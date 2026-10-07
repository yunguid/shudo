import type { coachFakeAdmin, Row } from "./coach_fake_admin.ts";

/// The golden day: Luke on Wednesday 2026-10-07 at 13:05 in New York.
/// Lean bulk 162.5 → 175 lb, office at 9:30 six days a week, a 10-minute
/// bike this morning, chest day tonight at the Monterey Gym, and the usual
/// miss: 780 cal and 28 g protein by lunch. No scale yet. Seeded memory
/// still has three open questions. Offline tests render prompts from this
/// and assert on what the coach actually gets to see.

export const LUKE = "6327f491-5e4a-415f-b174-fcc67bb9bf16";
export const GOLDEN_NOW = new Date("2026-10-07T17:05:00Z"); // Wed 13:05 EDT
export const GOLDEN_DAY = "2026-10-07";
export const SANDWICH = "a1a1a1a1-0000-4000-8000-000000000002";
export const BREAKFAST = "a1a1a1a1-0000-4000-8000-000000000001";
export const BACK_DAY = "b2b2b2b2-0000-4000-8000-000000000002";

export const OPEN_QUESTIONS =
  "Does he have a bathroom scale yet (ordering one)? Which gym / what equipment now? Which days can he realistically lift?";

export function goldenMemorySections(): Row {
  return {
    bio: {
      about:
        "Luke. Lives in the city again after a stretch in Northern Virginia. Works about six days a week and has to be in the office around 9:30am.",
      role_models:
        "Big fan of Sam Sulek: high volume, eat big, simple and fired up.",
      schedule:
        "Office ~9:30am, six days a week. Bed around 11:30pm to midnight; wants earlier. Doing ~10 minutes on the bike in the morning lately.",
      training_history:
        "Started lifting senior year of high school at ~120 lb. COVID year: gallons of milk, backpack Bulgarian split squats. Peaked ~172 lb in Northern Virginia.",
      current_training:
        "Rebuilding. Lifts 2-3 times a week, not pushing as hard as before.",
      nutrition: "Eats very little right now. Thrived on milk and easy food.",
      goals: "Bulk back up to ~175 lb and make training fun again.",
      equipment: "Rebuilding his setup; needs pre-workout.",
      handle_with_care:
        "During the Virginia stretch he was in great shape but completely alone. Don't bring it up unprompted.",
    },
    notes: {
      running_jokes:
        "Milk era (the COVID gallon-of-milk bulk). Backpack Bulgarian split squats.",
      open_questions: OPEN_QUESTIONS,
      n_20261005_1: "pattern: Eats almost nothing until lunch on office days.",
      n_20261006_1: "commitment: Buy whey and pre-workout on Saturday.",
    },
    schedule: {
      wake: "07:00",
      office_start: "09:30",
      office_days: ["mon", "tue", "wed", "thu", "fri", "sat"],
      lift_days: ["mon", "wed", "fri"],
      lift_time: "18:30",
      bed: "23:45",
      target_bed: "23:00",
    },
    equipment: [],
  };
}

function message(
  id: string,
  role: "coach" | "user",
  body: string,
  day: string,
  at: string,
  extra: Row = {},
): Row {
  return {
    id,
    user_id: LUKE,
    role,
    kind: "text",
    body,
    payload: {},
    local_day: day,
    deliver_at: at,
    slot_key: null,
    status: "delivered",
    created_at: at,
    ...extra,
  };
}

