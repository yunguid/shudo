import {
  calculateDeterministicTargets,
  validateNutritionTarget,
} from "../_shared/target_engine.ts";
import type { TargetEngineInput } from "../_shared/target_engine.ts";
import { assertEquals, assertThrows } from "./assertions.ts";

const profile: Omit<TargetEngineInput, "goal_type"> = {
  height_cm: 180,
  weight_kg: 80,
  activity_level: "moderate",
  age_years: 30,
  sex_for_equation: "male",
  training_days_per_week: 4,
  goal_rate_percent_per_week: null,
  protein_bias: "standard",
  fat_bias: "standard",
};

Deno.test("cut, maintain, and bulk produce meaningfully different targets", () => {
  const loss = calculateDeterministicTargets({ ...profile, goal_type: "lose" });
  const maintain = calculateDeterministicTargets({
    ...profile,
    goal_type: "maintain",
  });
  const gain = calculateDeterministicTargets({ ...profile, goal_type: "gain" });

  assertEquals(
    loss.target.calories_kcal <= maintain.target.calories_kcal - 250,
    true,
  );
  assertEquals(
    gain.target.calories_kcal >= maintain.target.calories_kcal + 150,
    true,
  );
  assertEquals(loss.goal_adjustment_kcal < 0, true);
  assertEquals(maintain.goal_adjustment_kcal, 0);
  assertEquals(gain.goal_adjustment_kcal > 0, true);
});

Deno.test("target engine bounds aggressive requested rates", () => {
  const rapidLoss = calculateDeterministicTargets({
    ...profile,
    goal_type: "lose",
    goal_rate_percent_per_week: 1.25,
  });
  const rapidGain = calculateDeterministicTargets({
    ...profile,
    goal_type: "gain",
    goal_rate_percent_per_week: 1.25,
  });
  assertEquals(rapidLoss.goal_adjustment_kcal >= -750, true);
  assertEquals(rapidGain.goal_adjustment_kcal <= 500, true);
  assertEquals(rapidLoss.target.calories_kcal >= 1_200, true);
  assertEquals(rapidGain.target.calories_kcal <= 6_000, true);
});

Deno.test("target engine remains valid with incomplete and boundary profiles", () => {
  for (
    const candidate of [
      {
        ...profile,
        goal_type: "maintain" as const,
        height_cm: null,
        age_years: null,
        sex_for_equation: "unspecified" as const,
      },
      {
        ...profile,
        goal_type: "gain" as const,
        height_cm: 275,
        weight_kg: 500,
        age_years: 18,
        activity_level: "extra_active" as const,
      },
      {
        ...profile,
        goal_type: "lose" as const,
        height_cm: null,
        weight_kg: null,
        age_years: null,
        sex_for_equation: "unspecified" as const,
        activity_level: "sedentary" as const,
      },
    ]
  ) {
    const result = calculateDeterministicTargets(candidate);
    assertEquals(result.target.calories_kcal >= 1_200, true);
    assertEquals(result.target.calories_kcal <= 6_000, true);
  }
});

Deno.test("validation rejects unsafe and inconsistent targets", () => {
  assertThrows(
    () =>
      validateNutritionTarget({
        calories_kcal: 900,
        protein_g: 100,
        carbs_g: 80,
        fat_g: 20,
      }, 80),
    undefined,
    "outside the supported estimate range",
  );
  assertThrows(
    () =>
      validateNutritionTarget({
        calories_kcal: 2_400,
        protein_g: 160,
        carbs_g: 100,
        fat_g: 50,
      }, 80),
    undefined,
    "Daily macros do not match",
  );
  assertThrows(
    () =>
      validateNutritionTarget({
        calories_kcal: 2_400,
        protein_g: 250,
        carbs_g: 250,
        fat_g: 45,
      }, 60),
    undefined,
    "too high for the supplied weight",
  );
});
