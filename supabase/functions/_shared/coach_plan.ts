import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import {
  type Anthropic,
  callClaudeStructured,
  CLAUDE_MODELS,
  ClaudeRefusalError,
  type ClaudeUsage,
} from "./claude.ts";
import {
  allowedFiguresFor,
  avoidOpeners,
  buildStatePack,
  type CoachContext,
  coachSystemBlocks,
  loadCoachContext,
  logCompleteness,
  numeric,
  paceOf,
  pickShape,
  recentThreadForPack,
  renderMemoryBlock,
} from "./coach_context.ts";
import {
  type CoachCopyPolicy,
  coachCopyViolation,
  type CoachRenderOutput,
  splitBubbles,
} from "./coach_copy.ts";
import {
  type FallbackSnapshot,
  fallbackReactionCopy,
  fallbackSlotCopy,
  type ReactionKind,
} from "./coach_fallbacks.ts";
import { addMemoryNote, updateCoachMemory } from "./coach_memory.ts";
import {
  COACH_DAY_PLAN_INSTRUCTIONS,
  COACH_PERSONA_VERSION,
  type CoachMode,
} from "./coach_persona.ts";
import {
  formatClock,
  isBehindPace,
  isQuietMinute,
  parseClock,
  type PlannedSlot,
  planCoachSlots,
  SLOT_KEYS,
} from "./coach_policy.ts";
import {
  claimCoachRun,
  type CoachMessageInput,
  completeCoachRun,
  failCoachRun,
  isClaimed,
} from "./coach_rpc.ts";
import { recordCoachUsage } from "./coach_usage.ts";

/// One Sonnet call per state change: an optional reaction to what Luke just
/// logged plus copy for every remaining slot. Slots come from the pure
/// policy; the model only writes. Every body passes assertCoachCopy or is
/// repaired once, then dropped (slots) or replaced by a template (reaction).

export const COACH_PLAN_MODEL = CLAUDE_MODELS.sonnet;
const PLAN_TIMEOUT_MS = 45_000;
const REPAIR_TIMEOUT_MS = 25_000;

export type CoachPlanTrigger =
  | "foreground"
  | "meal_complete"
  | "meal_corrected"
  | "activity_complete"
  | "checkin"
  | "settings"
  | "bg_refresh"
  | "chat"
  | "daily";

export type CoachPlanRequest = {
  userId: string;
  trigger: CoachPlanTrigger;
  entryId?: string | null;
  activityId?: string | null;
  /// True when the app asked in the foreground: reactions don't notify.
  foreground?: boolean;
  timezone?: string | null;
};

export type CoachPlanDependencies = {
  client?: Anthropic;
  now?: () => Date;
  loadContext?: typeof loadCoachContext;
};

export type CoachPlanOutcome = {
  status: string;
  runId: string | null;
  generated: boolean;
  messageIds: string[];
};

const REACTION_KINDS = ["meal_ack", "workout_ack", "weigh_in_ack"] as const;

export const COACH_PLAN_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    reaction: {
      anyOf: [
        {
          type: "object",
          additionalProperties: false,
          properties: {
            kind: { type: "string", enum: [...REACTION_KINDS] },
            body: { type: "string", minLength: 1, maxLength: 600 },
            push_body: { type: ["string", "null"], maxLength: 150 },
          },
          required: ["kind", "body", "push_body"],
        },
        { type: "null" },
      ],
    },
    slots: {
      type: "array",
      maxItems: 10,
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          slot_key: { type: "string", enum: [...SLOT_KEYS] },
          deliver_local: { type: "string" },
          day: { type: "string", enum: ["today", "tomorrow"] },
          skip: { type: "boolean" },
          kind: { type: "string", enum: ["checkpoint", "plan", "recap"] },
          body: { type: "string", maxLength: 600 },
          push_body: { type: ["string", "null"], maxLength: 150 },
        },
        required: [
          "slot_key",
          "deliver_local",
          "day",
          "skip",
          "kind",
          "body",
          "push_body",
        ],
      },
    },
    day_theme: { type: ["string", "null"], maxLength: 80 },
    memory_note: { type: ["string", "null"], maxLength: 200 },
  },
  required: ["reaction", "slots", "day_theme", "memory_note"],
} as const;

