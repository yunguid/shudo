import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import { createActivityFromText } from "./activity_analysis.ts";
import type { Anthropic, BetaToolUnion } from "./claude.ts";
import { mergeBioDictation, mergeSchedule } from "./coach_bio.ts";
import {
  buildStatePack,
  type CoachCheckinRow,
  type CoachContext,
  KG_PER_LB,
  LB_PER_KG,
  loadCoachContext,
  logCompleteness,
  useImperial,
  weightTrendOf,
} from "./coach_context.ts";
import { assertCoachText } from "./coach_copy.ts";
import type { CoachJobRequest } from "./coach_dispatch.ts";
import {
  applyGoalSnapshot,
  type GoalChangeRequest,
  goalChangeCard,
  loadTargetContext,
  planGoalChange,
} from "./coach_goals.ts";
import {
  addMemoryNote,
  applyBioChanges,
  BIO_SECTION_KEYS,
  type BioChange,
  type BioSectionKey,
  updateCoachMemory,
} from "./coach_memory.ts";
import {
  addDays,
  type CoachSchedule,
  formatClock,
  localWallTimeToInstant,
  parseClock,
} from "./coach_policy.ts";
import type { CoachMessageInput } from "./coach_rpc.ts";
import { createTextEntry } from "./entry_capture.ts";
import type { LocationContext, NearbyStore } from "./nearby_food.ts";
import { researchNearbyFood } from "./nearby_food.ts";

/// The coach's tools in chat. Each is strict (every field required, null
/// for "not said"), validated again here, and grounded: numbers on cards
/// come from the server, never from the model.

export type CoachToolServices = {
  createActivityFromText: typeof createActivityFromText;
  researchNearbyFood: typeof researchNearbyFood;
  dispatchCoachJob: (job: CoachJobRequest) => Promise<void>;
  createTextEntry: typeof createTextEntry;
  mergeBioDictation: typeof mergeBioDictation;
};

export type CoachToolEnvironment = {
  admin: SupabaseClient;
  userId: string;
  timezone: string;
  localDay: string;
  now: Date;
  clientRequestId: string;
  userMessageId: string | null;
  userText: string;
  location: LocationContext | null;
  context: CoachContext;
  /// Mutating tools only run on turns that carry Luke's own words.
  allowMutations: boolean;
  client?: Anthropic;
  dispatchEntry: (entryId: string) => void;
  services: CoachToolServices;
  /// Cards produced during the turn, persisted with the run's completion.
  cards: CoachMessageInput[];
  /// Tool results whose numbers the reply may cite.
  facts: unknown[];
  /// What the turn changed (drives a plan refresh afterwards).
  changed: Set<string>;
};

export type CoachToolResult = { content: string; isError: boolean };

export const COACH_TOOL_TIMEOUTS_MS: Record<string, number> = {
  update_bio: 50_000,
  find_nearby_food: 70_000,
  log_meal_text: 20_000,
  log_activity_text: 20_000,
  update_goals: 15_000,
};
export const DEFAULT_TOOL_TIMEOUT_MS = 10_000;

export const COACH_TOOL_STATUS_LABELS: Record<string, string> = {
  get_day_state: "Checking today's log…",
  get_weight_trend: "Pulling up your weight trend…",
  update_goals: "Running the numbers…",
  update_bio: "Updating your bio…",
  remember: "Making a note…",
  log_meal_text: "Logging that meal…",
  log_activity_text: "Logging the session…",
  log_weight: "Logging your weight…",
  find_nearby_food: "Checking what's near you…",
  draft_training_plan: "Starting your training plan…",
  request_physique_review: "Queuing a physique review…",
  web_search: "Looking that up…",
};

export const MUTATING_COACH_TOOLS: ReadonlySet<string> = new Set([
  "update_goals",
  "update_bio",
  "remember",
  "log_meal_text",
  "log_activity_text",
  "log_weight",
  "find_nearby_food",
  "draft_training_plan",
  "request_physique_review",
]);

const DATE = { type: "string", description: "Local day, YYYY-MM-DD." };
const nullable = (schema: Record<string, unknown>) => ({
  anyOf: [schema, { type: "null" }],
});

function tool(
  name: string,
  description: string,
  properties: Record<string, unknown>,
): BetaToolUnion {
  return {
    name,
    description,
    strict: true,
    input_schema: {
      type: "object",
      additionalProperties: false,
      properties,
      required: Object.keys(properties),
    },
  } as BetaToolUnion;
}

