import { responseOutputText } from "./analysis.ts";
import {
  AUDIO_TYPES,
  audioExtension,
  formFile,
  formString,
  validateFile,
  validateTimezone,
} from "./capture_validation.ts";
import { HttpError } from "./errors.ts";
import {
  assertNeutralGeneratedCopy,
  NEUTRAL_PRODUCT_COPY_INSTRUCTION,
} from "./generated_copy.ts";
import { isUuid, requiredEnv } from "./http.ts";
import {
  calculateDeterministicTargets,
  validateNutritionTarget,
} from "./target_engine.ts";
import type { TargetEngineInput } from "./target_engine.ts";

export const ONBOARDING_MODEL = "gpt-5.6-sol";
export const ONBOARDING_TRANSCRIPTION_MODEL = "gpt-4o-transcribe";
export const ONBOARDING_PROCESSING_BUDGET_MS = 125_000;
export const ONBOARDING_TRANSCRIPTION_TIMEOUT_MS = 55_000;
export const ONBOARDING_ANALYSIS_TIMEOUT_MS = 65_000;
export const MAX_ONBOARDING_AUDIO_BYTES = 25 * 1024 * 1024;
export const MAX_ONBOARDING_TEXT_CHARACTERS = 30_000;
export const ONBOARDING_COPY_INSTRUCTION =
  `${NEUTRAL_PRODUCT_COPY_INSTRUCTION} Apply that voice rule to summary, assumptions, and suggestions. Keep the summary concise and address the user directly only when useful. goal_notes is user-owned profile context, so preserve its meaning and do not treat first-person wording there as product narration.`;
export const ONBOARDING_DIETARY_CONTEXT_INSTRUCTION =
  "Preserve useful dietary context such as allergies, restrictions, preferences, recurring foods, and training routine in goal_notes without inventing any of it.";
export const ONBOARDING_TRANSCRIPTION_PROMPT =
  "Personal nutrition onboarding. Preserve stated goals, routines, foods, quantities, height, weight, units, allergies, dietary restrictions, dietary preferences, and corrections accurately.";

export const ONBOARDING_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    summary: { type: "string", minLength: 1, maxLength: 500 },
    display_name: { type: ["string", "null"], maxLength: 80 },
    goal_type: { type: "string", enum: ["maintain", "lose", "gain"] },
    goal_notes: {
      type: "string",
      maxLength: 2_000,
      description:
        "The user's stated goal and useful dietary context, including allergies, restrictions, preferences, recurring foods, and training routine. Do not invent context.",
    },
    height_cm: { type: ["number", "null"], minimum: 50, maximum: 275 },
    weight_kg: { type: ["number", "null"], minimum: 20, maximum: 500 },
    target_weight_kg: {
      type: ["number", "null"],
      minimum: 20,
      maximum: 500,
    },
    activity_level: {
      type: "string",
      enum: ["sedentary", "light", "moderate", "active", "extra_active"],
    },
    age_years: { type: ["number", "null"], minimum: 18, maximum: 100 },
    sex_for_equation: {
      type: "string",
      enum: ["female", "male", "unspecified"],
    },
    training_days_per_week: {
      type: ["number", "null"],
      minimum: 0,
      maximum: 7,
    },
    goal_rate_percent_per_week: {
      type: ["number", "null"],
      minimum: 0.05,
      maximum: 1.25,
    },
    protein_bias: { type: "string", enum: ["standard", "higher"] },
    fat_bias: {
      type: "string",
      enum: ["lower", "standard", "higher"],
    },
    assumptions: {
      type: "array",
      maxItems: 6,
      items: { type: "string", minLength: 1, maxLength: 240 },
    },
    suggestions: {
      type: "array",
      maxItems: 4,
      items: { type: "string", minLength: 1, maxLength: 240 },
    },
  },
  required: [
    "summary",
    "display_name",
    "goal_type",
    "goal_notes",
    "height_cm",
    "weight_kg",
    "target_weight_kg",
    "activity_level",
    "age_years",
    "sex_for_equation",
    "training_days_per_week",
    "goal_rate_percent_per_week",
    "protein_bias",
    "fat_bias",
    "assumptions",
    "suggestions",
  ],
} as const;

export type OnboardingRecommendation = {
  summary: string;
  display_name: string | null;
  goal_type: "maintain" | "lose" | "gain";
  goal_notes: string;
  height_cm: number | null;
  weight_kg: number | null;
  target_weight_kg: number | null;
  activity_level:
    | "sedentary"
    | "light"
    | "moderate"
    | "active"
    | "extra_active";
  calories_kcal: number;
  protein_g: number;
  carbs_g: number;
  fat_g: number;
  assumptions: string[];
  suggestions: string[];
  _target_context?: TargetEngineInput;
};

