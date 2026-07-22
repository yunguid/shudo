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
import { isUuid, requiredEnv } from "./http.ts";

export const ONBOARDING_MODEL = "gpt-5.6-sol";
export const ONBOARDING_TRANSCRIPTION_MODEL = "gpt-4o-transcribe";
export const ONBOARDING_PROCESSING_BUDGET_MS = 125_000;
export const ONBOARDING_TRANSCRIPTION_TIMEOUT_MS = 55_000;
export const ONBOARDING_ANALYSIS_TIMEOUT_MS = 65_000;
export const MAX_ONBOARDING_AUDIO_BYTES = 25 * 1024 * 1024;
export const MAX_ONBOARDING_TEXT_CHARACTERS = 30_000;

export const ONBOARDING_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    summary: { type: "string", minLength: 1, maxLength: 500 },
    display_name: { type: ["string", "null"], maxLength: 80 },
    goal_type: { type: "string", enum: ["maintain", "lose", "gain"] },
    goal_notes: { type: "string", maxLength: 2_000 },
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
    calories_kcal: { type: "number", minimum: 500, maximum: 10_000 },
    protein_g: { type: "number", minimum: 0, maximum: 1_000 },
    carbs_g: { type: "number", minimum: 0, maximum: 1_500 },
    fat_g: { type: "number", minimum: 0, maximum: 1_000 },
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
    "calories_kcal",
    "protein_g",
    "carbs_g",
    "fat_g",
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
};

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
  if ((!allowEmpty && !normalized) || normalized.length > maxLength) {
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

export function parseOnboardingRecommendation(
  value: unknown,
): OnboardingRecommendation {
  const object = record(value, "recommendation");
  const goalType = object.goal_type;
  if (!(["maintain", "lose", "gain"] as unknown[]).includes(goalType)) {
    throw new Error("Invalid goal_type");
  }
  const recommendation: OnboardingRecommendation = {
    summary: textValue(object.summary, "summary", 500),
    display_name: nullableText(object.display_name, "display_name", 80),
    goal_type: goalType as OnboardingRecommendation["goal_type"],
    goal_notes: textValue(object.goal_notes, "goal_notes", 2_000, true),
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
      500,
      10_000,
    ),
    protein_g: boundedNumber(object.protein_g, "protein_g", 0, 1_000),
    carbs_g: boundedNumber(object.carbs_g, "carbs_g", 0, 1_500),
    fat_g: boundedNumber(object.fat_g, "fat_g", 0, 1_000),
    assumptions: shortStrings(object.assumptions, "assumptions", 6),
    suggestions: shortStrings(object.suggestions, "suggestions", 4),
  };
  const caloriesFromMacros = recommendation.protein_g * 4 +
    recommendation.carbs_g * 4 + recommendation.fat_g * 9;
  const allowedDifference = Math.max(150, recommendation.calories_kcal * 0.12);
  if (
    Math.abs(caloriesFromMacros - recommendation.calories_kcal) >
      allowedDifference
  ) {
    throw new Error("Daily macros do not match the calorie target");
  }
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
  return {
    timezone: validateTimezone(timezone),
    display_name: nullableText(candidate.display_name, "display_name", 80),
    goal_type: parseOnboardingRecommendation({
      ...recommendation,
      goal_type: candidate.goal_type,
    }).goal_type,
    goal_notes: textValue(candidate.goal_notes, "goal_notes", 2_000, true),
    height_cm: nullableNumber(candidate.height_cm, "height_cm", 50, 275),
    weight_kg: nullableNumber(candidate.weight_kg, "weight_kg", 20, 500),
    target_weight_kg: nullableNumber(
      candidate.target_weight_kg,
      "target_weight_kg",
      20,
      500,
    ),
    activity_level: activityLevel(candidate.activity_level),
    calories_kcal: boundedNumber(
      candidate.calories_kcal,
      "calories_kcal",
      500,
      10_000,
    ),
    protein_g: boundedNumber(candidate.protein_g, "protein_g", 0, 1_000),
    carbs_g: boundedNumber(candidate.carbs_g, "carbs_g", 0, 1_500),
    fat_g: boundedNumber(candidate.fat_g, "fat_g", 0, 1_000),
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
    "Personal nutrition onboarding. Preserve stated goals, routines, foods, quantities, height, weight, units, and corrections accurately.",
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
            "Create a practical nutrition tracking profile from this user's own description.",
            "Use only stated facts plus conservative, clearly named assumptions.",
            "Choose calories from the stated height, weight, activity, and direction of the goal when available. Never invent age, sex, or unstated measurements; name missing inputs as assumptions and avoid false precision.",
            "Choose protein first for the stated goal, then practical fat and carbohydrate targets. Ensure protein*4 + carbs*4 + fat*9 is within 5 percent of calories_kcal.",
            "Targets are editable estimates, not prescriptions. Do not diagnose a condition, interpret symptoms, recommend medication, or give treatment advice.",
            "Avoid aggressive restriction. If the user mentions a medical issue, keep the summary neutral and suggest discussing individualized targets with a qualified clinician.",
            "Keep suggestions specific, non-medical, and easy to act on.",
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
    recommendation: parseOnboardingRecommendation(
      JSON.parse(responseOutputText(payload)),
    ),
    responseId: typeof payload.id === "string" ? payload.id : null,
  };
}
