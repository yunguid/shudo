import { responseOutputText } from "./analysis.ts";
import { requiredEnv } from "./http.ts";

export const WEEKLY_SUMMARY_MODEL = "gpt-5.6-sol";

export const WEEKLY_SUMMARY_SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    headline: { type: "string", minLength: 1, maxLength: 120 },
    narrative: { type: "string", minLength: 1, maxLength: 600 },
    patterns: {
      type: "array",
      maxItems: 4,
      items: { type: "string", minLength: 1, maxLength: 220 },
    },
    suggestions: {
      type: "array",
      maxItems: 3,
      items: { type: "string", minLength: 1, maxLength: 220 },
    },
  },
  required: ["headline", "narrative", "patterns", "suggestions"],
} as const;

export type WeeklyEntry = {
  local_day: string;
  title: string | null;
  items: unknown;
  calories_kcal: number | string;
  protein_g: number | string;
  carbs_g: number | string;
  fat_g: number | string;
};

export type WeeklyTarget = {
  target_day: string;
  calories_kcal: number | string;
  protein_g: number | string;
  carbs_g: number | string;
  fat_g: number | string;
};

export type WeeklyMetrics = {
  days_logged: number;
  meals_logged: number;
  average_calories_kcal: number;
  average_protein_g: number;
  average_carbs_g: number;
  average_fat_g: number;
  calorie_target_days: number;
  protein_target_days: number;
  target_calories_kcal: number;
  target_protein_g: number;
};

export type RepeatedFood = { name: string; count: number };

function numeric(value: number | string): number {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function rounded(value: number): number {
  return Math.round(value * 10) / 10;
}

export function priorCompletedWeekStart(
  date: Date,
  timezone: string,
): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const values = Object.fromEntries(
    parts.map((part) => [part.type, part.value]),
  );
  const localMidnight = new Date(
    Date.UTC(Number(values.year), Number(values.month) - 1, Number(values.day)),
  );
  const isoDay = localMidnight.getUTCDay() || 7;
  localMidnight.setUTCDate(localMidnight.getUTCDate() - isoDay - 6);
  return localMidnight.toISOString().slice(0, 10);
}

export function safePriorCompletedWeekStart(
  date: Date,
  timezone: string,
): string | null {
  try {
    return priorCompletedWeekStart(date, timezone);
  } catch {
    return null;
  }
}

export function addCalendarDays(day: string, count: number): string {
  const date = new Date(`${day}T00:00:00.000Z`);
  date.setUTCDate(date.getUTCDate() + count);
  return date.toISOString().slice(0, 10);
}

export function aggregateWeeklyEntries(
  entries: WeeklyEntry[],
  targetHistory: WeeklyTarget[],
  fallbackTarget: Record<string, unknown> = {},
): {
  adherence: WeeklyMetrics;
  repeatedFoods: RepeatedFood[];
  foodCandidates: RepeatedFood[];
} {
  const days = new Map<string, {
    calories: number;
    protein: number;
    carbs: number;
    fat: number;
  }>();
  const foodCounts = new Map<string, { name: string; count: number }>();

  for (const entry of entries) {
    const totals = days.get(entry.local_day) ?? {
      calories: 0,
      protein: 0,
      carbs: 0,
      fat: 0,
    };
    totals.calories += numeric(entry.calories_kcal);
    totals.protein += numeric(entry.protein_g);
    totals.carbs += numeric(entry.carbs_g);
    totals.fat += numeric(entry.fat_g);
    days.set(entry.local_day, totals);

    const items = Array.isArray(entry.items) ? entry.items : [];
    const names = new Set<string>();
    for (const item of items) {
      if (!item || typeof item !== "object" || Array.isArray(item)) continue;
      const rawName = (item as Record<string, unknown>).name;
      if (typeof rawName !== "string") continue;
      const name = rawName.trim();
      if (name) names.add(name);
    }
    if (names.size === 0 && entry.title?.trim()) names.add(entry.title.trim());
    for (const name of names) {
      const key = name.toLocaleLowerCase();
      const prior = foodCounts.get(key) ?? { name, count: 0 };
      prior.count += 1;
      foodCounts.set(key, prior);
    }
  }

  const orderedTargets = [...targetHistory]
    .filter((target) => /^\d{4}-\d{2}-\d{2}$/.test(target.target_day))
    .sort((left, right) => left.target_day.localeCompare(right.target_day));
  const effectiveTarget = (localDay: string): Record<string, unknown> => {
    let target: WeeklyTarget | undefined;
    for (const candidate of orderedTargets) {
      if (candidate.target_day > localDay) break;
      target = candidate;
    }
    return target ?? fallbackTarget;
  };
  const dayTotals = [...days.entries()]
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([localDay, totals]) => ({
      ...totals,
      target: effectiveTarget(localDay),
    }));
  const denominator = Math.max(dayTotals.length, 1);
  const sum = (field: "calories" | "protein" | "carbs" | "fat"): number =>
    dayTotals.reduce((total, day) => total + day[field], 0);
  const targetCalories = dayTotals.map((day) =>
    numeric(
      (day.target.calories_kcal as number | string | undefined) ?? 0,
    )
  );
  const targetProtein = dayTotals.map((day) =>
    numeric((day.target.protein_g as number | string | undefined) ?? 0)
  );
  const averagePositive = (values: number[]): number => {
    const positive = values.filter((value) => value > 0);
    return positive.length > 0
      ? positive.reduce((total, value) => total + value, 0) / positive.length
      : 0;
  };
  const adherence: WeeklyMetrics = {
    days_logged: dayTotals.length,
    meals_logged: entries.length,
    average_calories_kcal: rounded(sum("calories") / denominator),
    average_protein_g: rounded(sum("protein") / denominator),
    average_carbs_g: rounded(sum("carbs") / denominator),
    average_fat_g: rounded(sum("fat") / denominator),
    calorie_target_days:
      dayTotals.filter((day, index) =>
        targetCalories[index] > 0 &&
        day.calories >= targetCalories[index] * 0.9 &&
        day.calories <= targetCalories[index] * 1.1
      ).length,
    protein_target_days:
      dayTotals.filter((day, index) =>
        targetProtein[index] > 0 &&
        day.protein >= targetProtein[index] * 0.9
      ).length,
    target_calories_kcal: rounded(averagePositive(targetCalories)),
    target_protein_g: rounded(averagePositive(targetProtein)),
  };
  const foodCandidates = [...foodCounts.values()]
    .sort((left, right) =>
      right.count - left.count ||
      left.name.localeCompare(right.name)
    )
    .slice(0, 20);
  const repeatedFoods = foodCandidates
    .filter((food) => food.count >= 2)
    .slice(0, 8);
  return { adherence, repeatedFoods, foodCandidates };
}