type PlanOutputSlot = {
  slot_key: string;
  deliver_local: string;
  day: "today" | "tomorrow";
  skip: boolean;
  kind: string;
  body: string;
  push_body: string | null;
};

export type PlanOutput = {
  reaction: { kind: string; body: string; push_body: string | null } | null;
  slots: PlanOutputSlot[];
  day_theme: string | null;
  memory_note: string | null;
};

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function nullableText(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

/** Tolerant parse: malformed items are dropped, never thrown. */
export function parsePlanOutput(value: unknown): PlanOutput {
  const object = value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
  const reaction = object.reaction && typeof object.reaction === "object"
    ? object.reaction as Record<string, unknown>
    : null;
  const slots = Array.isArray(object.slots) ? object.slots : [];
  return {
    reaction: reaction && text(reaction.body).trim()
      ? {
        kind: text(reaction.kind),
        body: text(reaction.body),
        push_body: nullableText(reaction.push_body),
      }
      : null,
    slots: slots.flatMap((item) => {
      if (!item || typeof item !== "object") return [];
      const slot = item as Record<string, unknown>;
      if (!SLOT_KEYS.includes(slot.slot_key as typeof SLOT_KEYS[number])) return [];
      return [{
        slot_key: text(slot.slot_key),
        deliver_local: text(slot.deliver_local),
        day: slot.day === "tomorrow" ? "tomorrow" : "today",
        skip: slot.skip === true,
        kind: text(slot.kind),
        body: text(slot.body),
        push_body: nullableText(slot.push_body),
      }];
    }),
    day_theme: nullableText(object.day_theme),
    memory_note: nullableText(object.memory_note),
  };
}

export type ReactionPlan = {
  kind: ReactionKind;
  mode: CoachMode;
  subjectKey: string;
  subject: Record<string, unknown>;
  payload: Record<string, unknown>;
  entryId: string | null;
  activityId: string | null;
};

async function hasAck(
  admin: SupabaseClient,
  userId: string,
  kind: string,
  column: "entry_id" | "activity_id" | "local_day",
  value: string,
): Promise<boolean> {
  const { data, error } = await admin.from("coach_messages")
    .select("id")
    .eq("user_id", userId)
    .eq("kind", kind)
    .eq(column, value)
    .limit(1);
  if (error) throw error;
  return Array.isArray(data) && data.length > 0;
}

/// Which logged thing, if any, deserves an immediate reaction. A subject
/// that already has an ack (chat logged it, or an earlier plan reacted) is
/// never acknowledged twice.
export async function resolveReaction(
  admin: SupabaseClient,
  context: CoachContext,
  request: CoachPlanRequest,
): Promise<ReactionPlan | null> {
  if (
    (request.trigger === "meal_complete" ||
      request.trigger === "meal_corrected") && request.entryId
  ) {
    const meal = context.meals.find((row) =>
      row.id === request.entryId && row.status === "complete"
    );
    if (!meal) return null;
    if (await hasAck(admin, context.userId, "meal_ack", "entry_id", meal.id)) {
      return null;
    }
    return {
      kind: "meal_ack",
      mode: "meal_ack",
      subjectKey: `meal:${meal.id}`,
      subject: {
        title: meal.title,
        calories_kcal: numeric(meal.calories_kcal),
        protein_g: numeric(meal.protein_g),
        corrected: request.trigger === "meal_corrected",
      },
      payload: { entry_id: meal.id },
      entryId: meal.id,
      activityId: null,
    };
  }
  if (request.trigger === "activity_complete" && request.activityId) {
    const activity = context.activities.find((row) =>
      row.id === request.activityId && row.status === "complete"
    );
    if (!activity) return null;
    if (
      await hasAck(admin, context.userId, "workout_ack", "activity_id", activity.id)
    ) return null;
    const details = activity.details ?? {};
    const prs = Array.isArray(details.prs) ? details.prs.slice(0, 5) : [];
    return {
      kind: "workout_ack",
      mode: "workout_ack",
      subjectKey: `activity:${activity.id}`,
      subject: {
        title: activity.title,
        kind: activity.kind,
        duration_min: activity.duration_min,
        active_kcal: activity.active_kcal,
        exercises: Array.isArray(details.exercises)
          ? details.exercises.slice(0, 8)
          : [],
        prs,
      },
      payload: { activity_id: activity.id, prs },
      entryId: null,
      activityId: activity.id,
    };
  }
  if (request.trigger === "checkin" && context.checkin) {
    if (
      await hasAck(admin, context.userId, "weigh_in_ack", "local_day", context.localDay)
    ) return null;
    const weight = context.checkin.weight_kg === null
      ? null
      : numeric(context.checkin.weight_kg);
    return {
      kind: "weigh_in_ack",
      mode: "checkin_ack",
      subjectKey: `checkin:${context.checkin.id}`,
      subject: {
        weight_kg: weight,
        photo_attached: Boolean(context.checkin.progress_photo_path),
        pose_match: "unknown",
      },
      payload: {
        local_day: context.localDay,
        ...(context.checkin.progress_photo_path
          ? { photo_path: context.checkin.progress_photo_path }
          : {}),
        ...(weight !== null ? { weight_kg: weight } : {}),
      },
      entryId: null,
      activityId: null,
    };
  }
  return null;
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest)).map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

