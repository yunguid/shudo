export type NutritionGoal = "maintain" | "lose" | "gain";
export type ActivityLevel =
  | "sedentary"
  | "light"
  | "moderate"
  | "active"
  | "extra_active";
export type EquationSex = "female" | "male" | "unspecified";
export type MacroBias = "lower" | "standard" | "higher";

export type NutritionTarget = {
  calories_kcal: number;
  protein_g: number;
  carbs_g: number;
  fat_g: number;
};

export type TargetEngineInput = {
  goal_type: NutritionGoal;
  height_cm: number | null;
  weight_kg: number | null;
  activity_level: ActivityLevel;
  age_years: number | null;
  sex_for_equation: EquationSex;
  training_days_per_week: number | null;
  goal_rate_percent_per_week: number | null;
  protein_bias: Exclude<MacroBias, "lower">;
  fat_bias: MacroBias;
};

export type TargetEngineResult = {
  target: NutritionTarget;
  maintenance_calories_kcal: number;
  goal_adjustment_kcal: number;
  uncertainty: "moderate" | "high";
  assumptions: string[];
};

const ACTIVITY_MULTIPLIER: Record<ActivityLevel, number> = {
  sedentary: 1.2,
  light: 1.375,
  moderate: 1.55,
  active: 1.725,
  extra_active: 1.9,
};

const WEIGHT_ONLY_KCAL_PER_KG: Record<ActivityLevel, number> = {
  sedentary: 28,
  light: 31,
  moderate: 34,
  active: 37,
  extra_active: 40,
};

function clamp(value: number, minimum: number, maximum: number): number {
  return Math.min(maximum, Math.max(minimum, value));
}

function roundTo(value: number, increment: number): number {
  return Math.round(value / increment) * increment;
}

function finiteInRange(
  value: number | null,
  minimum: number,
  maximum: number,
): value is number {
  return value !== null && Number.isFinite(value) && value >= minimum &&
    value <= maximum;
}

function maintenanceEstimate(
  input: TargetEngineInput,
): {
  calories: number;
  assumptions: string[];
  uncertainty: "moderate" | "high";
} {
  const assumptions: string[] = [];
  if (
    finiteInRange(input.weight_kg, 20, 500) &&
    finiteInRange(input.height_cm, 50, 275)
  ) {
    const age = finiteInRange(input.age_years, 18, 100) ? input.age_years : 35;
    if (input.age_years === null) {
      assumptions.push(
        "Age was not provided, so the baseline uses a neutral adult estimate.",
      );
    }
    const sexOffset = input.sex_for_equation === "male"
      ? 5
      : input.sex_for_equation === "female"
      ? -161
      : -78;
    if (input.sex_for_equation === "unspecified") {
      assumptions.push(
        "Sex for the energy equation was not provided, so a midpoint estimate is used.",
      );
    }
    const resting = 10 * input.weight_kg + 6.25 * input.height_cm - 5 * age +
      sexOffset;
    return {
      calories: resting * ACTIVITY_MULTIPLIER[input.activity_level],
      assumptions,
      uncertainty: input.age_years !== null &&
          input.sex_for_equation !== "unspecified"
        ? "moderate"
        : "high",
    };
  }

  if (finiteInRange(input.weight_kg, 20, 500)) {
    assumptions.push(
      "Height, age, or sex for the energy equation was incomplete, so a weight-and-activity estimate is used.",
    );
    return {
      calories: input.weight_kg * WEIGHT_ONLY_KCAL_PER_KG[input.activity_level],
      assumptions,
      uncertainty: "high",
    };
  }

  assumptions.push(
    "Current weight was not provided, so the calorie estimate uses a broad adult starting point.",
  );
  return {
    calories: 2_200 * ACTIVITY_MULTIPLIER[input.activity_level] /
      ACTIVITY_MULTIPLIER.moderate,
    assumptions,
    uncertainty: "high",
  };
}

