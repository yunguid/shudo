import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import {
  Anthropic,
  callClaudeStructured,
  CLAUDE_MODELS,
  type ClaudeModel,
  type StructuredCallResult,
} from "./claude.ts";
import {
  type CoachContext,
  coachSystemBlocks,
  loadCoachContext,
  numeric,
  renderMemoryBlock,
} from "./coach_context.ts";
import { coachMemorySafetyViolation } from "./coach_copy.ts";
import {
  applyNoteOperations,
  type NoteOperation,
  updateCoachMemory,
} from "./coach_memory.ts";
import {
  COACH_DAY_DIGEST_INSTRUCTIONS,
  COACH_PERSONA_VERSION,
} from "./coach_persona.ts";
import { addDays, coachLocalDay, localClock } from "./coach_policy.ts";
import {
  claimCoachRun,
  completeCoachRun,
  failCoachRun,
  isClaimed,
  saveDayDigestRpc,
} from "./coach_rpc.ts";
import { recordCoachUsage } from "./coach_usage.ts";

/// Nightly compression (Fable 5.1, medium): yesterday's log + thread become
/// one day_digests row, the coach notes are patched (version-locked), and
/// the next day's game plan is stored for the morning plan to pick up.

export const DAY_DIGEST_MODEL = CLAUDE_MODELS.fable;
const DIGEST_TIMEOUT_MS = 110_000;

export const DAY_DIGEST_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    headline: { type: "string", minLength: 1, maxLength: 160 },
    summary: { type: "string", minLength: 1, maxLength: 1200 },
    highlights: {
      type: "array",
      maxItems: 4,
      items: { type: "string", maxLength: 200 },
    },
    misses: { type: "array", maxItems: 4, items: { type: "string", maxLength: 200 } },
    tomorrow_focus: {
      type: "array",
      maxItems: 3,
      items: { type: "string", maxLength: 160 },
    },
    score: { type: ["integer", "null"], minimum: 0, maximum: 100 },
    game_plan: {
      type: "object",
      additionalProperties: false,
      properties: {
        theme: { type: "string", maxLength: 80 },
        focus: { type: "array", maxItems: 3, items: { type: "string", maxLength: 120 } },
        training: {
          anyOf: [
            {
              type: "object",
              additionalProperties: false,
              properties: { session_name: { type: ["string", "null"], maxLength: 80 } },
              required: ["session_name"],
            },
            { type: "null" },
          ],
        },
      },
      required: ["theme", "focus", "training"],
    },
    memory_ops: {
      type: "array",
      maxItems: 6,
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          op: { type: "string", enum: ["add", "update", "remove"] },
          key: { type: ["string", "null"] },
          text: { type: ["string", "null"], maxLength: 200 },
        },
        required: ["op", "key", "text"],
      },
    },
  },
  required: [
    "headline",
    "summary",
    "highlights",
    "misses",
    "tomorrow_focus",
    "score",
    "game_plan",
    "memory_ops",
  ],
} as const;

export type DayDigestOutput = {
  headline: string;
  summary: string;
  highlights: string[];
  misses: string[];
  tomorrow_focus: string[];
  score: number | null;
  game_plan: {
    theme: string;
    focus: string[];
    training: { session_name: string | null } | null;
  };
  memory_ops: NoteOperation[];
};

function safeText(value: unknown, max: number): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim().slice(0, max);
  if (!trimmed || coachMemorySafetyViolation(trimmed)) return null;
  return trimmed;
}

function safeList(value: unknown, maxItems: number, maxChars: number): string[] {
  return (Array.isArray(value) ? value : [])
    .map((item) => safeText(item, maxChars))
    .filter((item): item is string => item !== null)
    .slice(0, maxItems);
}

/// Validates the model's digest; unsafe list items are dropped, an unsafe
/// headline or summary fails the digest (it would seed later prompts).
export function parseDigestOutput(value: unknown): DayDigestOutput {
  const object = value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
  const headline = safeText(object.headline, 160);
  const summary = safeText(object.summary, 1200);
  if (!headline || !summary) throw new Error("Day digest copy is invalid");
  const plan = object.game_plan && typeof object.game_plan === "object"
    ? object.game_plan as Record<string, unknown>
    : {};
  const training = plan.training && typeof plan.training === "object"
    ? plan.training as Record<string, unknown>
    : null;
  const score = typeof object.score === "number" && Number.isFinite(object.score)
    ? Math.max(0, Math.min(100, Math.round(object.score)))
    : null;
  return {
    headline,
    summary,
    highlights: safeList(object.highlights, 4, 200),
    misses: safeList(object.misses, 4, 200),
    tomorrow_focus: safeList(object.tomorrow_focus, 3, 160),
    score,
    game_plan: {
      theme: safeText(plan.theme, 80) ?? "Normal day: eat, train, sleep.",
      focus: safeList(plan.focus, 3, 120),
      training: training
        ? { session_name: safeText(training.session_name, 80) }
        : null,
    },
    memory_ops: (Array.isArray(object.memory_ops) ? object.memory_ops : [])
      .flatMap((item): NoteOperation[] => {
        if (!item || typeof item !== "object") return [];
        const op = (item as Record<string, unknown>).op;
        if (op !== "add" && op !== "update" && op !== "remove") return [];
        const key = (item as Record<string, unknown>).key;
        const text = safeText((item as Record<string, unknown>).text, 200);
        if (op !== "remove" && !text) return [];
        return [{
          op,
          key: typeof key === "string" && /^[a-z0-9_]{1,40}$/u.test(key) ? key : null,
          text,
        }];
      }).slice(0, 6),
  };
}