/// Same state, same fingerprint: a re-sync with nothing new is a no-op
/// because the claim key repeats and the completed run is returned.
export function planFingerprint(
  context: CoachContext,
  slots: PlannedSlot[],
  reaction: ReactionPlan | null,
): Promise<string> {
  return sha256Hex(JSON.stringify({
    v: COACH_PERSONA_VERSION,
    day: context.localDay,
    meals: context.meals.map((meal) => [meal.id, meal.status, meal.updated_at]),
    activities: context.activities.map((activity) => [
      activity.id,
      activity.status,
      activity.updated_at,
    ]),
    checkin: context.checkin ? [context.checkin.id, context.checkin.updated_at] : null,
    memory: context.memory?.version ?? 0,
    digest: context.digests.at(-1)?.local_day ?? null,
    settings: context.settings,
    targets: context.targets,
    wellbeing: context.wellbeingHold,
    slots: slots.map((slot) => `${slot.day}:${slot.slot_key}`),
    reaction: reaction?.subjectKey ?? null,
  }));
}

function fallbackSnapshot(context: CoachContext): FallbackSnapshot {
  return {
    name: context.profile.display_name?.trim().split(/\s+/u)[0] ?? null,
    mealsLogged: context.meals.filter((meal) => meal.status === "complete").length,
    minutesSinceLastLog: context.lastLogAt
      ? Math.round((context.now.getTime() - context.lastLogAt.getTime()) / 60_000)
      : null,
    calories: {
      logged: context.totals.calories_kcal,
      target: context.targets.calories_kcal,
      remaining: context.remaining.calories_kcal,
    },
    protein: {
      logged: context.totals.protein_g,
      target: context.targets.protein_g,
      remaining: context.remaining.protein_g,
    },
    wellbeingHold: context.wellbeingHold,
  };
}

type WrittenMessage = { key: string; message: CoachMessageInput };

type CopyCandidate = {
  key: string;
  mode: CoachMode;
  bubbles: string[];
  push: string | null;
  dayTheme: string | null;
};

function copyPolicy(
  context: CoachContext,
  mode: CoachMode,
  allowedFigures: number[],
  pushCapable: boolean,
): CoachCopyPolicy {
  return {
    mode,
    profanity: context.settings.profanity,
    emojiAllowed: context.settings.emoji,
    allowedFigures: context.wellbeingHold ? [] : allowedFigures,
    pushCapable,
  };
}

function candidateOutput(candidate: CopyCandidate): CoachRenderOutput {
  return {
    skip: false,
    bubbles: candidate.bubbles,
    push_body: candidate.push,
    day_theme: candidate.dayTheme,
  };
}

function shiftedMinutes(planned: string, proposed: string): number | null {
  const plannedMinutes = parseClock(planned);
  const proposedMinutes = parseClock(proposed);
  if (plannedMinutes === null || proposedMinutes === null) return null;
  let delta = ((proposedMinutes - plannedMinutes) % 1440 + 1440) % 1440;
  if (delta > 720) delta -= 1440;
  return Math.abs(delta) <= 30 ? delta : null;
}

