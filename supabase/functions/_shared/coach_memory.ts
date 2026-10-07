import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import type { CoachSchedule, Weekday } from "./coach_policy.ts";
import { WEEKDAYS } from "./coach_policy.ts";
import { type CoachMemorySource, saveCoachMemoryRpc } from "./coach_rpc.ts";

/// One living memory document per user: Luke's bio (his sections, his words)
/// plus the coach's notes, a structured schedule and an equipment list. The
/// markdown `document` is rendered deterministically from `sections` so the
/// cached prompt prefix only changes when the content does.

export const BIO_SECTION_KEYS = [
  "about",
  "role_models",
  "schedule",
  "training_history",
  "current_training",
  "nutrition",
  "sleep",
  "goals",
  "equipment",
  "handle_with_care",
] as const;
export type BioSectionKey = typeof BIO_SECTION_KEYS[number];

export const BIO_SECTION_TITLES: Record<BioSectionKey, string> = {
  about: "About",
  role_models: "Role models",
  schedule: "Schedule",
  training_history: "Training history",
  current_training: "Current training",
  nutrition: "Nutrition",
  sleep: "Sleep",
  goals: "Goals",
  equipment: "Equipment",
  handle_with_care: "Handle with care",
};

export type CoachMemorySections = {
  bio: Partial<Record<BioSectionKey, string>>;
  notes: Record<string, string>;
  schedule: CoachSchedule;
  equipment: string[];
};

export type CoachMemory = {
  version: number;
  document: string;
  sections: CoachMemorySections;
};

const MAX_DOCUMENT_CHARACTERS = 20_000;
const MAX_SECTION_CHARACTERS = 2_000;
const MAX_NOTE_CHARACTERS = 240;
const MAX_NOTES = 40;