function goalAdjustment(
  maintenance: number,
  input: TargetEngineInput,
): number {
  if (input.goal_type === "maintain") return 0;

  const defaultRate = input.goal_type === "lose" ? 0.5 : 0.25;
  const requestedRate = finiteInRange(
      input.goal_rate_percent_per_week,
      0.05,
      1.25,
    )
    ? input.goal_rate_percent_per_week
    : defaultRate;
  const boundedRate = input.goal_type === "lose"
    ? clamp(requestedRate, 0.25, 1)
    : clamp(requestedRate, 0.1, 0.5);
  const weightBased = finiteInRange(input.weight_kg, 20, 500)
    ? input.weight_kg * boundedRate / 100 * 7_700 / 7
    : input.goal_type === "lose"
    ? 400
    : 250;

  if (input.goal_type === "lose") {
    return -clamp(weightBased, 250, Math.min(750, maintenance * 0.25));
  }
  return clamp(weightBased, 150, Math.min(500, maintenance * 0.2));
}

export function validateNutritionTarget(
  value: NutritionTarget,
  weightKg: number | null = null,
): NutritionTarget {
  for (const [key, number] of Object.entries(value)) {
    if (!Number.isFinite(number)) throw new Error(`Invalid ${key}`);
  }
  if (value.calories_kcal < 1_200 || value.calories_kcal > 6_000) {
    throw new Error("Calorie target is outside the supported estimate range");
  }
  if (value.protein_g < 40 || value.protein_g > 300) {
    throw new Error("Protein target is outside the supported estimate range");
  }
  if (value.carbs_g < 0 || value.carbs_g > 900) {
    throw new Error(
      "Carbohydrate target is outside the supported estimate range",
    );
  }
  if (value.fat_g < 20 || value.fat_g > 250) {
    throw new Error("Fat target is outside the supported estimate range");
  }
  if (
    finiteInRange(weightKg, 20, 500) && value.protein_g / weightKg > 2.5
  ) {
    throw new Error("Protein target is too high for the supplied weight");
  }
  const macroCalories = value.protein_g * 4 + value.carbs_g * 4 +
    value.fat_g * 9;
  if (
    Math.abs(macroCalories - value.calories_kcal) > value.calories_kcal * 0.02
  ) {
    throw new Error("Daily macros do not match the calorie target");
  }
  return value;
}

export function calculateDeterministicTargets(
  input: TargetEngineInput,
): TargetEngineResult {
  const baseline = maintenanceEstimate(input);
  const maintenance = clamp(baseline.calories, 1_400, 6_000);
  const adjustment = goalAdjustment(maintenance, input);
  const calories = roundTo(clamp(maintenance + adjustment, 1_200, 6_000), 10);

  const trainingAdjustment = (input.training_days_per_week ?? 0) >= 4 ? 0.1 : 0;
  const goalProtein = input.goal_type === "lose"
    ? 1.8
    : input.goal_type === "gain"
    ? 1.7
    : 1.6;
  const proteinPerKg = clamp(
    goalProtein + trainingAdjustment +
      (input.protein_bias === "higher" ? 0.2 : 0),
    1.2,
    2.2,
  );
  const protein = clamp(
    roundTo(
      finiteInRange(input.weight_kg, 20, 500)
        ? input.weight_kg * proteinPerKg
        : calories * 0.25 / 4,
      1,
    ),
    40,
    300,
  );
  const fatFraction = input.fat_bias === "lower"
    ? 0.22
    : input.fat_bias === "higher"
    ? 0.3
    : 0.25;
  const fat = roundTo(calories * fatFraction / 9, 1);
  const carbs = roundTo(Math.max(0, (calories - protein * 4 - fat * 9) / 4), 1);
  const target = validateNutritionTarget({
    calories_kcal: calories,
    protein_g: protein,
    carbs_g: carbs,
    fat_g: fat,
  }, input.weight_kg);

  const goalAssumption = input.goal_type === "maintain"
    ? "The estimate starts at maintenance and should be reviewed against weight and training trends."
    : input.goal_rate_percent_per_week === null
    ? input.goal_type === "lose"
      ? "No pace was provided, so the estimate uses a moderate loss rate."
      : "No pace was provided, so the estimate uses a gradual gain rate."
    : "The stated rate is bounded to a conservative weekly range.";

  return {
    target,
    maintenance_calories_kcal: roundTo(maintenance, 10),
    goal_adjustment_kcal: roundTo(adjustment, 10),
    uncertainty: baseline.uncertainty,
    assumptions: [...baseline.assumptions, goalAssumption],
  };
}