/// Turns validated copy into persisted messages, with card payloads.
function slotMessage(
  context: CoachContext,
  slot: PlannedSlot,
  bubbles: string[],
  push: string | null,
  dayTheme: string | null,
  shiftMinutes: number,
  extraPayload: Record<string, unknown>,
): CoachMessageInput {
  let deliverAt = slot.deliver_at;
  if (shiftMinutes !== 0) {
    const shifted = new Date(Date.parse(slot.deliver_at) + shiftMinutes * 60_000);
    if (shifted.getTime() > context.now.getTime() + 2 * 60_000) {
      deliverAt = shifted.toISOString();
    }
  }
  const notify = slot.notify && push !== null;
  const remaining = slot.day === "tomorrow" ? context.targets : context.remaining;
  const payload: Record<string, unknown> = {
    slot_key: slot.slot_key,
    topic: slot.topic,
    mode: slot.mode,
    as_of: context.now.toISOString(),
    persona_version: COACH_PERSONA_VERSION,
    ...extraPayload,
    ...(notify ? { push_body: push } : {}),
  };
  if (slot.kind === "plan") {
    const focus = Array.isArray(context.gamePlan?.focus)
      ? (context.gamePlan.focus as unknown[]).filter((item): item is string =>
        typeof item === "string"
      ).slice(0, 3)
      : [];
    Object.assign(payload, { theme: dayTheme, remaining, actions: focus });
  } else if (slot.kind === "recap") {
    Object.assign(payload, {
      kind: "day",
      kcal: context.totals.calories_kcal,
      protein_g: context.totals.protein_g,
      kcal_target: context.targets.calories_kcal,
      protein_target_g: context.targets.protein_g,
      headline: bubbles[0] ?? "",
      log_completeness: logCompleteness(context),
    });
  } else {
    Object.assign(payload, {
      remaining,
      on_track: !isBehindPace(paceOf(context), context.clock.coachMinutes),
    });
  }
  return {
    kind: slot.kind,
    body: bubbles.join("\n\n"),
    payload,
    deliver_at: deliverAt,
    local_day: slot.local_day,
    slot_key: slot.slot_key,
    notify,
  };
}

function reactionMessage(
  context: CoachContext,
  reaction: ReactionPlan,
  bubbles: string[],
  push: string | null,
  notifyAllowed: boolean,
): CoachMessageInput {
  const notify = notifyAllowed && push !== null && reaction.kind !== "weigh_in_ack";
  return {
    kind: reaction.kind,
    body: bubbles.join("\n\n"),
    payload: {
      ...reaction.payload,
      mode: reaction.mode,
      persona_version: COACH_PERSONA_VERSION,
      ...(notify ? { push_body: push } : {}),
    },
    deliver_at: context.now.toISOString(),
    local_day: context.localDay,
    notify,
    entry_id: reaction.entryId,
    activity_id: reaction.activityId,
  };
}

function pushFor(bubbles: string[], proposed: string | null): string | null {
  if (proposed && !/[\r\n]/u.test(proposed)) return proposed;
  const first = bubbles.length === 1 ? bubbles[0] : null;
  return first && Array.from(first).length <= 150 ? first : null;
}

type ModelCopy = {
  messages: WrittenMessage[];
  dayTheme: string | null;
  memoryNote: string | null;
  model: string | null;
  responseId: string | null;
  fallbackUsed: boolean;
  dropped: string[];
};

function templateCopy(
  context: CoachContext,
  slots: PlannedSlot[],
  reaction: ReactionPlan | null,
  reactionNotify: boolean,
  allowedFigures: number[],
): ModelCopy {
  const snapshot = fallbackSnapshot(context);
  const messages: WrittenMessage[] = [];
  const dropped: string[] = [];
  if (reaction) {
    const copy = fallbackReactionCopy(reaction.kind, snapshot);
    messages.push({
      key: "reaction",
      message: reactionMessage(
        context,
        reaction,
        [copy.body],
        copy.push_body,
        reactionNotify,
      ),
    });
  }
  for (const slot of slots) {
    const copy = fallbackSlotCopy(slot.topic, snapshot);
    const violation = copy
      ? coachCopyViolation(
        { skip: false, bubbles: [copy.body], push_body: slot.notify ? copy.push_body : null },
        copyPolicy(context, slot.mode, allowedFigures, slot.notify),
      )
      : null;
    if (!copy || violation) {
      dropped.push(slot.slot_key);
      continue;
    }
    messages.push({
      key: `${slot.day}:${slot.slot_key}`,
      message: slotMessage(
        context,
        slot,
        [copy.body],
        slot.notify ? copy.push_body : null,
        null,
        0,
        { fallback: true },
      ),
    });
  }
  return {
    messages,
    dayTheme: null,
    memoryNote: null,
    model: null,
    responseId: null,
    fallbackUsed: true,
    dropped,
  };
}

