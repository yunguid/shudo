import {
  type Anthropic,
  callClaudeStructured,
  CLAUDE_MODELS,
  type ClaudeUsage,
  systemBlocks,
} from "./claude.ts";
import {
  BIO_SECTION_KEYS,
  type BioChange,
  type BioSectionKey,
  type CoachMemorySections,
  parseSchedule,
  renderMemoryDocument,
} from "./coach_memory.ts";
import { COACH_BIO_MERGE_INSTRUCTIONS } from "./coach_persona.ts";
import type { CoachSchedule } from "./coach_policy.ts";

/// update_bio: Sonnet (medium) folds a dictation into Luke's own bio
/// sections. The result is a patch the server applies, versions, and lets
/// him undo; the model never rewrites the document wholesale.

const BIO_MERGE_TIMEOUT_MS = 45_000;

export const BIO_MERGE_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    changes: {
      type: "array",
      maxItems: 10,
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          section: { type: "string", enum: [...BIO_SECTION_KEYS] },
          op: { type: "string", enum: ["add", "replace", "remove"] },
          text: { type: ["string", "null"], maxLength: 2000 },
          summary: { type: "string", maxLength: 140 },
        },
        required: ["section", "op", "text", "summary"],
      },
    },
    schedule: {
      anyOf: [
        {
          type: "object",
          additionalProperties: false,
          properties: {
            wake: { type: ["string", "null"] },
            office_start: { type: ["string", "null"] },
            office_days: { anyOf: [{ type: "array", items: { type: "string" } }, { type: "null" }] },
            lift_days: { anyOf: [{ type: "array", items: { type: "string" } }, { type: "null" }] },
            lift_time: { type: ["string", "null"] },
            bed: { type: ["string", "null"] },
            target_bed: { type: ["string", "null"] },
          },
          required: [
            "wake",
            "office_start",
            "office_days",
            "lift_days",
            "lift_time",
            "bed",
            "target_bed",
          ],
        },
        { type: "null" },
      ],
    },
    goal_signals: {
      type: "object",
      additionalProperties: false,
      properties: {
        target_weight_lb: { type: ["number", "null"] },
        phase: {
          anyOf: [
            { type: "string", enum: ["cut", "lean_bulk", "bulk", "maintain", "recomp"] },
            { type: "null" },
          ],
        },
        training_days_per_week: { type: ["integer", "null"] },
        bedtime_target: { type: ["string", "null"] },
      },
      required: ["target_weight_lb", "phase", "training_days_per_week", "bedtime_target"],
    },
    unclear: { type: "array", maxItems: 3, items: { type: "string", maxLength: 160 } },
  },
  required: ["changes", "schedule", "goal_signals", "unclear"],
} as const;

export type BioMergeResult = {
  changes: BioChange[];
  schedule: CoachSchedule | null;
  goalSignals: {
    target_weight_lb: number | null;
    phase: string | null;
    training_days_per_week: number | null;
    bedtime_target: string | null;
  };
  unclear: string[];
  model: string;
  usage: ClaudeUsage | null;
};

export function parseBioMerge(value: unknown): Omit<BioMergeResult, "model" | "usage"> {
  const object = value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
  const changes = (Array.isArray(object.changes) ? object.changes : [])
    .flatMap((item): BioChange[] => {
      if (!item || typeof item !== "object") return [];
      const change = item as Record<string, unknown>;
      if (!BIO_SECTION_KEYS.includes(change.section as BioSectionKey)) return [];
      if (change.op !== "add" && change.op !== "replace" && change.op !== "remove") {
        return [];
      }
      const text = typeof change.text === "string" ? change.text.trim().slice(0, 2000) : null;
      if (change.op !== "remove" && !text) return [];
      return [{
        section: change.section as BioSectionKey,
        op: change.op,
        text,
        summary: typeof change.summary === "string" && change.summary.trim()
          ? change.summary.trim().slice(0, 140)
          : `${change.op} ${change.section}`,
      }];
    }).slice(0, 10);
  const signals = object.goal_signals && typeof object.goal_signals === "object"
    ? object.goal_signals as Record<string, unknown>
    : {};
  const schedule = object.schedule && typeof object.schedule === "object"
    ? parseSchedule(object.schedule)
    : null;
  return {
    changes,
    schedule: schedule && Object.keys(schedule).length ? schedule : null,
    goalSignals: {
      target_weight_lb: typeof signals.target_weight_lb === "number"
        ? signals.target_weight_lb
        : null,
      phase: typeof signals.phase === "string" ? signals.phase : null,
      training_days_per_week: typeof signals.training_days_per_week === "number"
        ? signals.training_days_per_week
        : null,
      bedtime_target: typeof signals.bedtime_target === "string"
        ? signals.bedtime_target
        : null,
    },
    unclear: (Array.isArray(object.unclear) ? object.unclear : [])
      .filter((item): item is string => typeof item === "string" && item.trim().length > 0)
      .map((item) => item.trim().slice(0, 160)).slice(0, 3),
  };
}

export async function mergeBioDictation(
  sections: CoachMemorySections,
  dictation: string,
  options: { client?: Anthropic } = {},
): Promise<BioMergeResult> {
  const result = await callClaudeStructured({
    workload: "bio_merge",
    model: CLAUDE_MODELS.sonnet,
    effort: "medium",
    system: systemBlocks([{ text: COACH_BIO_MERGE_INSTRUCTIONS, cache: true }]),
    messages: [{
      role: "user",
      content: `<current_bio>\n${renderMemoryDocument(sections)}\n</current_bio>\n\n<dictation>\n${
        dictation.slice(0, 12_000)
      }\n</dictation>\n\nReturn the changes to merge this dictation into the bio.`,
    }],
    schema: BIO_MERGE_SCHEMA,
    schemaName: "submit_bio_changes",
    maxTokens: 8_000,
    timeoutMs: BIO_MERGE_TIMEOUT_MS,
    client: options.client,
  });
  return { ...parseBioMerge(result.output), model: result.model, usage: result.usage };
}

/// Structured schedule facts overwrite only the fields he mentioned.
export function mergeSchedule(
  current: CoachSchedule,
  update: CoachSchedule | null,
): CoachSchedule {
  if (!update) return current;
  const next: CoachSchedule = { ...current };
  for (const [key, value] of Object.entries(update)) {
    if (value !== null && value !== undefined) {
      (next as Record<string, unknown>)[key] = value;
    }
  }
  return next;
}