export function goldenTables(): Record<string, Row[]> {
  return {
    profiles: [{
      user_id: LUKE,
      display_name: "Luke",
      timezone: "America/New_York",
      units: "imperial",
      goal_type: "gain",
      goal_notes: null,
      daily_macro_target: {
        calories_kcal: 3000,
        protein_g: 170,
        carbs_g: 400,
        fat_g: 85,
      },
      weight_kg: 73.71,
      target_weight_kg: 79.38,
      height_cm: 178,
      activity_level: "moderate",
      goal_date: "2027-03-01",
      goal_started_on: "2026-10-06",
      goal_start_weight_kg: 73.71,
      coach_enabled: true,
      coach_intensity: "locked_in",
      coach_profanity: "mild",
      quiet_hours_start: "23:00:00",
      quiet_hours_end: "07:00:00",
      location_recs_enabled: false,
      physique_ai_review_enabled: false,
    }],
    coach_memory: [{
      user_id: LUKE,
      version: 4,
      document: "(stored markdown; prompts render from sections)",
      sections: goldenMemorySections(),
    }],
    entries: [
      {
        id: BREAKFAST,
        user_id: LUKE,
        local_day: GOLDEN_DAY,
        occurred_at: "2026-10-07T11:50:00Z",
        created_at: "2026-10-07T11:50:00Z",
        updated_at: "2026-10-07T11:51:00Z",
        title: "Coffee and a banana",
        status: "complete",
        calories_kcal: 140,
        protein_g: 2,
        carbs_g: 30,
        fat_g: 1,
      },
      {
        id: SANDWICH,
        user_id: LUKE,
        local_day: GOLDEN_DAY,
        occurred_at: "2026-10-07T16:40:00Z",
        created_at: "2026-10-07T16:40:00Z",
        updated_at: "2026-10-07T16:41:00Z",
        title: "Turkey sandwich and chips",
        status: "complete",
        calories_kcal: 640,
        protein_g: 26,
        carbs_g: 70,
        fat_g: 24,
      },
    ],
    activities: [
      {
        id: "c3c3c3c3-0000-4000-8000-000000000001",
        user_id: LUKE,
        local_day: "2026-09-30",
        occurred_at: "2026-09-30T22:40:00Z",
        updated_at: "2026-09-30T23:40:00Z",
        title: "Chest day",
        kind: "strength",
        status: "complete",
        duration_min: 55,
        active_kcal: 260,
        details: {
          exercises: [
            {
              name: "Bench press",
              key: "bench_press",
              sets: [
                { reps: 10, weight: 135, unit: "lb", is_warmup: true },
                { reps: 6, weight: 185, unit: "lb" },
                { reps: 5, weight: 185, unit: "lb" },
              ],
            },
            {
              name: "Incline DB press",
              key: "incline_db_press",
              sets: [{ reps: 8, weight: 70, unit: "lb" }],
            },
          ],
          prs: [{
            exercise: "Bench press",
            key: "bench_press",
            kind: "weight",
            value: 185,
            unit: "lb",
            weight: 185,
            reps: 6,
            previous: 180,
          }],
        },
      },
      {
        id: BACK_DAY,
        user_id: LUKE,
        local_day: "2026-10-05",
        occurred_at: "2026-10-05T22:35:00Z",
        updated_at: "2026-10-05T23:30:00Z",
        title: "Back day",
        kind: "strength",
        status: "complete",
        duration_min: 48,
        active_kcal: 230,
        details: {
          exercises: [
            {
              name: "Barbell row",
              key: "barbell_row",
              sets: [{ reps: 10, weight: 135, unit: "lb" }],
            },
            {
              name: "Pull-ups",
              key: "pull_up",
              sets: [{ reps: 8, weight: 0, unit: "lb" }],
            },
          ],
          prs: [],
        },
      },
      {
        id: "c3c3c3c3-0000-4000-8000-000000000003",
        user_id: LUKE,
        local_day: GOLDEN_DAY,
        occurred_at: "2026-10-07T11:15:00Z",
        updated_at: "2026-10-07T11:30:00Z",
        title: "Morning bike",
        kind: "cardio",
        status: "complete",
        duration_min: 10,
        active_kcal: 70,
        details: {},
      },
    ],
    weight_checkins: [],
    day_digests: [
      {
        user_id: LUKE,
        local_day: "2026-10-05",
        headline: "Back day done, food short again",
        summary: "Rows and pull-ups after work. About 2,100 cal logged.",
        metrics: { calories_kcal: 2100, protein_g: 120 },
        score: 60,
        tomorrow_focus: ["Breakfast before 9"],
        game_plan: {},
      },
      {
        user_id: LUKE,
        local_day: "2026-10-06",
        headline: "Rest day, under-ate: 1,900 of 3,000 cal",
        summary:
          "Coffee until lunch again. Dinner was solid. Rest days still need the full number.",
        metrics: { calories_kcal: 1900, protein_g: 110 },
        score: 55,
        tomorrow_focus: ["Real breakfast before 9", "Shake at 3"],
        game_plan: {
          theme: "Eat early, lift heavy",
          focus: ["Real breakfast before 9", "Shake at 3"],
          training: { session_name: "Chest day" },
        },
      },
    ],
    coach_messages: [
      message(
        "d4d4d4d4-0000-4000-8000-000000000001",
        "user",
        "chest day tomorrow at the Monterey Gym, finally. need to grab pre-workout",
        "2026-10-06",
        "2026-10-07T01:40:00Z",
      ),
      message(
        "d4d4d4d4-0000-4000-8000-000000000002",
        "coach",
        "Good. Eat dinner first and pack the shoes tonight.",
        "2026-10-06",
        "2026-10-07T01:41:00Z",
      ),
      message(
        "d4d4d4d4-0000-4000-8000-000000000003",
        "coach",
        "Chest day. Breakfast before you walk out, then a real lunch.",
        GOLDEN_DAY,
        "2026-10-07T11:10:00Z",
        { kind: "plan", slot_key: "wake" },
      ),
    ],
  };
}

/// The ledger's save_coach_memory only records calls; this makes it write
/// through to the table so the next turn loads what the last one saved.
export function persistMemorySaves(
  fake: ReturnType<typeof coachFakeAdmin>,
): void {
  const record = fake.rpc.save_coach_memory;
  fake.rpc.save_coach_memory = (args) => {
    const result = record?.(args) as Row | undefined;
    const version = Number(args.p_expected_version) + 1;
    fake.tables.coach_memory = [{
      user_id: args.p_user_id,
      version,
      document: args.p_document,
      sections: structuredClone(args.p_sections),
    }];
    return result ?? { status: "saved", version };
  };
}