export type DigestMetrics = {
  meals_logged: number;
  calories_kcal: number;
  protein_g: number;
  carbs_g: number;
  fat_g: number;
  target_calories_kcal: number;
  target_protein_g: number;
  calories_on_target: boolean;
  protein_hit: boolean;
  sessions: number;
  checkin_photo: boolean;
  weight_kg: number | null;
  log_completeness: "likely_complete" | "possibly_incomplete";
  coach_messages: number;
  user_messages: number;
};

/** Deterministic scorecard for the digested day (copy never recomputes). */
export function digestMetrics(context: CoachContext): DigestMetrics {
  const complete = context.meals.filter((meal) => meal.status === "complete");
  const target = context.targets;
  const dayMessages = context.thread.filter((row) => row.local_day === context.localDay);
  const incomplete = complete.length < 2 ||
    context.totals.calories_kcal < target.calories_kcal * 0.6;
  return {
    meals_logged: complete.length,
    calories_kcal: context.totals.calories_kcal,
    protein_g: context.totals.protein_g,
    carbs_g: context.totals.carbs_g,
    fat_g: context.totals.fat_g,
    target_calories_kcal: target.calories_kcal,
    target_protein_g: target.protein_g,
    calories_on_target: target.calories_kcal > 0 &&
      context.totals.calories_kcal >= target.calories_kcal * 0.9 &&
      context.totals.calories_kcal <= target.calories_kcal * 1.1,
    protein_hit: target.protein_g > 0 &&
      context.totals.protein_g >= target.protein_g * 0.9,
    sessions: context.activities.filter((activity) => activity.status === "complete").length,
    checkin_photo: Boolean(context.checkin?.progress_photo_path),
    weight_kg: context.checkin?.weight_kg === null || context.checkin === null
      ? null
      : numeric(context.checkin.weight_kg),
    log_completeness: incomplete ? "possibly_incomplete" : "likely_complete",
    coach_messages: dayMessages.filter((row) => row.role === "coach").length,
    user_messages: dayMessages.filter((row) => row.role === "user").length,
  };
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest)).map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

/** The day to digest: yesterday relative to the coach day (04:00 boundary). */
export function digestDayFor(now: Date, timezone: string): string {
  return addDays(coachLocalDay(now, timezone), -1);
}

export type DayDigestRequest = {
  userId: string;
  digestDay?: string | null;
};

export type DayDigestDependencies = {
  client?: Anthropic;
  now?: () => Date;
  loadContext?: typeof loadCoachContext;
};

export type DayDigestOutcome = {
  status: string;
  runId: string | null;
  digestDay: string;
  gamePlan: DayDigestOutput["game_plan"] | null;
};

async function callDigestModel(
  model: ClaudeModel,
  system: ReturnType<typeof coachSystemBlocks>,
  content: string,
  client: Anthropic | undefined,
): Promise<StructuredCallResult> {
  return await callClaudeStructured({
    workload: "day_digest",
    model,
    effort: "medium",
    system,
    messages: [{ role: "user", content }],
    schema: DAY_DIGEST_SCHEMA,
    schemaName: "submit_day_digest",
    maxTokens: 16_000,
    timeoutMs: DIGEST_TIMEOUT_MS,
    client,
  });
}