function record(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function clockOrNull(value: unknown): string | null {
  return typeof value === "string" &&
      /^([01]\d|2[0-3]):[0-5]\d$/u.test(value.trim())
    ? value.trim()
    : null;
}

function weekdays(value: unknown): Weekday[] | null {
  if (!Array.isArray(value)) return null;
  const days = value.map((day) => String(day).trim().toLowerCase().slice(0, 3))
    .filter((day): day is Weekday => WEEKDAYS.includes(day as Weekday));
  return days.length ? [...new Set(days)] : null;
}

export function parseSchedule(value: unknown): CoachSchedule {
  const object = record(value);
  const schedule: CoachSchedule = {};
  for (
    const key of [
      "wake",
      "office_start",
      "lift_time",
      "bed",
      "target_bed",
    ] as const
  ) {
    const clock = clockOrNull(object[key]);
    if (clock) schedule[key] = clock;
  }
  const office = weekdays(object.office_days);
  if (office) schedule.office_days = office;
  const lift = weekdays(object.lift_days);
  if (lift) schedule.lift_days = lift;
  return schedule;
}

/** Tolerant parse of the stored sections jsonb. */
export function parseMemorySections(value: unknown): CoachMemorySections {
  const object = record(value);
  const bioSource = record(object.bio);
  const bio: Partial<Record<BioSectionKey, string>> = {};
  for (const key of BIO_SECTION_KEYS) {
    const text = bioSource[key];
    if (typeof text === "string" && text.trim()) {
      bio[key] = text.trim().slice(0, MAX_SECTION_CHARACTERS);
    }
  }
  const notes: Record<string, string> = {};
  for (const [key, text] of Object.entries(record(object.notes))) {
    if (
      typeof text === "string" && text.trim() && /^[a-z0-9_]{1,40}$/u.test(key)
    ) {
      notes[key] = text.trim().slice(0, MAX_NOTE_CHARACTERS);
    }
  }
  const equipment = Array.isArray(object.equipment)
    ? object.equipment.filter((item): item is string =>
      typeof item === "string" && item.trim().length > 0
    ).map((item) => item.trim().slice(0, 80)).slice(0, 30)
    : [];
  return { bio, notes, schedule: parseSchedule(object.schedule), equipment };
}

export function emptyMemorySections(): CoachMemorySections {
  return { bio: {}, notes: {}, schedule: {}, equipment: [] };
}

export function describeSchedule(schedule: CoachSchedule): string {
  const parts: string[] = [];
  if (schedule.wake) parts.push(`wake ${schedule.wake}`);
  if (schedule.office_start) {
    parts.push(
      `office ${schedule.office_start}${
        schedule.office_days?.length ? ` ${schedule.office_days.join("/")}` : ""
      }`,
    );
  }
  if (schedule.lift_days?.length) {
    parts.push(
      `lift ${schedule.lift_days.join("/")}${
        schedule.lift_time ? ` ${schedule.lift_time}` : ""
      }`,
    );
  }
  if (schedule.bed) parts.push(`bed ${schedule.bed}`);
  if (schedule.target_bed) parts.push(`target bed ${schedule.target_bed}`);
  return parts.join(" · ");
}

/// Notes are keyed `n_<yyyymmdd>_<n>`; sorted keys render oldest first.
function orderedNotes(notes: Record<string, string>): Array<[string, string]> {
  return Object.entries(notes).sort(([left], [right]) =>
    left.localeCompare(right)
  );
}

/// The note that holds what the coach still needs to learn about him
/// ("Does he have a scale yet? Which gym?"). Questions are asked one at a
/// time and removed as he answers them.
export const OPEN_QUESTIONS_NOTE_KEY = "open_questions";

export type NoteKind =
  | "fact"
  | "commitment"
  | "running_joke"
  | "pattern"
  | "preference"
  | "win"
  | "open_questions";

const NOTE_KIND_PREFIXES: Array<[RegExp, NoteKind]> = [
  [/^commitments?\s*:/iu, "commitment"],
  [/^(?:running[ _]jokes?|jokes?)\s*:/iu, "running_joke"],
  [/^patterns?\s*:/iu, "pattern"],
  [/^preferences?\s*:/iu, "preference"],
  [/^wins?\s*:/iu, "win"],
];

/** A note's kind, from its key (seeded notes) or its text prefix. */
export function noteKind(key: string, text: string): NoteKind {
  if (key === OPEN_QUESTIONS_NOTE_KEY) return "open_questions";
  if (/^running_jokes?$/u.test(key)) return "running_joke";
  if (/^commitments?$/u.test(key)) return "commitment";
  for (const [pattern, kind] of NOTE_KIND_PREFIXES) {
    if (pattern.test(text.trim())) return kind;
  }
  return "fact";
}

/** Note text without its kind label ("commitment: x" → "x"). */
export function noteBody(text: string): string {
  return text.replace(
    /^(?:commitments?|running[ _]jokes?|jokes?|patterns?|preferences?|wins?)\s*:\s*/iu,
    "",
  ).trim();
}

/** The open questions, in the order they should be asked. */
export function openQuestions(sections: CoachMemorySections): string[] {
  const text = sections.notes[OPEN_QUESTIONS_NOTE_KEY]?.trim();
  if (!text) return [];
  return text.split(/(?<=\?)\s+|\n+|;\s*/u)
    .map((part) => part.replace(/^[-*•\d.)\s]+/u, "").trim())
    .filter((part) => part.length > 2);
}

function questionTokens(value: string): Set<string> {
  const stop = new Set([
    "does",
    "do",
    "he",
    "his",
    "have",
    "a",
    "an",
    "the",
    "which",
    "what",
    "can",
    "is",
    "yet",
    "now",
    "you",
    "your",
  ]);
  return new Set(
    value.toLowerCase().replace(/[^a-z0-9\s]/gu, " ").split(/\s+/u)
      .filter((word) => word.length > 1 && !stop.has(word)),
  );
}

/** Index of the open question `query` refers to, or -1. */
export function matchOpenQuestion(questions: string[], query: string): number {
  const wanted = questionTokens(query);
  if (wanted.size === 0) return -1;
  let best = -1;
  let bestScore = 0;
  questions.forEach((question, index) => {
    const tokens = questionTokens(question);
    if (tokens.size === 0) return;
    let shared = 0;
    for (const token of wanted) if (tokens.has(token)) shared += 1;
    const score = shared / Math.min(tokens.size, wanted.size);
    if (score > bestScore) {
      best = index;
      bestScore = score;
    }
  });
  return bestScore >= 0.5 ? best : -1;
}

/**
 * Settles one open question: it leaves the open_questions note (which is
 * removed once empty) and the answer is kept as a note in its place.
 */