export type OnboardingModelContext =
  & Omit<
    OnboardingRecommendation,
    "calories_kcal" | "protein_g" | "carbs_g" | "fat_g" | "_target_context"
  >
  & Omit<TargetEngineInput, keyof OnboardingRecommendation>;

export type OnboardingValues =
  & Omit<
    OnboardingRecommendation,
    "summary" | "assumptions" | "suggestions"
  >
  & { timezone: string };

type OnboardingOverrideKey = keyof Omit<OnboardingValues, "timezone">;
const OVERRIDE_KEYS: OnboardingOverrideKey[] = [
  "display_name",
  "goal_type",
  "goal_notes",
  "height_cm",
  "weight_kg",
  "target_weight_kg",
  "activity_level",
  "calories_kcal",
  "protein_g",
  "carbs_g",
  "fat_g",
];

function record(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HttpError(400, `${label} must be an object`);
  }
  return value as Record<string, unknown>;
}

function textValue(
  value: unknown,
  label: string,
  maxLength: number,
  allowEmpty = false,
): string {
  if (typeof value !== "string") throw new Error(`Invalid ${label}`);
  const normalized = value.trim();
  if (
    (!allowEmpty && !normalized) ||
    Array.from(normalized).length > maxLength
  ) {
    throw new Error(`Invalid ${label}`);
  }
  return normalized;
}

function nullableText(
  value: unknown,
  label: string,
  maxLength: number,
): string | null {
  if (value === null) return null;
  return textValue(value, label, maxLength);
}

function boundedNumber(
  value: unknown,
  label: string,
  minimum: number,
  maximum: number,
): number {
  if (
    typeof value !== "number" || !Number.isFinite(value) || value < minimum ||
    value > maximum
  ) throw new Error(`Invalid ${label}`);
  return Math.round(value * 10) / 10;
}

function nullableNumber(
  value: unknown,
  label: string,
  minimum: number,
  maximum: number,
): number | null {
  return value === null ? null : boundedNumber(value, label, minimum, maximum);
}

function shortStrings(
  value: unknown,
  label: string,
  maxItems: number,
): string[] {
  if (!Array.isArray(value) || value.length > maxItems) {
    throw new Error(`Invalid ${label}`);
  }
  return value.map((item) => textValue(item, label, 240));
}

function activityLevel(
  value: unknown,
): OnboardingRecommendation["activity_level"] {
  const allowed = [
    "sedentary",
    "light",
    "moderate",
    "active",
    "extra_active",
  ] as const;
  if (!allowed.includes(value as (typeof allowed)[number])) {
    throw new Error("Invalid activity_level");
  }
  return value as OnboardingRecommendation["activity_level"];
}

function enumValue<T extends string>(
  value: unknown,
  allowed: readonly T[],
  label: string,
): T {
  if (!allowed.includes(value as T)) throw new Error(`Invalid ${label}`);
  return value as T;
}

function parseTargetContext(value: unknown): TargetEngineInput {
  const object = record(value, "target context");
  return {
    goal_type: enumValue(
      object.goal_type,
      ["maintain", "lose", "gain"] as const,
      "goal_type",
    ),
    height_cm: nullableNumber(object.height_cm, "height_cm", 50, 275),
    weight_kg: nullableNumber(object.weight_kg, "weight_kg", 20, 500),
    activity_level: activityLevel(object.activity_level),
    age_years: nullableNumber(object.age_years, "age_years", 18, 100),
    sex_for_equation: enumValue(
      object.sex_for_equation,
      ["female", "male", "unspecified"] as const,
      "sex_for_equation",
    ),
    training_days_per_week: nullableNumber(
      object.training_days_per_week,
      "training_days_per_week",
      0,
      7,
    ),
    goal_rate_percent_per_week: nullableNumber(
      object.goal_rate_percent_per_week,
      "goal_rate_percent_per_week",
      0.05,
      1.25,
    ),
    protein_bias: enumValue(
      object.protein_bias,
      ["standard", "higher"] as const,
      "protein_bias",
    ),
    fat_bias: enumValue(
      object.fat_bias,
      ["lower", "standard", "higher"] as const,
      "fat_bias",
    ),
  };
}

