/// Deterministic workout energy estimate. The model extracts facts (kind,
/// intensity, duration, device readouts); this module turns them into a burn
/// number so the arithmetic is reproducible, testable, and never invented.
///
/// Order of evidence:
/// 1. Device "active" calories (Watch, Strava) as reported; gym consoles are
///    discounted because they overestimate.
/// 2. Device "total" calories minus resting burn for the session.
/// 3. MET table: net active kcal = (MET − 1) × body kg × hours.
/// Body weight: latest weigh-in on/before the day → profile → 75 kg.

export type ActivityKind =
  | "strength"
  | "cardio"
  | "walk"
  | "run"
  | "cycle"
  | "swim"
  | "hiit"
  | "sport"
  | "mobility"
  | "other";

export const ACTIVITY_KINDS: readonly ActivityKind[] = [
  "strength",
  "cardio",
  "walk",
  "run",
  "cycle",
  "swim",
  "hiit",
  "sport",
  "mobility",
  "other",
];

export type ActivityIntensity = "easy" | "moderate" | "hard" | "max";
export const ACTIVITY_INTENSITIES: readonly ActivityIntensity[] = [
  "easy",
  "moderate",
  "hard",
  "max",
];

export type DeviceLabel = "apple_watch" | "strava" | "gym_machine" | "other";
export const DEVICE_LABELS: readonly DeviceLabel[] = [
  "apple_watch",
  "strava",
  "gym_machine",
  "other",
];

export type BodyWeightSource = "weigh_in" | "profile" | "default";

export const DEFAULT_BODY_WEIGHT_KG = 75;
/// Minutes per working set (work + typical rest) when a lift has no duration.
export const MINUTES_PER_WORKING_SET = 2.5;
export const GYM_MACHINE_DISCOUNT = 0.85;

/// Compendium of Physical Activities (2024) derived values, rounded. Codes are
/// the analyzer's optional precise pick; kind × intensity covers the rest.
export const MET_CODES: Readonly<Record<string, number>> = {
  lift_light: 3.5,
  lift_moderate: 5.0,
  lift_vigorous: 6.0,
  circuit_training: 8.0,
  bodyweight_calisthenics_moderate: 3.8,
  bodyweight_calisthenics_vigorous: 8.0,
  run_5mph: 8.3,
  run_6mph: 9.8,
  run_7mph: 11.0,
  run_8mph: 11.8,
  jog_general: 7.0,
  walk_2_5mph: 3.0,
  walk_3mph: 3.5,
  walk_3_5mph: 4.3,
  walk_4mph: 5.0,
  hike: 6.0,
  bike_stationary_light: 3.5,
  bike_stationary_moderate: 6.8,
  bike_stationary_vigorous: 8.8,
  bike_outdoor_leisure: 4.0,
  bike_outdoor_moderate: 8.0,
  bike_outdoor_fast: 10.0,
  elliptical_moderate: 5.0,
  rowing_machine_moderate: 7.0,
  rowing_machine_vigorous: 8.5,
  stair_climber: 9.0,
  jump_rope: 11.0,
  swim_leisure: 6.0,
  swim_freestyle_moderate: 7.0,
  swim_freestyle_vigorous: 9.8,
  basketball_game: 6.5,
  basketball_shootaround: 4.5,
  soccer_casual: 7.0,
  tennis_singles: 8.0,
  pickleball: 4.1,
  golf_walking: 4.8,
  yoga_hatha: 2.5,
  stretching: 2.3,
  pilates: 3.0,
  martial_arts: 10.3,
};

export const MET_CODE_KEYS: readonly string[] = Object.keys(MET_CODES);

const KIND_INTENSITY_MET: Record<
  ActivityKind,
  Record<"easy" | "moderate" | "hard", number>
> = {
  strength: { easy: 3.5, moderate: 5.0, hard: 6.0 },
  cardio: { easy: 5.0, moderate: 7.0, hard: 9.0 },
  walk: { easy: 3.0, moderate: 3.5, hard: 4.3 },
  run: { easy: 8.3, moderate: 9.8, hard: 11.5 },
  cycle: { easy: 3.5, moderate: 6.8, hard: 8.8 },
  swim: { easy: 6.0, moderate: 7.0, hard: 9.8 },
  hiit: { easy: 6.0, moderate: 8.0, hard: 10.0 },
  sport: { easy: 4.5, moderate: 6.5, hard: 8.0 },
  mobility: { easy: 2.3, moderate: 2.5, hard: 3.0 },
  other: { easy: 3.0, moderate: 4.0, hard: 5.5 },
};

export function metFor(
  kind: ActivityKind,
  intensity: ActivityIntensity | null,
  metCode: string | null,
): number {
  if (metCode && metCode in MET_CODES) return MET_CODES[metCode];
  const level = intensity === "max" ? "hard" : intensity ?? "moderate";
  return KIND_INTENSITY_MET[kind]?.[level] ?? KIND_INTENSITY_MET.other[level];
}

function finiteInRange(
  value: unknown,
  minimum: number,
  maximum: number,
): value is number {
  return typeof value === "number" && Number.isFinite(value) &&
    value >= minimum && value <= maximum;
}

