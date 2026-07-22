import {
  localDayInTimezone,
  mergeOnboardingValues,
  ONBOARDING_ANALYSIS_TIMEOUT_MS,
  ONBOARDING_MODEL,
  ONBOARDING_PROCESSING_BUDGET_MS,
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
  assertEquals(parseOnboardingRecommendation(recommendation), {
    ...recommendation,
    assumptions: [...recommendation.assumptions],
    suggestions: [...recommendation.suggestions],
  });
});

Deno.test("reviewed onboarding overrides only approved profile values", () => {
  const values = mergeOnboardingValues(
    recommendation,
    { goal_type: "lose", calories_kcal: 2200, display_name: null },
    "America/New_York",
  );
  assertEquals(values.goal_type, "lose");
  assertEquals(values.calories_kcal, 2200);
  assertEquals(values.display_name, null);
  assertEquals(values.timezone, "America/New_York");
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
        protein_g: 20,
        carbs_g: 20,
        fat_g: 10,
      }),
    undefined,
    "Daily macros do not match the calorie target",
  );
});