export function parseOnboardingModelContext(
  value: unknown,
): OnboardingModelContext {
  const object = record(value, "profile context");
  const targetContext = parseTargetContext(object);
  return {
    summary: assertNeutralGeneratedCopy(
      textValue(object.summary, "summary", 500),
      "summary",
    ),
    display_name: nullableText(object.display_name, "display_name", 80),
    goal_type: targetContext.goal_type,
    goal_notes: textValue(object.goal_notes, "goal_notes", 2_000, true),
    height_cm: targetContext.height_cm,
    weight_kg: targetContext.weight_kg,
    target_weight_kg: nullableNumber(
      object.target_weight_kg,
      "target_weight_kg",
      20,
      500,
    ),
    activity_level: targetContext.activity_level,
    age_years: targetContext.age_years,
    sex_for_equation: targetContext.sex_for_equation,
    training_days_per_week: targetContext.training_days_per_week,
    goal_rate_percent_per_week: targetContext.goal_rate_percent_per_week,
    protein_bias: targetContext.protein_bias,
    fat_bias: targetContext.fat_bias,
    assumptions: shortStrings(object.assumptions, "assumptions", 6).map(
      (item) => assertNeutralGeneratedCopy(item, "assumption"),
    ),
    suggestions: shortStrings(object.suggestions, "suggestions", 4).map(
      (item) => assertNeutralGeneratedCopy(item, "suggestion"),
    ),
  };
}

export function createOnboardingRecommendation(
  value: unknown,
): OnboardingRecommendation {
  const context = parseOnboardingModelContext(value);
  const targetContext: TargetEngineInput = {
    goal_type: context.goal_type,
    height_cm: context.height_cm,
    weight_kg: context.weight_kg,
    activity_level: context.activity_level,
    age_years: context.age_years,
    sex_for_equation: context.sex_for_equation,
    training_days_per_week: context.training_days_per_week,
    goal_rate_percent_per_week: context.goal_rate_percent_per_week,
    protein_bias: context.protein_bias,
    fat_bias: context.fat_bias,
  };
  const calculated = calculateDeterministicTargets(targetContext);
  return {
    summary: context.summary,
    display_name: context.display_name,
    goal_type: context.goal_type,
    goal_notes: context.goal_notes,
    height_cm: context.height_cm,
    weight_kg: context.weight_kg,
    target_weight_kg: context.target_weight_kg,
    activity_level: context.activity_level,
    ...calculated.target,
    assumptions: [
      ...new Set([
        ...calculated.assumptions,
        `This is a ${calculated.uncertainty}-uncertainty estimate, not medical advice.`,
        ...context.assumptions,
      ]),
    ].slice(0, 6),
    suggestions: context.suggestions,
    _target_context: targetContext,
  };
}

export function parseOnboardingRecommendation(
  value: unknown,
): OnboardingRecommendation {
  const object = record(value, "recommendation");
  const goalType = object.goal_type;
  if (!(["maintain", "lose", "gain"] as unknown[]).includes(goalType)) {
    throw new Error("Invalid goal_type");
  }
  const summary = assertNeutralGeneratedCopy(
    textValue(object.summary, "summary", 500),
    "summary",
  );
  // This field is durable user-owned context, not generated product copy. It
  // may legitimately preserve first-person wording such as "I'm vegetarian."
  const goalNotes = textValue(object.goal_notes, "goal_notes", 2_000, true);
  const assumptions = shortStrings(object.assumptions, "assumptions", 6).map(
    (item) => assertNeutralGeneratedCopy(item, "assumption"),
  );
  const suggestions = shortStrings(object.suggestions, "suggestions", 4).map(
    (item) => assertNeutralGeneratedCopy(item, "suggestion"),
  );
  const recommendation: OnboardingRecommendation = {
    summary,
    display_name: nullableText(object.display_name, "display_name", 80),
    goal_type: goalType as OnboardingRecommendation["goal_type"],
    goal_notes: goalNotes,
    height_cm: nullableNumber(object.height_cm, "height_cm", 50, 275),
    weight_kg: nullableNumber(object.weight_kg, "weight_kg", 20, 500),
    target_weight_kg: nullableNumber(
      object.target_weight_kg,
      "target_weight_kg",
      20,
      500,
    ),
    activity_level: activityLevel(object.activity_level),
    calories_kcal: boundedNumber(
      object.calories_kcal,
      "calories_kcal",
      1_200,
      6_000,
    ),
    protein_g: boundedNumber(object.protein_g, "protein_g", 40, 300),
    carbs_g: boundedNumber(object.carbs_g, "carbs_g", 0, 900),
    fat_g: boundedNumber(object.fat_g, "fat_g", 20, 250),
    assumptions,
    suggestions,
    ...(object._target_context === undefined
      ? {}
      : { _target_context: parseTargetContext(object._target_context) }),
  };
  validateNutritionTarget({
    calories_kcal: recommendation.calories_kcal,
    protein_g: recommendation.protein_g,
    carbs_g: recommendation.carbs_g,
    fat_g: recommendation.fat_g,
  }, recommendation.weight_kg);
  return recommendation;
}