export function answerOpenQuestion(
  sections: CoachMemorySections,
  question: string,
  answer: string,
  now: Date,
): { sections: CoachMemorySections; question: string | null } {
  const questions = openQuestions(sections);
  const index = matchOpenQuestion(questions, question);
  let next: CoachMemorySections = { ...sections, notes: { ...sections.notes } };
  const matched = index >= 0 ? questions[index] : null;
  if (matched) {
    const remaining = questions.filter((_, position) => position !== index);
    if (remaining.length) {
      next.notes[OPEN_QUESTIONS_NOTE_KEY] = remaining.join(" ");
    } else {
      delete next.notes[OPEN_QUESTIONS_NOTE_KEY];
    }
  }
  const text = answer.trim();
  if (text && !Object.values(next.notes).includes(text)) {
    next = addMemoryNote(next, text, now).sections;
  }
  return { sections: next, question: matched };
}

export type RenderMemoryOptions = {
  /// Show note keys (the nightly digest edits notes by key). Default true.
  noteKeys?: boolean;
  /// Leave out the open-questions note (the brief asks them one at a time).
  omitOpenQuestions?: boolean;
  /// Leave out the structured schedule line (the brief states it).
  omitStructuredSchedule?: boolean;
};

/// Without keys, a seeded note like `running_jokes` keeps its meaning as a
/// label ("running jokes: …"); dated `n_…` notes carry their own prefix.
function noteLine(key: string, text: string, showKeys: boolean): string {
  if (showKeys) return `- (${key}) ${text}`;
  if (/^n_\d{8}_\d+$/u.test(key) || noteKind("", text) !== "fact") {
    return `- ${text}`;
  }
  return `- ${key.replaceAll("_", " ")}: ${text}`;
}

/** Deterministic markdown rendering of the memory sections. */
export function renderMemoryDocument(
  sections: CoachMemorySections,
  options: RenderMemoryOptions = {},
): string {
  const showKeys = options.noteKeys ?? true;
  const render = (notes: Array<[string, string]>): string => {
    const lines: string[] = ["# Bio (his own words)"];
    for (const key of BIO_SECTION_KEYS) {
      const text = sections.bio[key];
      if (text) lines.push(`## ${BIO_SECTION_TITLES[key]}`, text);
    }
    const schedule = describeSchedule(sections.schedule);
    if (schedule && !options.omitStructuredSchedule) {
      lines.push("## Schedule (structured)", schedule);
    }
    if (sections.equipment.length) {
      lines.push("## Equipment list", sections.equipment.join(", "));
    }
    lines.push("# Coach notes");
    const shown = options.omitOpenQuestions
      ? notes.filter(([key]) => key !== OPEN_QUESTIONS_NOTE_KEY)
      : notes;
    if (shown.length === 0) lines.push("(none yet)");
    for (const [key, text] of shown) {
      lines.push(noteLine(key, text, showKeys));
    }
    return lines.join("\n");
  };
  let notes = orderedNotes(sections.notes);
  let document = render(notes);
  while (document.length > MAX_DOCUMENT_CHARACTERS && notes.length > 0) {
    notes = notes.slice(1);
    document = render(notes);
  }
  return document.slice(0, MAX_DOCUMENT_CHARACTERS);
}

function noteKeyPrefix(now: Date): string {
  return `n_${now.toISOString().slice(0, 10).replaceAll("-", "")}_`;
}

/** Adds a coach note, keeping the newest MAX_NOTES. Returns the new key. */
export function addMemoryNote(
  sections: CoachMemorySections,
  text: string,
  now: Date,
): { sections: CoachMemorySections; key: string } {
  const prefix = noteKeyPrefix(now);
  let index = 1;
  while (sections.notes[`${prefix}${index}`]) index += 1;
  const key = `${prefix}${index}`;
  const notes = {
    ...sections.notes,
    [key]: text.trim().slice(0, MAX_NOTE_CHARACTERS),
  };
  const kept = orderedNotes(notes).slice(-MAX_NOTES);
  return { sections: { ...sections, notes: Object.fromEntries(kept) }, key };
}

export type NoteOperation = {
  op: "add" | "update" | "remove";
  key: string | null;
  text: string | null;
  /// Optional label for added notes ("commitment: in bed by 23:00").
  kind?: NoteKind | null;
};

const LABELLED_KINDS: Partial<Record<NoteKind, string>> = {
  commitment: "commitment",
  running_joke: "running joke",
  pattern: "pattern",
  preference: "preference",
  win: "win",
};