function boundedString(value: unknown, label: string, max: number): string {
  if (typeof value !== "string" || !value.trim() || value.trim().length > max) {
    throw new Error(`Invalid weekly summary ${label}`);
  }
  return value.trim();
}

function boundedStrings(
  value: unknown,
  label: string,
  maxItems: number,
): string[] {
  if (!Array.isArray(value) || value.length > maxItems) {
    throw new Error(`Invalid weekly summary ${label}`);
  }
  return value.map((item) => boundedString(item, label, 220));
}

export function parseWeeklyNarrative(value: unknown): {
  headline: string;
  narrative: string;
  patterns: string[];
  suggestions: string[];
} {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Invalid weekly summary response");
  }
  const object = value as Record<string, unknown>;
  return {
    headline: boundedString(object.headline, "headline", 120),
    narrative: boundedString(object.narrative, "narrative", 600),
    patterns: boundedStrings(object.patterns, "patterns", 4),
    suggestions: boundedStrings(object.suggestions, "suggestions", 3),
  };
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

export async function writeWeeklyNarrative(
  userId: string,
  weekStart: string,
  adherence: WeeklyMetrics,
  repeatedFoods: RepeatedFood[],
  foodCandidates: RepeatedFood[] = repeatedFoods,
): Promise<{
  headline: string;
  narrative: string;
  patterns: string[];
  suggestions: string[];
  responseId: string | null;
}> {
  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      authorization: `Bearer ${requiredEnv("OPENAI_API_KEY")}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: WEEKLY_SUMMARY_MODEL,
      reasoning: { effort: "low" },
      text: {
        verbosity: "low",
        format: {
          type: "json_schema",
          name: "shudo_weekly_summary",
          strict: true,
          schema: WEEKLY_SUMMARY_SCHEMA,
        },
      },
      input: [{
        role: "user",
        content: [{
          type: "input_text",
          text: [
            "Write a concise weekly meal-log reflection from the supplied computed metrics.",
            "Do not recalculate or contradict the metrics. Mention incomplete logging plainly.",
            "Use the bounded food candidate list to notice obviously similar meal patterns (for example variations of a wrap or bowl), but cluster conservatively and never invent a frequency.",
            "Offer practical food-logging or meal-pattern suggestions only. Do not diagnose, prescribe treatment, or make medical claims.",
            `Week starting: ${weekStart}`,
            `Computed adherence: ${JSON.stringify(adherence)}`,
            `Repeated foods: ${JSON.stringify(repeatedFoods)}`,
            `Food candidates: ${JSON.stringify(foodCandidates)}`,
          ].join("\n"),
        }],
      }],
      max_output_tokens: 1_000,
      safety_identifier: await safetyIdentifier(userId),
      store: false,
    }),
    signal: AbortSignal.timeout(75_000),
  });
  if (!response.ok) {
    throw new Error(`Weekly summary failed (${response.status})`);
  }
  const payload = await response.json() as Record<string, unknown>;
  return {
    ...parseWeeklyNarrative(JSON.parse(responseOutputText(payload))),
    responseId: typeof payload.id === "string" ? payload.id : null,
  };
}