/// Static and sorted by name so the tools prefix caches across turns.
export const COACH_TOOL_DEFINITIONS: BetaToolUnion[] = [
  tool(
    "draft_training_plan",
    "Start building (or rebuilding) Luke's training plan in the background. Returns immediately; the plan arrives as a card. Use when he asks for a plan or a change to his split.",
    { instructions: nullable({ type: "string", description: "His constraints and wishes, in his words." }) },
  ),
  tool(
    "find_nearby_food",
    "Research food options near Luke right now that fit what's left of his day. Posts a snack card. Use when he asks what to grab nearby.",
    { query: nullable({ type: "string", description: "What he's in the mood for, if he said." }) },
  ),
  tool(
    "get_day_state",
    "Read one day's log: meals with macros, workouts, check-in, targets, and what's left.",
    { local_day: DATE },
  ),
  tool(
    "get_weight_trend",
    "Read the weigh-in trend over a window: readings, smoothed weekly change, and projected goal date.",
    { window_days: { type: "integer", enum: [14, 30, 90] } },
  ),
  tool(
    "log_activity_text",
    "Log a workout or activity Luke described (lifts with sets/reps/weights, cardio, sports). The app analyzes it and posts a card.",
    { description: { type: "string" }, local_day: DATE },
  ),
  tool(
    "log_meal_text",
    "Log a meal or snack Luke described. The app estimates macros in the background and posts a meal card; never state macros for it yourself.",
    {
      description: { type: "string", description: "Everything he said he ate, with quantities." },
      local_day: DATE,
      time_local: nullable({ type: "string", description: "HH:MM if he said when." }),
    },
  ),
  tool(
    "log_weight",
    "Log a scale weight for a day.",
    {
      value: { type: "number" },
      unit: { type: "string", enum: ["lb", "kg"] },
      local_day: DATE,
    },
  ),
  tool(
    "remember",
    "Keep a short fact about Luke on file (preferences, commitments, wins, running jokes). Not for numbers the app tracks.",
    {
      note: { type: "string" },
      kind: { type: "string", enum: ["fact", "commitment", "win", "running_joke"] },
    },
  ),
  tool(
    "request_physique_review",
    "Queue a physique review of his check-in photos. Returns immediately; feedback arrives as a card.",
    { local_day: nullable(DATE) },
  ),
  tool(
    "update_bio",
    "Update Luke's bio. merge_current_message folds his current message into the bio (for dictated life, schedule, training, or food details). patch applies small explicit edits.",
    {
      mode: { type: "string", enum: ["merge_current_message", "patch"] },
      patch: nullable({
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          properties: {
            section: { type: "string", enum: [...BIO_SECTION_KEYS] },
            op: { type: "string", enum: ["add", "replace", "remove"] },
            text: nullable({ type: "string" }),
          },
          required: ["section", "op", "text"],
        },
      }),
    },
  ),
  tool(
    "update_goals",
    "Change Luke's goal (phase, goal weight, date, pace, activity, training days, macro biases or explicit targets). The app computes and bounds the targets and decides whether to apply now or ask him to confirm on a card. Null means unchanged.",
    {
      phase: nullable({ type: "string", enum: ["cut", "lean_bulk", "bulk", "maintain", "recomp"] }),
      goal_weight: nullable({
        type: "object",
        additionalProperties: false,
        properties: { value: { type: "number" }, unit: { type: "string", enum: ["lb", "kg"] } },
        required: ["value", "unit"],
      }),
      goal_date: nullable(DATE),
      weekly_rate_pct: nullable({ type: "number" }),
      activity_level: nullable({
        type: "string",
        enum: ["sedentary", "light", "moderate", "active", "extra_active"],
      }),
      training_days_per_week: nullable({ type: "integer" }),
      protein_bias: nullable({ type: "string", enum: ["standard", "higher"] }),
      fat_bias: nullable({ type: "string", enum: ["lower", "standard", "higher"] }),
      explicit_targets: nullable({
        type: "object",
        additionalProperties: false,
        properties: {
          calories_kcal: nullable({ type: "integer" }),
          protein_g: nullable({ type: "integer" }),
          carbs_g: nullable({ type: "integer" }),
          fat_g: nullable({ type: "integer" }),
        },
        required: ["calories_kcal", "protein_g", "carbs_g", "fat_g"],
      }),
      reason: { type: "string" },
    },
  ),
];

