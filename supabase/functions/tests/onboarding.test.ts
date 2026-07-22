import {
  createOnboardingRecommendation,
  localDayInTimezone,
  mergeOnboardingValues,
  ONBOARDING_ANALYSIS_TIMEOUT_MS,
  ONBOARDING_COPY_INSTRUCTION,
  ONBOARDING_DIETARY_CONTEXT_INSTRUCTION,
  ONBOARDING_MODEL,
  ONBOARDING_PROCESSING_BUDGET_MS,
  ONBOARDING_SCHEMA,
  ONBOARDING_TRANSCRIPTION_PROMPT,
  ONBOARDING_TRANSCRIPTION_TIMEOUT_MS,
  onboardingPhaseTimeout,
  parseOnboardingRecommendation,
} from "../_shared/onboarding.ts";
import { assertEquals, assertThrows } from "./assertions.ts";

const recommendation = {
  summary: "A steady maintenance plan.",
  display_name: "Luke",
  goal_type: "maintain",
  goal_notes: "Keep energy steady.",
  height_cm: 180,
  weight_kg: 80,
  target_weight_kg: 80,
  activity_level: "moderate",
  calories_kcal: 2400,
  protein_g: 160,
  carbs_g: 260,
  fat_g: 75,
  assumptions: ["Activity is consistent."],
  suggestions: ["Review the target after two weeks."],
} as const;

Deno.test("onboarding is explicitly pinned to GPT-5.6 Sol", () => {
  assertEquals(ONBOARDING_MODEL, "gpt-5.6-sol");
  assertEquals(ONBOARDING_SCHEMA.additionalProperties, false);
  assertEquals(
    [...ONBOARDING_SCHEMA.required].sort(),
    Object.keys(ONBOARDING_SCHEMA.properties).sort(),
  );
  assertEquals("calories_kcal" in ONBOARDING_SCHEMA.properties, false);
  assertEquals(
    "goal_rate_percent_per_week" in ONBOARDING_SCHEMA.properties,
    true,
  );
  assertEquals(parseOnboardingRecommendation(recommendation), {
    ...recommendation,
    assumptions: [...recommendation.assumptions],
    suggestions: [...recommendation.suggestions],
  });
});

Deno.test("onboarding preserves diet context without personifying the product", () => {
  assertEquals(
    ONBOARDING_COPY_INSTRUCTION.includes("Never speak as Shudo"),
    true,
  );
  for (
    const phrase of [
      "allergies",
      "restrictions",
      "preferences",
      "recurring foods",
      "training routine",
    ]
  ) {
    assertEquals(ONBOARDING_DIETARY_CONTEXT_INSTRUCTION.includes(phrase), true);
  }
  for (const phrase of ["allergies", "dietary restrictions", "preferences"]) {
    assertEquals(ONBOARDING_TRANSCRIPTION_PROMPT.includes(phrase), true);
  }
  assertThrows(
    () =>
      parseOnboardingRecommendation({
        ...recommendation,
        summary: "Shudo thinks these targets are best.",
      }),
    undefined,
    "personified product copy",
  );
  assertThrows(
    () =>
      parseOnboardingRecommendation({
        ...recommendation,
        suggestions: ["Our recommendation is more protein."],
      }),
    undefined,
    "personified product copy",
  );
  const userOwnedContext = "I'm vegetarian and I avoid dairy.";
  assertEquals(
    parseOnboardingRecommendation({
      ...recommendation,
      goal_notes: userOwnedContext,
    }).goal_notes,
    userOwnedContext,
  );
});

