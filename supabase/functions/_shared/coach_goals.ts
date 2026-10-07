import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import { KG_PER_LB, numeric } from "./coach_context.ts";
import { addDays } from "./coach_policy.ts";
import {
  type ActivityLevel,
  calculateDeterministicTargets,
  type NutritionGoal,
  type NutritionTarget,
  type TargetEngineInput,
  validateNutritionTarget,
} from "./target_engine.ts";

/// Goal changes dictated to the coach. The target engine computes, the
/// server decides whether the change applies now (with Undo) or needs a
/// one-tap confirmation, and the model only reports what happened.

export type GoalPhase = "cut" | "lean_bulk" | "bulk" | "maintain" | "recomp";

export type GoalChangeRequest = {
  phase: GoalPhase | null;
  goal_weight: { value: number; unit: "lb" | "kg" } | null;
  goal_date: string | null;
  weekly_rate_pct: number | null;
  activity_level: ActivityLevel | null;
  training_days_per_week: number | null;
  protein_bias: "standard" | "higher" | null;
  fat_bias: "lower" | "standard" | "higher" | null;
  explicit_targets: {
    calories_kcal: number | null;
    protein_g: number | null;
    carbs_g: number | null;
    fat_g: number | null;
  } | null;
  reason: string;
};

export type GoalSnapshot = NutritionTarget & {
  goal_type: NutritionGoal;
  target_weight_kg: number | null;
  goal_date: string | null;
};

export type GoalChangeProposal = {
  status: "applied" | "needs_confirmation" | "rejected";
  change_id: string;
  before: GoalSnapshot;
  after: GoalSnapshot;
  projected_goal_date: string | null;
  warnings: string[];
  /// Engine context for the new goal, kept with the card for reference.
  rate_percent_per_week: number | null;
};

export type GoalProfile = {
  goal_type: string | null;
  target_weight_kg: number | string | null;
  goal_date: string | null;
  daily_macro_target: Record<string, unknown> | null;
  weight_kg: number | string | null;
  height_cm: number | string | null;
  activity_level: string | null;
  updated_at?: string | null;
};

const ACTIVITY_LEVELS: ActivityLevel[] = [
  "sedentary",
  "light",
  "moderate",
  "active",
  "extra_active",
];

function goalType(value: unknown): NutritionGoal {
  return value === "lose" || value === "gain" ? value : "maintain";
}