export function mergeOnboardingValues(
  recommendationValue: unknown,
  overridesValue: unknown,
  timezone: string,
): OnboardingValues {
  const recommendation = parseOnboardingRecommendation(recommendationValue);
  const overrides = overridesValue === undefined || overridesValue === null
    ? {}
    : record(overridesValue, "overrides");
  const unexpected = Object.keys(overrides).filter((key) =>
    !OVERRIDE_KEYS.includes(key as OnboardingOverrideKey)
  );
  if (unexpected.length > 0) {
    throw new HttpError(400, `Unsupported override: ${unexpected[0]}`);
  }
  const candidate = { ...recommendation, ...overrides };
  const goalType = enumValue(
    candidate.goal_type,
    ["maintain", "lose", "gain"] as const,
    "goal_type",
  );
  const heightCm = nullableNumber(candidate.height_cm, "height_cm", 50, 275);
  const weightKg = nullableNumber(candidate.weight_kg, "weight_kg", 20, 500);
  const targetWeightKg = nullableNumber(
    candidate.target_weight_kg,
    "target_weight_kg",
    20,
    500,
  );
  const activity = activityLevel(candidate.activity_level);
  const proposedTarget = {
    calories_kcal: boundedNumber(
      candidate.calories_kcal,
      "calories_kcal",
      1_200,
      6_000,
    ),
    protein_g: boundedNumber(candidate.protein_g, "protein_g", 40, 300),
    carbs_g: boundedNumber(candidate.carbs_g, "carbs_g", 0, 900),
    fat_g: boundedNumber(candidate.fat_g, "fat_g", 20, 250),
  };
  const targetWasEdited = (Object.keys(proposedTarget) as Array<
    keyof typeof proposedTarget
  >).some((key) => proposedTarget[key] !== recommendation[key]);
  const contextWasEdited = goalType !== recommendation.goal_type ||
    heightCm !== recommendation.height_cm ||
    weightKg !== recommendation.weight_kg ||
    activity !== recommendation.activity_level;
  const baseContext = recommendation._target_context ?? {
    goal_type: recommendation.goal_type,
    height_cm: recommendation.height_cm,
    weight_kg: recommendation.weight_kg,
    activity_level: recommendation.activity_level,
    age_years: null,
    sex_for_equation: "unspecified" as const,
    training_days_per_week: null,
    goal_rate_percent_per_week: null,
    protein_bias: "standard" as const,
    fat_bias: "standard" as const,
  };
  const finalTarget = contextWasEdited && !targetWasEdited
    ? calculateDeterministicTargets({
      ...baseContext,
      goal_type: goalType,
      height_cm: heightCm,
      weight_kg: weightKg,
      activity_level: activity,
    }).target
    : validateNutritionTarget(proposedTarget, weightKg);

  return {
    timezone: validateTimezone(timezone),
    display_name: nullableText(candidate.display_name, "display_name", 80),
    goal_type: goalType,
    goal_notes: textValue(candidate.goal_notes, "goal_notes", 2_000, true),
    height_cm: heightCm,
    weight_kg: weightKg,
    target_weight_kg: targetWeightKg,
    activity_level: activity,
    ...finalTarget,
  };
}

export function localDayInTimezone(date: Date, timezone: string): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: validateTimezone(timezone),
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const values = Object.fromEntries(
    parts.map((part) => [part.type, part.value]),
  );
  return `${values.year}-${values.month}-${values.day}`;
}

export function onboardingPhaseTimeout(
  deadlineMs: number,
  maximumMs: number,
  nowMs = Date.now(),
): number {
  const remaining = Math.trunc(deadlineMs - nowMs);
  if (!Number.isFinite(remaining) || remaining <= 0) {
    throw new Error("Onboarding processing deadline expired");
  }
  return Math.max(1, Math.min(maximumMs, remaining));
}

export function parseOnboardingCapture(form: FormData): {
  clientRequestId: string;
  timezone: string;
  text: string;
  audio: File | null;
} {
  const clientRequestId = formString(form, "client_request_id").toLowerCase();
  if (!isUuid(clientRequestId)) {
    throw new HttpError(400, "client_request_id must be a UUID");
  }
  const timezone = validateTimezone(formString(form, "timezone"));
  const text = formString(form, "text");
  if (Array.from(text).length > MAX_ONBOARDING_TEXT_CHARACTERS) {
    throw new HttpError(413, "Onboarding note is too long");
  }
  const audio = formFile(form, "audio");
  validateFile(
    audio,
    AUDIO_TYPES,
    MAX_ONBOARDING_AUDIO_BYTES,
    "Voice note",
  );
  if (!text && !audio) {
    throw new HttpError(400, "Add a voice note or a short description");
  }
  return { clientRequestId, timezone, text, audio };
}