export async function runDayDigest(
  admin: SupabaseClient,
  request: DayDigestRequest,
  dependencies: DayDigestDependencies = {},
): Promise<DayDigestOutcome> {
  const now = dependencies.now?.() ?? new Date();
  const load = dependencies.loadContext ?? loadCoachContext;
  // Probe the timezone first so the digest day follows the user's clock.
  const probe = await load(admin, request.userId, { now, threadLimit: 1 });
  const digestDay = request.digestDay ?? digestDayFor(now, probe.timezone);
  if (!probe.settings.enabled) {
    return { status: "disabled", runId: null, digestDay, gamePlan: null };
  }
  const context = await load(admin, request.userId, {
    now,
    localDay: digestDay,
    threadLimit: 80,
  });
  const metrics = digestMetrics(context);
  const fingerprint = await sha256Hex(JSON.stringify({
    v: COACH_PERSONA_VERSION,
    day: digestDay,
    meals: context.meals.map((meal) => [meal.id, meal.updated_at]),
    activities: context.activities.map((activity) => [activity.id, activity.updated_at]),
    checkin: context.checkin?.updated_at ?? null,
    memory: context.memory?.version ?? 0,
  }));
  const claim = await claimCoachRun(admin, {
    userId: request.userId,
    operation: "day_digest",
    localDay: digestDay,
    checkpointKey: "digest",
    triggerSource: "schedule",
    scheduledFor: now,
    fingerprint,
    leaseSeconds: 150,
  });
  if (!isClaimed(claim)) {
    return { status: claim.status, runId: claim.run_id, digestDay, gamePlan: null };
  }

  try {
    const dayLog = {
      day: digestDay,
      weekday: localClock(new Date(`${digestDay}T12:00:00Z`), "UTC").weekday,
      next_day: addDays(digestDay, 1),
      next_weekday: localClock(new Date(`${addDays(digestDay, 1)}T12:00:00Z`), "UTC")
        .weekday,
      scorecard: metrics,
      targets: context.targets,
      meals: context.meals.filter((meal) => meal.status === "complete").map((meal) => ({
        title: meal.title,
        calories_kcal: numeric(meal.calories_kcal),
        protein_g: numeric(meal.protein_g),
        at: meal.occurred_at,
      })),
      activities: context.activities.map((activity) => ({
        title: activity.title,
        kind: activity.kind,
        duration_min: activity.duration_min,
        prs: Array.isArray(activity.details?.prs) ? activity.details?.prs : [],
      })),
      checkin: context.checkin
        ? {
          weight_kg: context.checkin.weight_kg === null ? null : numeric(context.checkin.weight_kg),
          photo: Boolean(context.checkin.progress_photo_path),
        }
        : null,
      thread: context.thread.filter((row) => row.local_day === digestDay)
        .map((row) => ({ role: row.role, kind: row.kind, text: row.body.slice(0, 500) })),
      training_plan: context.trainingPlan
        ? { name: context.trainingPlan.name, sessions: context.trainingPlan.sessions }
        : null,
    };
    const system = coachSystemBlocks(
      context.profile.goal_type,
      COACH_DAY_DIGEST_INSTRUCTIONS,
      renderMemoryBlock(context),
    );
    const content = `<day_log>\n${JSON.stringify(dayLog)}\n</day_log>\n\nWrite the digest for ${digestDay}.`;
    let result: StructuredCallResult;
    try {
      result = await callDigestModel(DAY_DIGEST_MODEL, system, content, dependencies.client);
    } catch (error) {
      // Fable requires 30-day retention; an org-config 400 falls back to Opus.
      if (error instanceof Anthropic.BadRequestError) {
        result = await callDigestModel(
          CLAUDE_MODELS.opus,
          system,
          content,
          dependencies.client,
        );
      } else {
        throw error;
      }
    }
    await recordCoachUsage(
      admin,
      request.userId,
      "day_digest",
      result.usage,
      claim.run_id,
    );
    const digest = parseDigestOutput(result.output);
    const saved = await saveDayDigestRpc(admin, claim.run_id, claim.claim_token, {
      headline: digest.headline,
      summary: digest.summary,
      metrics,
      highlights: digest.highlights,
      misses: digest.misses,
      tomorrow_focus: digest.tomorrow_focus,
      score: metrics.log_completeness === "possibly_incomplete" ? null : digest.score,
      input_fingerprint: fingerprint,
      digest_version: 1,
      model: result.model,
      provider_response_id: result.messageId,
      game_plan: digest.game_plan,
    });
    if (saved !== "saved") {
      return { status: saved || "stale", runId: claim.run_id, digestDay, gamePlan: null };
    }
    if (digest.memory_ops.length > 0) {
      await updateCoachMemory(
        admin,
        request.userId,
        (sections) => ({
          sections: applyNoteOperations(sections, digest.memory_ops, now),
          summary: `Nightly digest ${digestDay}: ${digest.memory_ops.length} note change(s)`,
        }),
        {
          source: "day_digest",
          runId: claim.run_id,
          claimToken: claim.claim_token,
        },
      ).catch((error) => {
        console.warn("coach_digest_memory_failed", { message: String(error) });
      });
    }
    await completeCoachRun(admin, {
      runId: claim.run_id,
      claimToken: claim.claim_token,
      status: "complete",
      result: { digest_day: digestDay, game_plan: digest.game_plan, score: digest.score },
      messages: [],
      supersedeSlotKeys: [],
      model: result.model,
      providerResponseId: result.messageId,
    });
    return {
      status: "complete",
      runId: claim.run_id,
      digestDay,
      gamePlan: digest.game_plan,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("coach_digest_failed", { userId: request.userId, message });
    await failCoachRun(admin, claim.run_id, claim.claim_token, message).catch(() => undefined);
    return { status: "failed", runId: claim.run_id, digestDay, gamePlan: null };
  }
}