class ToolInputError extends Error {}

function input(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ToolInputError("Tool input must be an object");
  }
  return value as Record<string, unknown>;
}

function str(value: unknown, label: string, max = 4000): string {
  if (typeof value !== "string" || !value.trim()) {
    throw new ToolInputError(`${label} is required`);
  }
  return value.trim().slice(0, max);
}

function optionalStr(value: unknown, max = 4000): string | null {
  return typeof value === "string" && value.trim() ? value.trim().slice(0, max) : null;
}

function optionalNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function dayInput(environment: CoachToolEnvironment, value: unknown): string {
  const day = typeof value === "string" ? value.trim() : "";
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(day)) {
    throw new ToolInputError("local_day must be YYYY-MM-DD");
  }
  if (day > addDays(environment.localDay, 1) || day < addDays(environment.localDay, -90)) {
    throw new ToolInputError("local_day must be within the last 90 days");
  }
  return day;
}

/// Stable request ids for tool side effects: the same chat request and
/// description never create two meals.
export async function deterministicUuid(seed: string): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(seed)),
  ).slice(0, 16);
  digest[6] = (digest[6] & 0x0f) | 0x50;
  digest[8] = (digest[8] & 0x3f) | 0x80;
  const hex = Array.from(digest).map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${
    hex.slice(20)
  }`;
}

function ok(value: unknown): CoachToolResult {
  return { content: JSON.stringify(value), isError: false };
}

function fail(message: string): CoachToolResult {
  return { content: JSON.stringify({ error: message }), isError: true };
}

async function getDayState(
  environment: CoachToolEnvironment,
  raw: Record<string, unknown>,
): Promise<CoachToolResult> {
  const day = dayInput(environment, raw.local_day);
  const context = day === environment.context.localDay
    ? environment.context
    : await loadCoachContext(environment.admin, environment.userId, {
      now: environment.now,
      timezone: environment.timezone,
      localDay: day,
      threadLimit: 40,
    });
  const pack = buildStatePack(context);
  const result = {
    local_day: day,
    targets: pack.targets,
    today: pack.today,
    log_completeness: logCompleteness(context),
    coach_texts: context.thread.filter((row) => row.local_day === day && row.role === "coach")
      .slice(-8).map((row) => row.body.slice(0, 280)),
  };
  environment.facts.push(result);
  return ok(result);
}

async function getWeightTrend(
  environment: CoachToolEnvironment,
  raw: Record<string, unknown>,
): Promise<CoachToolResult> {
  const window = [14, 30, 90].includes(Number(raw.window_days)) ? Number(raw.window_days) : 30;
  const { data, error } = await environment.admin.from("weight_checkins")
    .select("id,local_day,weight_kg,progress_photo_path,updated_at")
    .eq("user_id", environment.userId)
    .gte("local_day", addDays(environment.localDay, -window + 1))
    .lte("local_day", environment.localDay)
    .order("local_day", { ascending: true })
    .limit(120);
  if (error) throw error;
  const rows = (data ?? []) as CoachCheckinRow[];
  const trend = weightTrendOf(rows, environment.localDay, window);
  const imperial = useImperial(environment.context);
  const display = (kg: number | null) =>
    kg === null ? null : Math.round((imperial ? kg * LB_PER_KG : kg) * 10) / 10;
  const targetKg = Number(environment.context.profile.target_weight_kg);
  let projected: string | null = null;
  if (
    trend.change_per_week_kg && trend.latest_kg !== null && Number.isFinite(targetKg) &&
    Math.sign(targetKg - trend.latest_kg) === Math.sign(trend.change_per_week_kg)
  ) {
    const weeks = (targetKg - trend.latest_kg) / trend.change_per_week_kg;
    if (weeks > 0 && weeks < 260) projected = addDays(environment.localDay, Math.ceil(weeks * 7));
  }
  const result = {
    unit: imperial ? "lb" : "kg",
    window_days: window,
    readings: trend.readings,
    latest: display(trend.latest_kg),
    change_per_week: display(trend.change_per_week_kg),
    goal_weight: display(Number.isFinite(targetKg) ? targetKg : null),
    projected_goal_date: projected,
    points: rows.filter((row) => row.weight_kg !== null).map((row) => ({
      day: row.local_day,
      weight: display(Number(row.weight_kg)),
    })),
    note: trend.change_per_week_kg === null
      ? "Not enough weigh-ins for a trend yet (needs 4 over a week)."
      : null,
  };
  environment.facts.push(result);
  return ok(result);
}

async function updateGoals(
  environment: CoachToolEnvironment,
  raw: Record<string, unknown>,
): Promise<CoachToolResult> {
  const weight = raw.goal_weight && typeof raw.goal_weight === "object"
    ? raw.goal_weight as Record<string, unknown>
    : null;
  const explicit = raw.explicit_targets && typeof raw.explicit_targets === "object"
    ? raw.explicit_targets as Record<string, unknown>
    : null;
  const request: GoalChangeRequest = {
    phase: (["cut", "lean_bulk", "bulk", "maintain", "recomp"] as const)
      .find((phase) => phase === raw.phase) ?? null,
    goal_weight: weight && optionalNumber(weight.value) !== null
      ? { value: Number(weight.value), unit: weight.unit === "kg" ? "kg" : "lb" }
      : null,
    goal_date: optionalStr(raw.goal_date, 10),
    weekly_rate_pct: optionalNumber(raw.weekly_rate_pct),
    activity_level: (["sedentary", "light", "moderate", "active", "extra_active"] as const)
      .find((level) => level === raw.activity_level) ?? null,
    training_days_per_week: optionalNumber(raw.training_days_per_week),
    protein_bias: raw.protein_bias === "higher" || raw.protein_bias === "standard"
      ? raw.protein_bias
      : null,
    fat_bias: raw.fat_bias === "lower" || raw.fat_bias === "standard" ||
        raw.fat_bias === "higher"
      ? raw.fat_bias
      : null,
    explicit_targets: explicit
      ? {
        calories_kcal: optionalNumber(explicit.calories_kcal),
        protein_g: optionalNumber(explicit.protein_g),
        carbs_g: optionalNumber(explicit.carbs_g),
        fat_g: optionalNumber(explicit.fat_g),
      }
      : null,
    reason: optionalStr(raw.reason, 500) ?? "",
  };
  const profile = environment.context.profile;
  const baseContext = await loadTargetContext(environment.admin, environment.userId, profile);
  const currentWeightKg = environment.context.weightTrend.latest_kg ??
    (Number.isFinite(Number(profile.weight_kg)) && profile.weight_kg !== null
      ? Number(profile.weight_kg)
      : null);
  const proposal = planGoalChange(profile, baseContext, request, {
    today: environment.localDay,
    currentWeightKg,
    changeId: crypto.randomUUID(),
  });
  let status: "applied" | "needs_confirmation" | "rejected" = proposal.status;
  if (status === "applied") {
    const applied = await applyGoalSnapshot(
      environment.admin,
      environment.userId,
      proposal.before,
      proposal.after,
      { today: environment.localDay, currentWeightKg },
    );
    if (applied === "conflict") status = "needs_confirmation";
    else environment.changed.add("goals");
  }
  if (status !== "rejected") {
    environment.cards.push({
      kind: "goal_change",
      body: status === "applied" ? "Goals updated." : "New goals, ready when you are.",
      payload: goalChangeCard({ ...proposal, status }, status),
    });
  }
  const imperial = useImperial(environment.context);
  const toDisplay = (kg: number | null) =>
    kg === null ? null : Math.round((imperial ? kg * LB_PER_KG : kg) * 10) / 10;
  const result = {
    status,
    before: { ...proposal.before, target_weight: toDisplay(proposal.before.target_weight_kg) },
    after: { ...proposal.after, target_weight: toDisplay(proposal.after.target_weight_kg) },
    weight_unit: imperial ? "lb" : "kg",
    projected_goal_date: proposal.projected_goal_date,
    weekly_rate_pct: proposal.rate_percent_per_week,
    warnings: proposal.warnings,
    next_step: status === "needs_confirmation"
      ? "He confirms with the Apply button on the card."
      : status === "applied"
      ? "Applied now; the card has Undo."
      : "Nothing changed.",
  };
  environment.facts.push(result);
  return ok(result);
}

async function updateBio(
  environment: CoachToolEnvironment,
  raw: Record<string, unknown>,
): Promise<CoachToolResult> {
  let changes: BioChange[] = [];
  let schedule: CoachSchedule | null = null;
  let goalSignals: unknown = null;
  let unclear: string[] = [];
  if (raw.mode === "patch") {
    const patch = Array.isArray(raw.patch) ? raw.patch : [];
    changes = patch.flatMap((item): BioChange[] => {
      if (!item || typeof item !== "object") return [];
      const value = item as Record<string, unknown>;
      if (!BIO_SECTION_KEYS.includes(value.section as BioSectionKey)) return [];
      if (value.op !== "add" && value.op !== "replace" && value.op !== "remove") return [];
      const text = optionalStr(value.text, 2000);
      if (value.op !== "remove" && !text) return [];
      return [{
        section: value.section as BioSectionKey,
        op: value.op,
        text,
        summary: `${value.op === "remove" ? "Removed" : "Updated"} ${value.section}`,
      }];
    });
  } else {
    if (!environment.userText.trim()) throw new ToolInputError("Nothing to merge");
    const memory = environment.context.memory;
    const merged = await environment.services.mergeBioDictation(
      memory?.sections ?? { bio: {}, notes: {}, schedule: {}, equipment: [] },
      environment.userText,
      { client: environment.client },
    );
    changes = merged.changes;
    schedule = merged.schedule;
    goalSignals = merged.goalSignals;
    unclear = merged.unclear;
  }
  if (changes.length === 0 && !schedule) {
    return ok({ status: "no_changes", unclear });
  }
  const summary = changes.map((change) => change.summary).join("; ") ||
    "Schedule updated";
  const saved = await updateCoachMemory(
    environment.admin,
    environment.userId,
    (sections) => ({
      sections: {
        ...applyBioChanges(sections, changes),
        schedule: mergeSchedule(sections.schedule, schedule),
      },
      summary,
    }),
    { source: "coach_reply", messageId: environment.userMessageId },
  );
  if (saved.status !== "saved") return fail("The bio changed at the same time; try again.");
  environment.changed.add("bio");
  environment.cards.push({
    kind: "profile_update",
    body: "Bio updated.",
    payload: {
      change_id: crypto.randomUUID(),
      status: "applied",
      memory_version: saved.version,
      undo_version: saved.previousVersion,
      changes: [
        ...changes.map((change) => ({
          section: change.section,
          op: change.op,
          summary: change.summary,
        })),
        ...(schedule
          ? [{ section: "schedule", op: "replace", summary: "Schedule times updated" }]
          : []),
      ],
    },
  });
  return ok({
    status: "saved",
    changes: changes.map((change) => change.summary),
    schedule_updated: Boolean(schedule),
    goal_signals: goalSignals,
    unclear,
  });
}

async function remember(
  environment: CoachToolEnvironment,
  raw: Record<string, unknown>,
): Promise<CoachToolResult> {
  const note = str(raw.note, "note", 200);
  const kind = typeof raw.kind === "string" ? raw.kind : "fact";
  const saved = await updateCoachMemory(
    environment.admin,
    environment.userId,
    (sections) => {
      const text = kind === "fact" ? note : `${kind.replace("_", " ")}: ${note}`;
      if (Object.values(sections.notes).includes(text)) return null;
      return {
        sections: addMemoryNote(sections, text, environment.now).sections,
        summary: `Remembered: ${text}`,
      };
    },
    { source: "coach_reply", messageId: environment.userMessageId },
  );
  if (saved.status === "conflict" || saved.status === "stale") {
    return fail("Couldn't save that note; try again.");
  }
  environment.changed.add("memory");
  return ok({ saved: true });
}

async function logMealText(
  environment: CoachToolEnvironment,
  raw: Record<string, unknown>,
): Promise<CoachToolResult> {
  const description = str(raw.description, "description", 4000);
  const day = dayInput(environment, raw.local_day);
  const time = parseClock(optionalStr(raw.time_local, 5));
  let occurredAt: string | null = null;
  if (time !== null) {
    const instant = localWallTimeToInstant(day, time, environment.timezone);
    occurredAt = new Date(Math.min(instant.getTime(), environment.now.getTime())).toISOString();
  }
  const clientRequestId = await deterministicUuid(
    `${environment.clientRequestId}:meal:${day}:${description.toLowerCase()}`,
  );
  const created = await environment.services.createTextEntry(
    environment.admin,
    environment.userId,
    { clientRequestId, localDay: day, timezone: environment.timezone, text: description, occurredAt },
    environment.dispatchEntry,
  );
  // The meal shows in the day thread as its own card; the coach reacts with
  // a meal_ack once the estimate lands (entry finalize hook), never twice.
  if (!created.duplicate) environment.changed.add("meal");
  return ok({
    status: created.status,
    entry_id: created.entryId,
    note: "The estimate lands in about a minute on the meal card. Don't state macros for it.",
  });
}

async function logActivityText(
  environment: CoachToolEnvironment,
  raw: Record<string, unknown>,
): Promise<CoachToolResult> {
  const description = str(raw.description, "description", 4000);
  const day = dayInput(environment, raw.local_day);
  const created = await environment.services.createActivityFromText(
    environment.admin,
    environment.userId,
    {
      clientRequestId: await deterministicUuid(
        `${environment.clientRequestId}:activity:${day}:${description.toLowerCase()}`,
      ),
      localDay: day,
      timezone: environment.timezone,
      text: description,
      source: "coach_chat",
      sourceMessageId: environment.userMessageId,
    },
  );
  // Like meals: the activity card is in the thread already and the
  // workout_ack reaction follows its analysis.
  if (!created.duplicate) environment.changed.add("activity");
  return ok({
    status: "processing",
    activity_id: created.activityId,
    note: "The breakdown and any PRs land on the workout card shortly.",
  });
}

async function logWeight(
  environment: CoachToolEnvironment,
  raw: Record<string, unknown>,
): Promise<CoachToolResult> {
  const value = optionalNumber(raw.value);
  if (value === null) throw new ToolInputError("value is required");
  const day = dayInput(environment, raw.local_day);
  const kg = Math.round((raw.unit === "kg" ? value : value * KG_PER_LB) * 100) / 100;
  if (kg < 20 || kg > 500) throw new ToolInputError("That weight is outside the supported range");
  const { error } = await environment.admin.from("weight_checkins")
    .upsert(
      { user_id: environment.userId, local_day: day, weight_kg: kg },
      { onConflict: "user_id,local_day" },
    );
  if (error) throw error;
  environment.changed.add("weight");
  environment.cards.push({
    kind: "weigh_in_ack",
    body: "Weight logged.",
    payload: { local_day: day, weight_kg: kg },
    local_day: day,
  });
  const result = {
    saved: true,
    local_day: day,
    weight: Math.round(value * 10) / 10,
    unit: raw.unit === "kg" ? "kg" : "lb",
  };
  environment.facts.push(result);
  return ok(result);
}

function locationFromDevice(environment: CoachToolEnvironment): LocationContext | null {
  const device = environment.context.device;
  if (!device || device.nearby.length === 0) return null;
  const stores = device.nearby.filter((item): item is NearbyStore =>
    Boolean(item) && typeof item === "object" &&
    typeof (item as NearbyStore).name === "string" &&
    typeof (item as NearbyStore).ref === "string"
  ).slice(0, 12);
  if (stores.length === 0) return null;
  return {
    captured_at: device.nearby_captured_at ?? environment.now.toISOString(),
    quality: "approximate",
    locality: {
      city: device.city,
      region: device.region,
      country: device.country_code,
      timezone: device.timezone ?? environment.timezone,
    },
    stores,
  };
}

async function findNearbyFood(
  environment: CoachToolEnvironment,
  raw: Record<string, unknown>,
): Promise<CoachToolResult> {
  if (!environment.context.settings.locationRecs) {
    return ok({ status: "disabled", note: "Nearby recommendations are off in settings." });
  }
  const location = environment.location ?? locationFromDevice(environment);
  if (!location || location.stores.length === 0) {
    return ok({ status: "no_location", note: "No recent nearby places from his phone." });
  }
  const remaining = environment.context.remaining;
  const payload = await environment.services.researchNearbyFood(
    environment.admin,
    environment.userId,
    {
      localDay: environment.localDay,
      timezone: environment.timezone,
      localTime: formatClock(environment.context.clock.minutes),
      location,
      query: optionalStr(raw.query, 200),
      remaining: {
        calories_kcal: Math.max(0, remaining.calories_kcal),
        protein_g: Math.max(0, remaining.protein_g),
        carbs_g: Math.max(0, remaining.carbs_g),
        fat_g: Math.max(0, remaining.fat_g),
      },
    },
  );
  environment.facts.push(payload);
  let headline = "A few options nearby.";
  try {
    headline = assertCoachText(payload.headline, {
      mode: "snack_recommendation",
      profanity: environment.context.settings.profanity,
      emojiAllowed: false,
      allowedFigures: [...collectFigures(payload)],
      pushCapable: false,
    }, "snack_rec.headline");
  } catch {
    // The card still carries the vetted options; only the line is replaced.
  }
  environment.cards.push({
    kind: "snack_rec",
    body: headline,
    payload: { ...payload, headline, rec_id: crypto.randomUUID() },
  });
  return ok({
    status: "ok",
    verdict: payload.verdict,
    options: payload.options.map((option) => ({
      store_name: option.store_name,
      walk_minutes: option.walk_minutes,
      items: option.items.map((item) => ({
        name: item.name,
        brand: item.brand ?? null,
        serving: item.serving,
        calories_kcal: item.calories_kcal,
        protein_g: item.protein_g,
      })),
      combined: option.combined,
      remaining_after: option.remaining_after,
    })),
  });
}

function collectFigures(value: unknown, into: Set<number> = new Set()): Set<number> {
  if (typeof value === "number" && Number.isFinite(value)) into.add(value);
  else if (Array.isArray(value)) value.forEach((item) => collectFigures(item, into));
  else if (value && typeof value === "object") {
    Object.values(value).forEach((item) => collectFigures(item, into));
  }
  return into;
}

async function draftTrainingPlanTool(
  environment: CoachToolEnvironment,
  raw: Record<string, unknown>,
): Promise<CoachToolResult> {
  await environment.services.dispatchCoachJob({
    job: "training_plan",
    user_id: environment.userId,
    payload: {
      instructions: optionalStr(raw.instructions, 2000),
      reason: environment.context.trainingPlan ? "user_request" : "first_plan",
    },
  });
  return ok({ status: "started", note: "The plan arrives as a card in a minute or two." });
}

async function requestPhysiqueReview(
  environment: CoachToolEnvironment,
  raw: Record<string, unknown>,
): Promise<CoachToolResult> {
  if (!environment.context.settings.physiqueReview) {
    return ok({ status: "disabled", note: "Photo reviews are off in settings." });
  }
  const day = raw.local_day === null || raw.local_day === undefined
    ? environment.localDay
    : dayInput(environment, raw.local_day);
  await environment.services.dispatchCoachJob({
    job: "body_review",
    user_id: environment.userId,
    payload: { anchor_day: day, kind: "on_demand" },
  });
  return ok({ status: "started", note: "Feedback arrives as a card shortly." });
}

const HANDLERS: Record<
  string,
  (environment: CoachToolEnvironment, raw: Record<string, unknown>) => Promise<CoachToolResult>
> = {
  draft_training_plan: draftTrainingPlanTool,
  find_nearby_food: findNearbyFood,
  get_day_state: getDayState,
  get_weight_trend: getWeightTrend,
  log_activity_text: logActivityText,
  log_meal_text: logMealText,
  log_weight: logWeight,
  remember,
  request_physique_review: requestPhysiqueReview,
  update_bio: updateBio,
  update_goals: updateGoals,
};

/** Runs one custom tool call. Failures come back as is_error results. */
export async function executeCoachTool(
  name: string,
  rawInput: unknown,
  environment: CoachToolEnvironment,
): Promise<CoachToolResult> {
  const handler = HANDLERS[name];
  if (!handler) return fail(`Unknown tool ${name}`);
  if (MUTATING_COACH_TOOLS.has(name) && !environment.allowMutations) {
    return fail("That action needs Luke's own request in this message.");
  }
  try {
    return await handler(environment, input(rawInput));
  } catch (error) {
    if (error instanceof ToolInputError) return fail(error.message);
    console.warn("coach_tool_failed", {
      tool: name,
      message: String((error as Error)?.message ?? error).slice(0, 300),
    });
    return fail(
      error instanceof Error && /not available yet/u.test(error.message)
        ? error.message
        : "That didn't go through. Tell him to try again in a bit.",
    );
  }
}