async function safetyIdentifier(userId: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(userId),
  );
  return `shudo_${
    Array.from(new Uint8Array(digest)).slice(0, 16).map((byte) =>
      byte.toString(16).padStart(2, "0")
    ).join("")
  }`;
}

export async function transcribeOnboardingAudio(
  audio: File,
  deadlineMs = Date.now() + ONBOARDING_TRANSCRIPTION_TIMEOUT_MS,
): Promise<string> {
  const form = new FormData();
  form.append("model", ONBOARDING_TRANSCRIPTION_MODEL);
  form.append("response_format", "json");
  form.append(
    "prompt",
    ONBOARDING_TRANSCRIPTION_PROMPT,
  );
  form.append(
    "file",
    new File(
      [await audio.arrayBuffer()],
      `onboarding.${audioExtension(audio.type.toLowerCase())}`,
      { type: audio.type },
    ),
  );
  const response = await fetch(
    "https://api.openai.com/v1/audio/transcriptions",
    {
      method: "POST",
      headers: { authorization: `Bearer ${requiredEnv("OPENAI_API_KEY")}` },
      body: form,
      signal: AbortSignal.timeout(
        onboardingPhaseTimeout(
          deadlineMs,
          ONBOARDING_TRANSCRIPTION_TIMEOUT_MS,
        ),
      ),
    },
  );
  if (!response.ok) {
    throw new Error(`Onboarding transcription failed (${response.status})`);
  }
  const payload = await response.json();
  const transcript = typeof payload?.text === "string"
    ? payload.text.trim()
    : "";
  if (!transcript) throw new Error("Onboarding transcription was empty");
  return transcript;
}

export async function analyzeOnboarding(
  userId: string,
  transcript: string,
  deadlineMs = Date.now() + ONBOARDING_ANALYSIS_TIMEOUT_MS,
): Promise<
  { recommendation: OnboardingRecommendation; responseId: string | null }
> {
  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      authorization: `Bearer ${requiredEnv("OPENAI_API_KEY")}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: ONBOARDING_MODEL,
      reasoning: { effort: "low" },
      text: {
        verbosity: "low",
        format: {
          type: "json_schema",
          name: "shudo_onboarding_profile",
          strict: true,
          schema: ONBOARDING_SCHEMA,
        },
      },
      input: [{
        role: "user",
        content: [{
          type: "input_text",
          text: [
            "Extract a practical nutrition profile from this user's own description. A deterministic server-side engine calculates the final calorie and macro targets; do not calculate them.",
            "Use only stated facts. Never invent age, sex, measurements, training frequency, health context, or a requested rate of weight change. Use null or unspecified when absent and name material gaps in assumptions.",
            ONBOARDING_DIETARY_CONTEXT_INSTRUCTION,
            "Map only explicitly stated biological sex to sex_for_equation; otherwise use unspecified. This is an equation input, not a gender identity label.",
            "Set goal_rate_percent_per_week only when the user states a pace that can be represented as percent of current body weight per week; otherwise use null.",
            "Use protein_bias and fat_bias only for stated training or dietary preferences. Keep them standard when the description does not support a change.",
            "Targets are editable estimates, not prescriptions. Do not diagnose a condition, interpret symptoms, recommend medication, or give treatment advice.",
            "Avoid aggressive restriction. If the user mentions a medical issue, keep the summary neutral and suggest discussing individualized targets with a qualified clinician.",
            "Keep suggestions specific, non-medical, and easy to act on.",
            ONBOARDING_COPY_INSTRUCTION,
            `User description:\n${transcript}`,
          ].join("\n"),
        }],
      }],
      max_output_tokens: 2_000,
      safety_identifier: await safetyIdentifier(userId),
      store: false,
    }),
    signal: AbortSignal.timeout(
      onboardingPhaseTimeout(deadlineMs, ONBOARDING_ANALYSIS_TIMEOUT_MS),
    ),
  });
  if (!response.ok) {
    throw new Error(`Onboarding analysis failed (${response.status})`);
  }
  const payload = await response.json() as Record<string, unknown>;
  return {
    recommendation: createOnboardingRecommendation(
      JSON.parse(responseOutputText(payload)),
    ),
    responseId: typeof payload.id === "string" ? payload.id : null,
  };
}