/** Writes and validates the batch; falls back to templates on refusal. */
export async function writePlanCopy(
  context: CoachContext,
  slots: PlannedSlot[],
  reaction: ReactionPlan | null,
  options: {
    reactionNotify: boolean;
    seed: string;
    client?: Anthropic;
    onUsage?: (usage: ClaudeUsage) => void;
  },
): Promise<ModelCopy> {
  const allowedFigures = allowedFiguresFor(context, reaction?.subject ?? null);
  const usedOpeners: string[] = [];
  const requestSlots = slots.map((slot) => {
    const shape = pickShape(`${options.seed}:${slot.day}:${slot.slot_key}`, usedOpeners);
    usedOpeners.push(shape.opener);
    return {
      slot_key: slot.slot_key,
      day: slot.day,
      deliver_local: slot.deliver_local,
      kind: slot.kind,
      topic: slot.topic,
      mode: slot.mode,
      push: slot.notify,
      shape,
    };
  });
  const pack = buildStatePack(context, {
    thread: {
      recent: recentThreadForPack(context),
      avoid_openers: avoidOpeners(context),
      pushes_sent_today: context.proactiveDeliveredToday,
    },
    request: {
      reaction: reaction
        ? {
          kind: reaction.kind,
          mode: reaction.mode,
          subject: reaction.subject,
          push: options.reactionNotify && reaction.kind !== "weigh_in_ack",
        }
        : null,
      slots: requestSlots,
    },
  });
  const system = coachSystemBlocks(
    context.profile.goal_type,
    COACH_DAY_PLAN_INSTRUCTIONS,
    renderMemoryBlock(context),
  );
  const userContent =
    `<context_pack>\n${JSON.stringify(pack)}\n</context_pack>\n\nWrite the batch described in request: the reaction (if requested) and one entry per requested slot, in the same order.`;

  let output: PlanOutput;
  let model: string | null = null;
  let responseId: string | null = null;
  try {
    const result = await callClaudeStructured({
      workload: "coach_plan",
      model: COACH_PLAN_MODEL,
      effort: "low",
      system,
      messages: [{ role: "user", content: userContent }],
      schema: COACH_PLAN_SCHEMA,
      schemaName: "submit_coach_plan",
      maxTokens: 8_000,
      timeoutMs: PLAN_TIMEOUT_MS,
      client: options.client,
    });
    options.onUsage?.(result.usage);
    output = parsePlanOutput(result.output);
    model = result.model;
    responseId = result.messageId;
  } catch (error) {
    console.warn("coach_plan_model_failed", {
      refusal: error instanceof ClaudeRefusalError,
      message: String((error as Error)?.message ?? error),
    });
    return templateCopy(context, slots, reaction, options.reactionNotify, allowedFigures);
  }

  const collect = (candidateOutput: PlanOutput) => {
    const candidates = new Map<string, CopyCandidate>();
    if (reaction && candidateOutput.reaction) {
      const bubbles = splitBubbles(candidateOutput.reaction.body, 1);
      candidates.set("reaction", {
        key: "reaction",
        mode: reaction.mode,
        bubbles,
        push: options.reactionNotify && reaction.kind !== "weigh_in_ack"
          ? pushFor(bubbles, candidateOutput.reaction.push_body)
          : null,
        dayTheme: null,
      });
    }
    for (const slot of slots) {
      const written = candidateOutput.slots.find((item) =>
        item.slot_key === slot.slot_key && item.day === slot.day
      );
      if (!written || written.skip || !written.body.trim()) continue;
      const bubbles = splitBubbles(written.body, 2);
      candidates.set(`${slot.day}:${slot.slot_key}`, {
        key: `${slot.day}:${slot.slot_key}`,
        mode: slot.mode,
        bubbles,
        push: slot.notify ? pushFor(bubbles, written.push_body) : null,
        dayTheme: slot.slot_key === "wake" ? candidateOutput.day_theme : null,
      });
    }
    return candidates;
  };

  const validate = (candidates: Map<string, CopyCandidate>) => {
    const failures = new Map<string, string>();
    for (const candidate of candidates.values()) {
      const pushCapable = candidate.push !== null;
      const violation = coachCopyViolation(
        candidateOutput(candidate),
        copyPolicy(context, candidate.mode, allowedFigures, pushCapable),
      );
      if (violation) failures.set(candidate.key, violation.message);
    }
    return failures;
  };

  const candidates = collect(output);
  let failures = validate(candidates);
  if (failures.size > 0) {
    try {
      const repair = await callClaudeStructured({
        workload: "coach_plan_repair",
        model: COACH_PLAN_MODEL,
        effort: "low",
        system,
        messages: [{
          role: "user",
          content: `${userContent}\n\n<previous_output>\n${
            JSON.stringify(output)
          }\n</previous_output>\n\nThese items broke the copy rules: ${
            [...failures.entries()].map(([key, reason]) => `${key} (${reason})`).join("; ")
          }. Rewrite only those items so they follow every rule (use only figures from the pack). Return the same JSON shape containing just the rewritten items; reaction null unless it is one of them.`,
        }],
        schema: COACH_PLAN_SCHEMA,
        schemaName: "submit_coach_plan",
        maxTokens: 4_000,
        timeoutMs: REPAIR_TIMEOUT_MS,
        client: options.client,
      });
      options.onUsage?.(repair.usage);
      const repaired = collect(parsePlanOutput(repair.output));
      for (const key of failures.keys()) {
        const replacement = repaired.get(key);
        if (replacement) candidates.set(key, replacement);
      }
      failures = validate(candidates);
    } catch (error) {
      console.warn("coach_plan_repair_failed", {
        message: String((error as Error)?.message ?? error),
      });
    }
  }

  const messages: WrittenMessage[] = [];
  const dropped: string[] = [];
  if (reaction) {
    const candidate = candidates.get("reaction");
    if (candidate && !failures.has("reaction")) {
      messages.push({
        key: "reaction",
        message: reactionMessage(
          context,
          reaction,
          candidate.bubbles,
          candidate.push,
          options.reactionNotify,
        ),
      });
    } else {
      const copy = fallbackReactionCopy(reaction.kind, fallbackSnapshot(context));
      messages.push({
        key: "reaction",
        message: {
          ...reactionMessage(
            context,
            reaction,
            [copy.body],
            copy.push_body,
            options.reactionNotify,
          ),
        },
      });
    }
  }
  for (const slot of slots) {
    const key = `${slot.day}:${slot.slot_key}`;
    const candidate = candidates.get(key);
    if (!candidate || failures.has(key)) {
      if (candidate) dropped.push(slot.slot_key);
      continue;
    }
    const written = output.slots.find((item) =>
      item.slot_key === slot.slot_key && item.day === slot.day
    );
    messages.push({
      key,
      message: slotMessage(
        context,
        slot,
        candidate.bubbles,
        candidate.push,
        candidate.dayTheme,
        written ? shiftedMinutes(slot.deliver_local, written.deliver_local) ?? 0 : 0,
        { shape: requestSlots.find((item) => item.slot_key === slot.slot_key && item.day === slot.day)?.shape },
      ),
    });
  }
  return {
    messages,
    dayTheme: output.day_theme,
    memoryNote: output.memory_note,
    model,
    responseId,
    fallbackUsed: false,
    dropped,
  };
}