Deno.test("reviewed onboarding overrides only approved profile values", () => {
  const lossValues = mergeOnboardingValues(
    recommendation,
    {
      goal_type: "lose",
      display_name: null,
      calories_kcal: recommendation.calories_kcal,
      protein_g: recommendation.protein_g,
      carbs_g: recommendation.carbs_g,
      fat_g: recommendation.fat_g,
    },
    "America/New_York",
  );
  const gainValues = mergeOnboardingValues(
    recommendation,
    { goal_type: "gain" },
    "America/New_York",
  );
  assertEquals(lossValues.goal_type, "lose");
  assertEquals(lossValues.calories_kcal < recommendation.calories_kcal, true);
  assertEquals(gainValues.calories_kcal > recommendation.calories_kcal, true);
  assertEquals(
    gainValues.calories_kcal - lossValues.calories_kcal >= 400,
    true,
  );
  assertEquals(lossValues.display_name, null);
  assertEquals(lossValues.timezone, "America/New_York");

  const manuallyEdited = mergeOnboardingValues(
    recommendation,
    {
      goal_type: "lose",
      calories_kcal: 2200,
      protein_g: 160,
      carbs_g: 255,
      fat_g: 60,
    },
    "UTC",
  );
  assertEquals(manuallyEdited.calories_kcal, 2200);
  assertEquals(manuallyEdited.carbs_g, 255);
  assertThrows(
    () => mergeOnboardingValues(recommendation, { user_id: "other" }, "UTC"),
    400,
    "Unsupported override",
  );
  assertThrows(() =>
    mergeOnboardingValues(
      recommendation,
      { activity_level: "sometimes-ish" },
      "UTC",
    )
  );
});

Deno.test("model context is converted into deterministic targets", () => {
  const calculated = createOnboardingRecommendation({
    summary: "A gradual gain plan with flexible food choices.",
    display_name: "Luke",
    goal_type: "gain",
    goal_notes: "Four lifting sessions each week.",
    height_cm: 180,
    weight_kg: 80,
    target_weight_kg: 84,
    activity_level: "moderate",
    age_years: 30,
    sex_for_equation: "male",
    training_days_per_week: 4,
    goal_rate_percent_per_week: 0.25,
    protein_bias: "higher",
    fat_bias: "standard",
    assumptions: [],
    suggestions: ["Review the trend after two weeks."],
  });
  assertEquals(calculated.goal_type, "gain");
  assertEquals(calculated._target_context?.age_years, 30);
  assertEquals(calculated.calories_kcal > 2_700, true);
  assertEquals(
    calculated.assumptions.some((item) => item.includes("not medical advice")),
    true,
  );
  assertEquals(
    Math.abs(
      calculated.protein_g * 4 + calculated.carbs_g * 4 +
        calculated.fat_g * 9 - calculated.calories_kcal,
    ) <= calculated.calories_kcal * 0.02,
    true,
  );
  assertThrows(
    () =>
      createOnboardingRecommendation({
        summary: "An estimate.",
        display_name: null,
        goal_type: "lose",
        goal_notes: "",
        height_cm: 180,
        weight_kg: 80,
        target_weight_kg: null,
        activity_level: "moderate",
        age_years: 12,
        sex_for_equation: "unspecified",
        training_days_per_week: null,
        goal_rate_percent_per_week: null,
        protein_bias: "standard",
        fat_bias: "standard",
        assumptions: [],
        suggestions: [],
      }),
    undefined,
    "Invalid age_years",
  );
});

Deno.test("onboarding target date honors the user's timezone", () => {
  assertEquals(
    localDayInTimezone(
      new Date("2026-07-21T02:00:00.000Z"),
      "America/New_York",
    ),
    "2026-07-20",
  );
});

Deno.test("onboarding OpenAI phases stay inside the free Edge wall budget", () => {
  assertEquals(ONBOARDING_PROCESSING_BUDGET_MS <= 125_000, true);
  assertEquals(
    ONBOARDING_TRANSCRIPTION_TIMEOUT_MS + ONBOARDING_ANALYSIS_TIMEOUT_MS <
      150_000,
    true,
  );
  assertEquals(onboardingPhaseTimeout(10_000, 8_000, 4_000), 6_000);
  assertThrows(
    () => onboardingPhaseTimeout(10_000, 8_000, 10_000),
    undefined,
    "deadline expired",
  );
});

Deno.test("onboarding rejects internally inconsistent calorie and macro targets", () => {
  assertThrows(
    () =>
      parseOnboardingRecommendation({
        ...recommendation,
        calories_kcal: 2400,
        protein_g: 50,
        carbs_g: 50,
        fat_g: 30,
      }),
    undefined,
    "Daily macros do not match the calorie target",
  );

  assertThrows(
    () =>
      parseOnboardingRecommendation({
        ...recommendation,
        calories_kcal: 2400,
        protein_g: 160,
        carbs_g: 260,
        fat_g: 95,
      }),
    undefined,
    "Daily macros do not match the calorie target",
  );

  assertThrows(
    () =>
      parseOnboardingRecommendation({
        ...recommendation,
        calories_kcal: 900,
      }),
    undefined,
    "Invalid calories_kcal",
  );
});
