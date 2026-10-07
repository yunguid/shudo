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

/** Deterministic markdown rendering of the memory sections. */
export function renderMemoryDocument(sections: CoachMemorySections): string {
  const render = (notes: Array<[string, string]>): string => {
    const lines: string[] = ["# Bio (his own words)"];
    for (const key of BIO_SECTION_KEYS) {
      const text = sections.bio[key];
      if (text) lines.push(`## ${BIO_SECTION_TITLES[key]}`, text);
    }
    const schedule = describeSchedule(sections.schedule);
    if (schedule) lines.push("## Schedule (structured)", schedule);
    if (sections.equipment.length) {
      lines.push("## Equipment list", sections.equipment.join(", "));
    }
    lines.push("# Coach notes");
    if (notes.length === 0) lines.push("(none yet)");
    for (const [key, text] of notes) lines.push(`- (${key}) ${text}`);
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
};

/** Applies the nightly digest's note operations; unknown keys are ignored. */
export function applyNoteOperations(
  sections: CoachMemorySections,
  operations: NoteOperation[],
  now: Date,
): CoachMemorySections {
  let next: CoachMemorySections = { ...sections, notes: { ...sections.notes } };
  for (const operation of operations) {
    if (operation.op === "add" && operation.text?.trim()) {
      next = addMemoryNote(next, operation.text, now).sections;
    } else if (
      operation.op === "update" && operation.key &&
      next.notes[operation.key] && operation.text?.trim()
    ) {
      next.notes[operation.key] = operation.text.trim().slice(
        0,
        MAX_NOTE_CHARACTERS,
      );
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