/**
 * Plans the rest of the coach day for one user. Idempotent per state: the
 * run key is the state fingerprint, so concurrent or repeated triggers with
 * nothing new collapse onto one run.
 */
export async function runCoachPlan(
  admin: SupabaseClient,
  request: CoachPlanRequest,
  dependencies: CoachPlanDependencies = {},
): Promise<CoachPlanOutcome> {
  const now = dependencies.now?.() ?? new Date();
  const context = await (dependencies.loadContext ?? loadCoachContext)(
    admin,
    request.userId,
    { now, timezone: request.timezone ?? null },
  );
  if (!context.settings.enabled) {
    return { status: "disabled", runId: null, generated: false, messageIds: [] };
  }
  const slots = planCoachSlots({
    now,
    timezone: context.timezone,
    schedule: context.schedule,
    intensity: context.settings.intensity,
    quietHours: { start: context.settings.quietStart, end: context.settings.quietEnd },
    lastLogAt: context.lastLogAt,
    lastProactiveAt: context.lastProactiveAt,
    deliveredToday: context.proactiveDeliveredToday,
    pace: paceOf(context),
    wellbeingHold: context.wellbeingHold,
  });
  const reaction = await resolveReaction(admin, context, request);
  const fingerprint = await planFingerprint(context, slots, reaction);
  const claim = await claimCoachRun(admin, {
    userId: request.userId,
    operation: "coach_checkpoint",
    localDay: context.localDay,
    checkpointKey: `plan:${fingerprint.slice(0, 16)}`,
    triggerSource: request.trigger === "daily"
      ? "schedule"
      : request.foreground
      ? "user"
      : "event",
    scheduledFor: now,
    fingerprint,
    leaseSeconds: 150,
  });
  if (!isClaimed(claim)) {
    return {
      status: claim.status,
      runId: claim.run_id,
      generated: false,
      messageIds: [],
    };
  }

  try {
    const quiet = {
      start: parseClock(context.settings.quietStart) ?? 23 * 60,
      end: parseClock(context.settings.quietEnd) ?? 7 * 60,
    };
    const reactionNotify = !request.foreground &&
      !isQuietMinute(context.clock.minutes, quiet);
    const usageEvents: Array<ClaudeUsage> = [];
    const written = slots.length === 0 && !reaction
      ? {
        messages: [],
        dayTheme: null,
        memoryNote: null,
        model: null,
        responseId: null,
        fallbackUsed: false,
        dropped: [],
      } satisfies ModelCopy
      : await writePlanCopy(context, slots, reaction, {
        reactionNotify,
        seed: fingerprint,
        client: dependencies.client,
        onUsage: (usage) => usageEvents.push(usage),
      });
    for (const usage of usageEvents) {
      await recordCoachUsage(admin, request.userId, "coach_checkpoint", usage);
    }

    if (written.memoryNote && !context.wellbeingHold) {
      const note = written.memoryNote;
      await updateCoachMemory(
        admin,
        request.userId,
        (sections) => {
          if (Object.values(sections.notes).includes(note)) return null;
          return {
            sections: addMemoryNote(sections, note, now).sections,
            summary: `Coach note: ${note}`,
          };
        },
        { source: "coach_reply", runId: claim.run_id },
      ).catch((error) => {
        console.warn("coach_plan_memory_note_failed", { message: String(error) });
      });
    }

    const messages = written.messages.map((item) => item.message);
    const completion = await completeCoachRun(admin, {
      runId: claim.run_id,
      claimToken: claim.claim_token,
      status: messages.length > 0 ? "complete" : "skipped",
      result: {
        trigger: request.trigger,
        fingerprint,
        persona_version: COACH_PERSONA_VERSION,
        slots: slots.map((slot) => ({
          slot_key: slot.slot_key,
          day: slot.day,
          deliver_local: slot.deliver_local,
          notify: slot.notify,
        })),
        written: written.messages.map((item) => item.key),
        dropped: written.dropped,
        reaction: reaction?.subjectKey ?? null,
        fallback: written.fallbackUsed,
        day_theme: written.dayTheme,
        generated_local_time: formatClock(context.clock.minutes),
      },
      messages,
      supersedeSlotKeys: [...SLOT_KEYS],
      model: written.model,
      providerResponseId: written.responseId,
    });
    if (completion.status !== "complete" && completion.status !== "skipped") {
      return {
        status: completion.status,
        runId: claim.run_id,
        generated: false,
        messageIds: [],
      };
    }
    return {
      status: completion.status,
      runId: claim.run_id,
      generated: messages.length > 0,
      messageIds: completion.message_ids,
    };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("coach_plan_failed", { userId: request.userId, message });
    await failCoachRun(admin, claim.run_id, claim.claim_token, message).catch(
      () => undefined,
    );
    return { status: "failed", runId: claim.run_id, generated: false, messageIds: [] };
  }
}

/// Reaction notify decision exposed for tests.
export function reactionMayNotify(
  context: CoachContext,
  foreground: boolean,
): boolean {
  const quiet = {
    start: parseClock(context.settings.quietStart) ?? 23 * 60,
    end: parseClock(context.settings.quietEnd) ?? 7 * 60,
  };
  return !foreground && !isQuietMinute(context.clock.minutes, quiet);
}