export function resolveBodyWeight(
  weighInKg: number | null | undefined,
  profileKg: number | null | undefined,
): { kg: number; source: BodyWeightSource } {
  if (finiteInRange(weighInKg, 30, 300)) {
    return { kg: weighInKg, source: "weigh_in" };
  }
  if (finiteInRange(profileKg, 30, 300)) {
    return { kg: profileKg, source: "profile" };
  }
  return { kg: DEFAULT_BODY_WEIGHT_KG, source: "default" };
}

/// Resting burn per hour: Mifflin–St Jeor with a neutral adult (35 y, sex
/// midpoint) when height is known, else ~22 kcal/kg/day.
export function restingKcalPerHour(
  weightKg: number,
  heightCm: number | null | undefined,
): number {
  const daily = finiteInRange(heightCm, 120, 230)
    ? 10 * weightKg + 6.25 * heightCm - 5 * 35 - 78
    : 22 * weightKg;
  return daily / 24;
}

export type ActivityEnergyInput = {
  kind: ActivityKind;
  intensity: ActivityIntensity | null;
  metCode: string | null;
  durationMin: number | null;
  /// Non-warm-up sets, used to estimate a lift's duration when none is given.
  workingSets: number;
  deviceActiveKcal: number | null;
  deviceTotalKcal: number | null;
  deviceLabel: DeviceLabel | null;
  bodyWeightKg: number;
  bodyWeightSource: BodyWeightSource;
  heightCm?: number | null;
};

export type ActivityEnergyResult = {
  activeKcal: number | null;
  method: "device" | "met";
  met: number | null;
  weightKgUsed: number;
  durationMinUsed: number | null;
  durationEstimated: boolean;
  confidence: number;
};

function roundKcal(value: number): number {
  return Math.min(10_000, Math.max(0, Math.round(value)));
}

function roundConfidence(value: number): number {
  return Math.round(Math.min(1, Math.max(0, value)) * 100) / 100;
}

function weightConfidenceCap(source: BodyWeightSource): number {
  return source === "weigh_in" ? 1 : source === "profile" ? 0.75 : 0.4;
}

function estimatedDuration(
  input: ActivityEnergyInput,
): { minutes: number | null; estimated: boolean } {
  if (finiteInRange(input.durationMin, 1, 1_440)) {
    return { minutes: input.durationMin, estimated: false };
  }
  if (
    (input.kind === "strength" || input.kind === "hiit") &&
    input.workingSets > 0
  ) {
    const minutes = Math.min(
      150,
      Math.max(10, input.workingSets * MINUTES_PER_WORKING_SET),
    );
    return { minutes, estimated: true };
  }
  return { minutes: null, estimated: false };
}

export function estimateActiveEnergy(
  input: ActivityEnergyInput,
): ActivityEnergyResult {
  const weightKgUsed = Math.round(input.bodyWeightKg * 10) / 10;
  const duration = estimatedDuration(input);
  const isConsole = input.deviceLabel === "gym_machine";

  if (finiteInRange(input.deviceActiveKcal, 1, 5_000)) {
    return {
      activeKcal: roundKcal(
        input.deviceActiveKcal * (isConsole ? GYM_MACHINE_DISCOUNT : 1),
      ),
      method: "device",
      met: null,
      weightKgUsed,
      durationMinUsed: duration.minutes,
      durationEstimated: duration.estimated,
      confidence: isConsole
        ? 0.6
        : input.deviceLabel === "other" || input.deviceLabel === null
        ? 0.8
        : 0.9,
    };
  }

  if (finiteInRange(input.deviceTotalKcal, 1, 6_000)) {
    const discounted = input.deviceTotalKcal *
      (isConsole ? GYM_MACHINE_DISCOUNT : 1);
    const resting = duration.minutes !== null && !duration.estimated
      ? restingKcalPerHour(input.bodyWeightKg, input.heightCm) *
        (duration.minutes / 60)
      : null;
    return {
      activeKcal: roundKcal(
        resting === null ? discounted * 0.8 : discounted - resting,
      ),
      method: "device",
      met: null,
      weightKgUsed,
      durationMinUsed: duration.minutes,
      durationEstimated: duration.estimated,
      confidence: resting === null ? 0.5 : isConsole ? 0.55 : 0.75,
    };
  }

  const met = metFor(input.kind, input.intensity, input.metCode);
  if (duration.minutes === null) {
    return {
      activeKcal: null,
      method: "met",
      met,
      weightKgUsed,
      durationMinUsed: null,
      durationEstimated: false,
      confidence: 0,
    };
  }
  const activeKcal = roundKcal(
    Math.max(0, met - 1) * input.bodyWeightKg * (duration.minutes / 60),
  );
  const base = duration.estimated ? 0.45 : 0.6;
  return {
    activeKcal,
    method: "met",
    met,
    weightKgUsed,
    durationMinUsed: Math.round(duration.minutes * 10) / 10,
    durationEstimated: duration.estimated,
    confidence: roundConfidence(
      Math.min(base, weightConfidenceCap(input.bodyWeightSource)),
    ),
  };
}