/** Note text carrying its kind label, unless it already has one. */
export function labelledNote(text: string, kind: NoteKind | null | undefined) {
  const trimmed = text.trim();
  const label = kind ? LABELLED_KINDS[kind] : undefined;
  if (!label || noteKind("", trimmed) !== "fact") return trimmed;
  return `${label}: ${trimmed}`;
}

/** Applies the nightly digest's note operations; unknown keys are ignored. */
export function applyNoteOperations(
  sections: CoachMemorySections,
  operations: NoteOperation[],
  now: Date,
): CoachMemorySections {
  let next: CoachMemorySections = { ...sections, notes: { ...sections.notes } };
  for (const operation of operations) {
    if (operation.op === "add" && operation.text?.trim()) {
      const text = labelledNote(operation.text, operation.kind);
      if (Object.values(next.notes).includes(text)) continue;
      next = addMemoryNote(next, text, now).sections;
    } else if (
      operation.op === "update" && operation.key &&
      next.notes[operation.key] && operation.text?.trim()
    ) {
      next.notes[operation.key] = labelledNote(operation.text, operation.kind)
        .slice(0, MAX_NOTE_CHARACTERS);
    } else if (operation.op === "remove" && operation.key) {
      delete next.notes[operation.key];
    }
  }
  return next;
}

export type BioChange = {
  section: BioSectionKey;
  op: "add" | "replace" | "remove";
  text: string | null;
  summary: string;
};

export function applyBioChanges(
  sections: CoachMemorySections,
  changes: BioChange[],
): CoachMemorySections {
  const bio = { ...sections.bio };
  for (const change of changes) {
    if (change.op === "remove") {
      delete bio[change.section];
    } else if (change.text?.trim()) {
      const text = change.text.trim();
      bio[change.section] = (change.op === "add" && bio[change.section]
        ? `${bio[change.section]}\n${text}`
        : text).slice(0, MAX_SECTION_CHARACTERS);
    }
  }
  return { ...sections, bio };
}

export async function loadCoachMemory(
  admin: SupabaseClient,
  userId: string,
): Promise<CoachMemory | null> {
  const { data, error } = await admin.from("coach_memory")
    .select("version,document,sections")
    .eq("user_id", userId)
    .maybeSingle();
  if (error) throw error;
  if (!data) return null;
  const row = data as { version: number; document: string; sections: unknown };
  return {
    version: Number(row.version) || 0,
    document: row.document ?? "",
    sections: parseMemorySections(row.sections),
  };
}

export type MemoryUpdateResult = {
  status: "saved" | "unchanged" | "conflict" | "stale";
  version: number | null;
  previousVersion: number;
  sections: CoachMemorySections;
};

/**
 * Version-locked read-modify-write of the memory document. The mutation runs
 * against the latest stored sections; a concurrent writer causes one reload
 * and retry. Returning null from `mutate` skips the write.
 */
export async function updateCoachMemory(
  admin: SupabaseClient,
  userId: string,
  mutate: (
    sections: CoachMemorySections,
  ) => { sections: CoachMemorySections; summary: string } | null,
  options: {
    source: CoachMemorySource;
    runId?: string | null;
    claimToken?: string | null;
    messageId?: string | null;
    attempts?: number;
  },
): Promise<MemoryUpdateResult> {
  const attempts = options.attempts ?? 2;
  let last: MemoryUpdateResult | null = null;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    const current = await loadCoachMemory(admin, userId);
    const sections = current?.sections ?? emptyMemorySections();
    const previousVersion = current?.version ?? 0;
    const change = mutate(sections);
    if (!change) {
      return {
        status: "unchanged",
        version: previousVersion,
        previousVersion,
        sections,
      };
    }
    const document = renderMemoryDocument(change.sections);
    const saved = await saveCoachMemoryRpc(admin, {
      userId,
      expectedVersion: previousVersion,
      document,
      sections: change.sections as unknown as Record<string, unknown>,
      source: options.source,
      changeSummary: change.summary.slice(0, 1000),
      runId: options.runId ?? null,
      claimToken: options.claimToken ?? null,
      messageId: options.messageId ?? null,
    });
    last = {
      status: saved.status,
      version: saved.version,
      previousVersion,
      sections: change.sections,
    };
    if (saved.status !== "conflict") return last;
  }
  return last ?? {
    status: "conflict",
    version: null,
    previousVersion: 0,
    sections: emptyMemorySections(),
  };
}