function nullableNumber(value: unknown): number | null {
  if (value === null || value === undefined || value === "") return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

export function snapshotOfProfile(profile: GoalProfile): GoalSnapshot {
  const target = profile.daily_macro_target ?? {};
  return {
    goal_type: goalType(profile.goal_type),
    target_weight_kg: nullableNumber(profile.target_weight_kg),
    goal_date: profile.goal_date ?? null,
    calories_kcal: numeric(target.calories_kcal),
    protein_g: numeric(target.protein_g),
    carbs_g: numeric(target.carbs_g),
    fat_g: numeric(target.fat_g),
  };
}

export function sameSnapshot(left: GoalSnapshot, right: GoalSnapshot): boolean {
  return left.goal_type === right.goal_type &&
    left.goal_date === right.goal_date &&
    (left.target_weight_kg === null) === (right.target_weight_kg === null) &&
    Math.abs((left.target_weight_kg ?? 0) - (right.target_weight_kg ?? 0)) < 0.05 &&
    Math.round(left.calories_kcal) === Math.round(right.calories_kcal) &&
    Math.round(left.protein_g) === Math.round(right.protein_g) &&
    Math.round(left.carbs_g) === Math.round(right.carbs_g) &&
    Math.round(left.fat_g) === Math.round(right.fat_g);
}

const PHASE_SETTINGS: Record<
  GoalPhase,
  { goal: NutritionGoal; rate: number | null; proteinBias?: "higher" }
> = {
  cut: { goal: "lose", rate: 0.5 },
  lean_bulk: { goal: "gain", rate: 0.25 },
  bulk: { goal: "gain", rate: 0.5 },
  maintain: { goal: "maintain", rate: null },
  recomp: { goal: "maintain", rate: null, proteinBias: "higher" },
};

function weeksBetween(from: string, to: string): number {
  return (Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) /
    (7 * 86_400_000);
}

function rateBounds(goal: NutritionGoal): [number, number] {
  return goal === "lose" ? [0.25, 1] : [0.1, 0.5];
}

function projectDate(
  today: string,
  currentKg: number | null,
  targetKg: number | null,
  ratePercent: number | null,
): string | null {
  if (currentKg === null || targetKg === null || !ratePercent) return null;
  const weeklyKg = currentKg * ratePercent / 100;
  if (weeklyKg <= 0) return null;
  const weeks = Math.abs(targetKg - currentKg) / weeklyKg;
  if (!Number.isFinite(weeks) || weeks > 260) return null;
  return addDays(today, Math.ceil(weeks * 7));
}

/// Fills explicit targets in: whatever he didn't name absorbs the change,
/// carbs first, then the result must pass the engine's validator.
function explicitTarget(
  base: NutritionTarget,
  explicit: NonNullable<GoalChangeRequest["explicit_targets"]>,
): NutritionTarget {
  const protein = explicit.protein_g ?? base.protein_g;
  const fat = explicit.fat_g ?? base.fat_g;
  if (explicit.calories_kcal !== null && explicit.carbs_g === null) {
    const calories = Math.round(explicit.calories_kcal / 10) * 10;
    return {
      calories_kcal: calories,
      protein_g: Math.round(protein),
      fat_g: Math.round(fat),
      carbs_g: Math.max(0, Math.round((calories - protein * 4 - fat * 9) / 4)),
    };
  }
  const carbs = explicit.carbs_g ?? base.carbs_g;
  const calories = explicit.calories_kcal ??
    Math.round((protein * 4 + carbs * 4 + fat * 9) / 10) * 10;
  if (explicit.calories_kcal !== null) {
    return {
      calories_kcal: Math.round(calories),
      protein_g: Math.round(protein),
      carbs_g: Math.round(carbs),
      fat_g: Math.round(fat),
    };
  }
  // Calories follow the named macros when no calorie number was given.
  return {
    calories_kcal: calories,
    protein_g: Math.round(protein),
    carbs_g: Math.max(0, Math.round((calories - protein * 4 - fat * 9) / 4)),
    fat_g: Math.round(fat),
  };
}

/**
 * Pure goal planner. Never throws for a bad request: unsafe or invalid
 * targets come back as `rejected` with the reason in warnings.
 */
export function planGoalChange(
  profile: GoalProfile,
  baseContext: TargetEngineInput,
  request: GoalChangeRequest,
  options: { today: string; currentWeightKg: number | null; changeId: string },
): GoalChangeProposal {
  const before = snapshotOfProfile(profile);
  const warnings: string[] = [];
  const phase = request.phase ? PHASE_SETTINGS[request.phase] : null;
  const goal = phase?.goal ?? before.goal_type;
  const targetWeightKg = request.goal_weight
    ? Math.round(
      (request.goal_weight.unit === "lb"
        ? request.goal_weight.value * KG_PER_LB
        : request.goal_weight.value) * 100,
    ) / 100
    : before.target_weight_kg;
  const currentKg = options.currentWeightKg ?? nullableNumber(profile.weight_kg) ??
    baseContext.weight_kg;
  let goalDate = request.goal_date ?? (request.phase ? null : before.goal_date);
  if (goalDate && !/^\d{4}-\d{2}-\d{2}$/u.test(goalDate)) goalDate = null;

  let rate: number | null = request.weekly_rate_pct ?? phase?.rate ??
    baseContext.goal_rate_percent_per_week;
  if (goalDate && goal !== "maintain" && currentKg && targetWeightKg) {
    const weeks = weeksBetween(options.today, goalDate);
    if (weeks <= 0) {
      warnings.push("That goal date has already passed, so the pace stays as set.");
      goalDate = null;
    } else {
      rate = Math.abs(targetWeightKg - currentKg) / currentKg * 100 / weeks;
    }
  }
  if (goal !== "maintain" && rate !== null) {
    const [minimum, maximum] = rateBounds(goal);
    if (rate > maximum) {
      warnings.push(
        goal === "gain"
          ? `Gain pace capped at ${maximum}% of body weight per week so it stays mostly muscle.`
          : `Loss pace capped at ${maximum}% of body weight per week.`,
      );
      rate = maximum;
    } else if (rate < minimum) {
      rate = minimum;
    }
  }
  if (
    goal === "gain" && targetWeightKg !== null && currentKg !== null &&
    targetWeightKg < currentKg
  ) {
    warnings.push("The goal weight is below the current weight for a gain phase.");
  }
  if (
    goal === "lose" && targetWeightKg !== null && currentKg !== null &&
    targetWeightKg > currentKg
  ) {
    warnings.push("The goal weight is above the current weight for a cut.");
  }

  const activity = request.activity_level &&
      ACTIVITY_LEVELS.includes(request.activity_level)
    ? request.activity_level
    : baseContext.activity_level;
  const engineInput: TargetEngineInput = {
    ...baseContext,
    goal_type: goal,
    weight_kg: currentKg,
    activity_level: activity,
    training_days_per_week: request.training_days_per_week ??
      baseContext.training_days_per_week,
    goal_rate_percent_per_week: goal === "maintain" ? null : rate,
    protein_bias: request.protein_bias ?? phase?.proteinBias ?? baseContext.protein_bias,
    fat_bias: request.fat_bias ?? baseContext.fat_bias,
  };

  let target: NutritionTarget;
  try {
    const computed = calculateDeterministicTargets(engineInput).target;
    target = request.explicit_targets
      ? validateNutritionTarget(
        explicitTarget(computed, request.explicit_targets),
        currentKg,
      )
      : computed;
  } catch (error) {
    return {
      status: "rejected",
      change_id: options.changeId,
      before,
      after: before,
      projected_goal_date: null,
      warnings: [
        ...warnings,
        error instanceof Error ? error.message : "Those targets are outside the supported range.",
      ],
      rate_percent_per_week: rate,
    };
  }

  const projected = goal === "maintain"
    ? null
    : projectDate(options.today, currentKg, targetWeightKg, rate);
  const after: GoalSnapshot = {
    ...target,
    goal_type: goal,
    target_weight_kg: targetWeightKg,
    goal_date: goalDate ?? projected,
  };
  const needsConfirmation = goal !== before.goal_type ||
    Math.abs(after.calories_kcal - before.calories_kcal) > 300 ||
    Math.abs(after.protein_g - before.protein_g) > 30 ||
    warnings.length > 0;
  return {
    status: needsConfirmation ? "needs_confirmation" : "applied",
    change_id: options.changeId,
    before,
    after,
    projected_goal_date: projected,
    warnings,
    rate_percent_per_week: rate,
  };
}

/// Best available engine inputs: the applied onboarding context when one
/// exists, otherwise the profile with neutral defaults.
export async function loadTargetContext(
  admin: SupabaseClient,
  userId: string,
  profile: GoalProfile,
): Promise<TargetEngineInput> {
  const fallback: TargetEngineInput = {
    goal_type: goalType(profile.goal_type),
    height_cm: nullableNumber(profile.height_cm),
    weight_kg: nullableNumber(profile.weight_kg),
    activity_level: ACTIVITY_LEVELS.includes(profile.activity_level as ActivityLevel)
      ? profile.activity_level as ActivityLevel
      : "moderate",
    age_years: null,
    sex_for_equation: "unspecified",
    training_days_per_week: null,
    goal_rate_percent_per_week: null,
    protein_bias: "standard",
    fat_bias: "standard",
  };
  try {
    const { data, error } = await admin.from("onboarding_analyses")
      .select("recommendation,status,created_at")
      .eq("user_id", userId)
      .eq("status", "applied")
      .order("created_at", { ascending: false })
      .limit(1);
    if (error) throw error;
    const recommendation = (data?.[0] as { recommendation?: unknown } | undefined)
      ?.recommendation as Record<string, unknown> | undefined;
    const stored = recommendation?._target_context as
      | Partial<TargetEngineInput>
      | undefined;
    if (!stored || typeof stored !== "object") return fallback;
    return {
      ...fallback,
      age_years: nullableNumber(stored.age_years),
      sex_for_equation: stored.sex_for_equation === "male" ||
          stored.sex_for_equation === "female"
        ? stored.sex_for_equation
        : "unspecified",
      height_cm: fallback.height_cm ?? nullableNumber(stored.height_cm),
      training_days_per_week: nullableNumber(stored.training_days_per_week),
      goal_rate_percent_per_week: nullableNumber(stored.goal_rate_percent_per_week),
      protein_bias: stored.protein_bias === "higher" ? "higher" : "standard",
      fat_bias: stored.fat_bias === "lower" || stored.fat_bias === "higher"
        ? stored.fat_bias
        : "standard",
    };
  } catch (error) {
    console.warn("coach_target_context_unavailable", { message: String(error) });
    return fallback;
  }
}

export const GOAL_PROFILE_COLUMNS =
  "goal_type,target_weight_kg,goal_date,daily_macro_target,weight_kg,height_cm,activity_level,goal_started_on,goal_start_weight_kg,updated_at";

/**
 * Writes `next` only if the profile still matches `expected` (optimistic on
 * the snapshot itself). The profile trigger snapshots daily_targets.
 */
export async function applyGoalSnapshot(
  admin: SupabaseClient,
  userId: string,
  expected: GoalSnapshot,
  next: GoalSnapshot,
  options: { today: string; currentWeightKg: number | null },
): Promise<"applied" | "conflict"> {
  const { data, error } = await admin.from("profiles")
    .select(GOAL_PROFILE_COLUMNS)
    .eq("user_id", userId)
    .maybeSingle();
  if (error) throw error;
  if (!data) return "conflict";
  const current = data as GoalProfile & {
    goal_started_on?: string | null;
    goal_start_weight_kg?: number | string | null;
  };
  if (!sameSnapshot(snapshotOfProfile(current), expected)) return "conflict";
  const goalChanged = expected.goal_type !== next.goal_type;
  const update: Record<string, unknown> = {
    goal_type: next.goal_type,
    target_weight_kg: next.target_weight_kg,
    goal_date: next.goal_date,
    daily_macro_target: {
      calories_kcal: next.calories_kcal,
      protein_g: next.protein_g,
      carbs_g: next.carbs_g,
      fat_g: next.fat_g,
    },
  };
  if (goalChanged) {
    update.goal_started_on = options.today;
    if (options.currentWeightKg !== null) {
      update.goal_start_weight_kg = options.currentWeightKg;
    }
  }
  let query = admin.from("profiles").update(update).eq("user_id", userId);
  if (current.updated_at) query = query.eq("updated_at", current.updated_at);
  const { data: updated, error: updateError } = await query.select("user_id")
    .maybeSingle();
  if (updateError) throw updateError;
  return updated ? "applied" : "conflict";
}

/// Card payload for a goal_change message (SPEC §4).
export function goalChangeCard(
  proposal: GoalChangeProposal,
  status: "needs_confirmation" | "applied" | "undone" | "discarded",
): Record<string, unknown> {
  return {
    change_id: proposal.change_id,
    status,
    before: proposal.before,
    after: proposal.after,
    projected_goal_date: proposal.projected_goal_date,
    warnings: proposal.warnings,
  };
}
