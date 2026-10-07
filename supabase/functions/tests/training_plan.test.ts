import {
  computedSessionMinutes,
  draftTrainingPlan,
  nextSession,
  planMemoryContext,
  TRAINING_PLAN_SYSTEM,
  type TrainingPlanDoc,
  validateTrainingPlan,
  weeklySetsByMuscle,
} from "../_shared/training_plan.ts";
import { assert, assertEquals } from "./assertions.ts";
import {
  fakeClaude,
  jsonTextEvents,
  promptText,
  type RecordedRequest,
} from "./fake_claude.ts";
import { fakeAdmin, fakeLedger } from "./fake_rest_admin.ts";

const USER = "11111111-1111-4111-8111-111111111111";
const PLAN_ID = "77777777-7777-4777-8777-777777777777";

function exercise(
  name: string,
  key: string,
  sets = 3,
  repMin = 6,
  repMax = 10,
  rest = 120,
) {
  return {
    name,
    exercise_key: key,
    sets,
    rep_min: repMin,
    rep_max: repMax,
    rest_sec: rest,
    progression: "double",
    increment_lb: 5,
    cue: null,
  };
}

function upperLowerPlan() {
  return {
    name: "Upper/Lower 4x",
    phase: "lean_bulk",
    sessions_per_week: 4,
    rotation: ["upper_a", "lower_a", "upper_b", "lower_b"],
    sessions: [
      {
        id: "upper_a",
        name: "Upper A",
        focus: "chest/back",
        est_minutes: 60,
        exercises: [
          exercise("Barbell bench press", "barbell_bench_press", 4, 6, 8, 150),
          exercise("Barbell row", "barbell_row", 4, 6, 10, 120),
          exercise("Dumbbell shoulder press", "dumbbell_shoulder_press", 3, 8, 10, 90),
          exercise("Lat pulldown", "lat_pulldown", 3, 8, 12, 90),
          exercise("Lateral raise", "lateral_raise", 3, 12, 15, 60),
          exercise("EZ-bar curl", "ez_bar_curl", 3, 8, 12, 60),
        ],
      },
      {
        id: "lower_a",
        name: "Lower A",
        focus: "squat",
        est_minutes: 60,
        exercises: [
          exercise("Back squat", "back_squat", 4, 6, 8, 180),
          exercise("Romanian deadlift", "romanian_deadlift", 3, 8, 10, 120),
          exercise("Leg press", "leg_press", 3, 10, 12, 120),
          exercise("Lying leg curl", "lying_leg_curl", 3, 10, 12, 60),
          exercise("Standing calf raise", "standing_calf_raise", 3, 10, 15, 60),
        ],
      },
      {
        id: "upper_b",
        name: "Upper B",
        focus: "shoulders/arms",
        est_minutes: 60,
        exercises: [
          exercise("Incline dumbbell press", "incline_dumbbell_press", 4, 8, 10, 120),
          exercise("Chest-supported row", "chest_supported_row", 4, 8, 12, 90),
          exercise("Pull-up", "pull_up", 3, 6, 10, 120),
          exercise("Cable fly", "cable_fly", 3, 10, 15, 60),
          exercise("Triceps pushdown", "tricep_pushdown", 3, 10, 12, 60),
          exercise("Hammer curl", "hammer_curl", 3, 10, 12, 60),
        ],
      },
      {
        id: "lower_b",
        name: "Lower B",
        focus: "hinge",
        est_minutes: 55,
        exercises: [
          exercise("Deadlift", "deadlift", 3, 5, 8, 180),
          exercise("Bulgarian split squat", "bulgarian_split_squat", 3, 8, 10, 90),
          exercise("Leg extension", "leg_extension", 3, 10, 15, 60),
          exercise("Seated leg curl", "seated_leg_curl", 3, 10, 12, 60),
          exercise("Hanging leg raise", "hanging_leg_raise", 3, 10, 15, 60),
        ],
      },
    ],
    conditioning: { kind: "bike", minutes: 10, when: "morning", optional: true },
    equipment_assumed: ["commercial gym"],
    notes: "Rotation is a queue: miss a day and the next session waits.",
  };
}

function planResponse(plan: unknown = upperLowerPlan(), overrides: Record<string, unknown> = {}) {
  return {
    plan,
    rationale: "Four rotating sessions fit a six-day work week with evening lifts.",
    change_summary: null,
    summary: "4 days a week, upper/lower, about 60 minutes, double progression in 6–10.",
    coach_message:
      "Built you a four-day upper/lower queue. Miss a day and it just waits for you. Bench and rows lead the way. Start with Upper A tonight?",
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// Validator
// ---------------------------------------------------------------------------

Deno.test("a sound upper/lower plan validates into TrainingPlanDoc v1", () => {
  const result = validateTrainingPlan(upperLowerPlan());
  assertEquals(result.errors, []);
  assert(result.ok && result.plan);
  const plan = result.plan;
  assertEquals(plan.version, 1);
  assertEquals(plan.rotation, ["upper_a", "lower_a", "upper_b", "lower_b"]);
  assertEquals(plan.sessions[0].exercises[0], {
    name: "Barbell bench press",
    key: "barbell_bench_press",
    sets: 4,
    rep_min: 6,
    rep_max: 8,
    rest_sec: 150,
    progression: "double",
    increment_lb: 5,
    cue: null,
  });
  assertEquals(plan.conditioning, {
    kind: "bike",
    minutes: 10,
    when: "morning",
    optional: true,
  });
  const volume = weeklySetsByMuscle(plan);
  assertEquals(volume.chest, 11); // bench 4 + incline 4 + fly 3, one cycle per week
  assertEquals(volume.back, 17);
  assert((volume.back ?? 0) >= 8);
});

Deno.test("structural problems are errors", () => {
  const oneSession = { ...upperLowerPlan(), sessions: [upperLowerPlan().sessions[0]] };
  const result = validateTrainingPlan(oneSession);
  assertEquals(result.ok, false);
  assert(result.errors[0].includes("2 to 6 distinct sessions"));

  const thin = upperLowerPlan();
  thin.sessions[1].exercises = thin.sessions[1].exercises.slice(0, 2);
  assert(validateTrainingPlan(thin).errors.some((error) => error.includes("lower_a needs 3 to 9")));

  const marathon = upperLowerPlan();
  marathon.sessions[0].exercises = marathon.sessions[0].exercises.map((item) => ({
    ...item,
    sets: 6,
    rest_sec: 300,
  }));
  assert(validateTrainingPlan(marathon).errors.some((error) => error.includes("too long")));

  assertEquals(validateTrainingPlan(null).ok, false);
  assertEquals(validateTrainingPlan({ ...upperLowerPlan(), name: "" }).ok, false);
});

Deno.test("numeric slips are clamped with warnings, ids and rotation repaired", () => {
  const plan = upperLowerPlan() as Record<string, unknown> & ReturnType<typeof upperLowerPlan>;
  plan.sessions[0].id = "Upper A";
  plan.sessions[0].exercises[0] = {
    ...plan.sessions[0].exercises[0],
    sets: 8,
    rep_max: 30,
    rest_sec: 600,
  };
  plan.rotation = ["Upper A", "lower_a", "ghost_day", "upper_b", "lower_b"];
  plan.sessions_per_week = 9;
  plan.conditioning = { kind: "bike", minutes: 45, when: "whenever", optional: true };
  const result = validateTrainingPlan(plan);
  assert(result.ok && result.plan, result.errors.join("; "));
  const bench = result.plan.sessions[0].exercises[0];
  assertEquals([bench.sets, bench.rep_max, bench.rest_sec], [6, 20, 300]);
  assertEquals(result.plan.sessions[0].id, "upper_a");
  assertEquals(result.plan.rotation, ["upper_a", "lower_a", "upper_b", "lower_b"]);
  assertEquals(result.plan.sessions_per_week, 6);
  assertEquals(result.plan.conditioning?.minutes, 30);
  assertEquals(result.plan.conditioning?.when, "any");
  assert(result.warnings.some((warning) => warning.includes("adjusted")));
});

Deno.test("unknown lifts keep a custom key; duplicates and extras are trimmed", () => {
  const plan = upperLowerPlan();
  plan.sessions[0].exercises.push(
    exercise("Barbell bench press", "barbell_bench_press"),
    exercise("Meadows row", "custom"),
    exercise("Cable curl", "cable_curl"),
    exercise("Face pull", "face_pull"),
    exercise("Shrug", "barbell_shrug"),
  );
  const result = validateTrainingPlan(plan);
  assert(result.ok && result.plan);
  const keys = result.plan.sessions[0].exercises.map((item) => item.key);
  assertEquals(keys.length, 9);
  assertEquals(keys.filter((key) => key === "barbell_bench_press").length, 1);
  assert(keys.includes("custom:meadows_row"));
  assert(result.warnings.some((warning) => warning.includes("duplicate")));
});

Deno.test("computed session minutes include warm-up, work, and rest", () => {
  const minutes = computedSessionMinutes([
    {
      name: "Bench",
      key: "barbell_bench_press",
      sets: 4,
      rep_min: 6,
      rep_max: 8,
      rest_sec: 150,
      progression: "double",
      increment_lb: 5,
      cue: null,
    },
  ]);
  assertEquals(minutes, 5 + 4 * (0.75 + 2.5));
});

// ---------------------------------------------------------------------------
// Rotation queue
// ---------------------------------------------------------------------------

function docWithRotation(rotation: string[]): TrainingPlanDoc {
  const ids = [...new Set(rotation)];
  return {
    version: 1,
    name: "Test",
    phase: "lean_bulk",
    sessions_per_week: 4,
    rotation,
    sessions: ids.map((id) => ({
      id,
      name: id,
      focus: "",
      est_minutes: 60,
      exercises: [],
    })),
    conditioning: null,
    equipment_assumed: [],
    notes: "",
  };
}

Deno.test("nextSession walks the rotation queue and wraps", () => {
  const plan = docWithRotation(["upper_a", "lower_a", "upper_b", "lower_b"]);
  assertEquals(nextSession(plan, []), "upper_a");
  assertEquals(nextSession(plan, ["upper_a"]), "lower_a");
  assertEquals(nextSession(plan, ["upper_a", "lower_a", "upper_b"]), "lower_b");
  assertEquals(nextSession(plan, ["upper_b", "lower_b"]), "upper_a");
  // Ids that are not in the rotation (old plans, freestyle days) are ignored.
  assertEquals(nextSession(plan, ["upper_a", "arm_day", "old_plan_x"]), "lower_a");
});

Deno.test("nextSession disambiguates repeated ids by recent history", () => {
  const plan = docWithRotation(["full_a", "full_b", "full_a", "full_c"]);
  assertEquals(nextSession(plan, ["full_c", "full_a"]), "full_b");
  assertEquals(nextSession(plan, ["full_a", "full_b", "full_a"]), "full_c");
  assertEquals(nextSession(docWithRotation([]), []), "");
});

// ---------------------------------------------------------------------------
// Context and drafting
// ---------------------------------------------------------------------------

Deno.test("plan context includes bio, schedule, equipment, never handle_with_care", () => {
  const context = planMemoryContext({
    bio: {
      schedule: "Office by 9:30, six days a week.",
      equipment: "Commercial gym near the office.",
      handle_with_care: "Private history the coach must not raise.",
    },
    schedule: { lift_days: ["mon", "wed", "fri", "sat"], lift_time: "18:15" },
    equipment: ["barbell", "dumbbells to 80"],
    notes: { prefs: "Likes arm work at the end." },
  });
  const text = JSON.stringify(context);
  assert(text.includes("Office by 9:30"));
  assert(text.includes("dumbbells to 80"));
  assert(text.includes("lift_time"));
  assert(text.includes("Likes arm work"));
  assert(!text.includes("Private history"));
});

function planSetup(
  options: { claimStatus?: string; saveResult?: unknown; existing?: boolean } = {},
) {
  const ledger = fakeLedger({ claimStatus: options.claimStatus });
  const saves: Array<Record<string, unknown>> = [];
  const fake = fakeAdmin({
    tables: {
      profiles: [{
        user_id: USER,
        timezone: "America/New_York",
        units: "imperial",
        goal_type: "gain",
        weight_kg: 73.71,
        target_weight_kg: 79.38,
        goal_date: null,
        coach_profanity: "mild",
      }],
      coach_memory: [{
        user_id: USER,
        version: 3,
        sections: {
          bio: {
            schedule: "Works six days a week, office by 9:30.",
            training_history: "Body-part splits for years.",
            handle_with_care: "Do not raise.",
          },
          schedule: { office_start: "09:30", lift_time: "18:15" },
          equipment: ["commercial gym"],
        },
      }],
      training_plans: options.existing
        ? [{
          id: PLAN_ID,
          user_id: USER,
          status: "draft",
          run_id: ledger.runId,
          plan: validateTrainingPlan(upperLowerPlan()).plan,
          change_summary: "4 days a week.",
        }]
        : [],
      activities: [{
        user_id: USER,
        status: "complete",
        local_day: "2099-01-01",
        occurred_at: "2099-01-01T22:00:00Z",
        kind: "strength",
        title: "Chest and arms",
        duration_min: 50,
        details: {
          exercises: [{
            name: "Barbell bench press",
            key: "barbell_bench_press",
            sets: [{ reps: 8, weight: 175, unit: "lb" }],
          }],
        },
      }],
    },
    rpc: {
      ...ledger.handlers,
      save_training_plan_draft(args) {
        saves.push(args);
        return options.saveResult ?? { status: "saved", plan_id: PLAN_ID };
      },
    },
  });
  return { ...fake, ledger, saves };
}

Deno.test("draftTrainingPlan runs Opus high, saves the draft, and posts a card", async () => {
  const env = planSetup();
  const requests: RecordedRequest[] = [];
  const result = await draftTrainingPlan(env.admin as never, USER, {
    instructions: "Four days, evenings, and keep arms in there.",
    reason: "first_plan",
  }, { client: fakeClaude([jsonTextEvents(planResponse())], requests) });

  assertEquals(result.planId, PLAN_ID);
  assertEquals(result.plan.version, 1);
  assertEquals(requests.length, 1);
  assertEquals(requests[0].model, "claude-opus-5-5");
  assertEquals((requests[0].output_config as { effort?: string }).effort, "high");
  assert(requests[0].output_config?.format);
  const prompt = promptText(requests[0]);
  assert(prompt.includes("4-day upper/lower rotation"));
  assert(prompt.includes("double progression") || prompt.includes("Double progression"));
  assert(prompt.includes("office by 9:30"));
  assert(prompt.includes("keep arms in there"));
  assert(!prompt.includes("Do not raise."));

  const claim = env.ledger.claims[0];
  assertEquals(claim.p_operation, "training_plan");
  assert(String(claim.p_checkpoint_key).startsWith("training_plan:"));
  assertEquals(claim.p_trigger_source, "user");

  assertEquals(env.saves.length, 1);
  assertEquals(env.saves[0].p_user_id, USER);
  assertEquals(env.saves[0].p_run_id, env.ledger.runId);
  assertEquals(env.saves[0].p_source, "coach");
  assertEquals((env.saves[0].p_plan as TrainingPlanDoc).sessions.length, 4);

  const completion = env.ledger.completed[0];
  const messages = completion.p_messages as Array<Record<string, unknown>>;
  assertEquals(messages.length, 1);
  assertEquals(messages[0].kind, "training_plan");
  assertEquals(messages[0].notify, false);
  const payload = messages[0].payload as Record<string, unknown>;
  assertEquals(payload.plan_id, PLAN_ID);
  assertEquals(payload.status, "draft");
  assertEquals(payload.sessions_per_week, 4);
  const sessions = payload.sessions as Array<Record<string, unknown>>;
  assertEquals(sessions[0].top_exercises, [
    "Barbell bench press",
    "Barbell row",
    "Dumbbell shoulder press",
  ]);
  assert(String(messages[0].body).startsWith("Built you a four-day"));
});

Deno.test("an invalid draft gets one corrective retry with the validator errors", async () => {
  const env = planSetup();
  const requests: RecordedRequest[] = [];
  const broken = { ...upperLowerPlan(), sessions: [upperLowerPlan().sessions[0]] };
  const result = await draftTrainingPlan(env.admin as never, USER, {
    instructions: null,
    reason: "weekly",
  }, {
    client: fakeClaude([
      jsonTextEvents(planResponse(broken)),
      jsonTextEvents(planResponse()),
    ], requests),
  });
  assertEquals(requests.length, 2);
  assert(promptText(requests[1]).includes("failed validation"));
  assert(promptText(requests[1]).includes("2 to 6 distinct sessions"));
  assertEquals(result.plan.sessions.length, 4);
  assertEquals(env.ledger.claims[0].p_trigger_source, "schedule");
  const message = (env.ledger.completed[0].p_messages as Array<Record<string, unknown>>)[0];
  assertEquals(message.notify, true);
  assert((message.payload as Record<string, unknown>).push_body);
  assertEquals(env.saves[0].p_source, "weekly");
});

Deno.test("off-voice coach copy falls back to a safe template", async () => {
  const env = planSetup();
  const result = await draftTrainingPlan(env.admin as never, USER, {
    instructions: null,
    reason: "user_request",
  }, {
    client: fakeClaude([
      jsonTextEvents(planResponse(upperLowerPlan(), {
        coach_message: "LET'S GO! Beast mode, bro!",
        summary: "See https://example.com for details",
      })),
    ]),
  });
  const message = (env.ledger.completed[0].p_messages as Array<Record<string, unknown>>)[0];
  assertEquals(
    message.body,
    "New plan drafted: Upper/Lower 4x, 4 days a week. Look it over and activate it when it looks right.",
  );
  assertEquals(result.summary, "4 days a week, 4 rotating sessions, about 60 minutes each.");
});

Deno.test("a completed run replays the stored draft without calling the model", async () => {
  const env = planSetup({ claimStatus: "complete", existing: true });
  const requests: RecordedRequest[] = [];
  const result = await draftTrainingPlan(env.admin as never, USER, {
    instructions: null,
    reason: "user_request",
    requestId: "88888888-8888-4888-8888-888888888888",
  }, { client: fakeClaude([jsonTextEvents(planResponse())], requests) });
  assertEquals(requests.length, 0);
  assertEquals(result.planId, PLAN_ID);
  assertEquals(env.ledger.claims[0].p_checkpoint_key, "training_plan:88888888-8888-4888-8888-888888888888");
});

Deno.test("a model failure fails the run and rethrows", async () => {
  const env = planSetup();
  let thrown: unknown = null;
  try {
    await draftTrainingPlan(env.admin as never, USER, {
      instructions: null,
      reason: "first_plan",
    }, { client: fakeClaude([500]) });
  } catch (error) {
    thrown = error;
  }
  assert(thrown instanceof Error);
  assertEquals(env.ledger.failed.length, 1);
  assertEquals(env.saves.length, 0);
});

Deno.test("a stale save never posts the card", async () => {
  const env = planSetup({ saveResult: { status: "stale" } });
  let thrown: unknown = null;
  try {
    await draftTrainingPlan(env.admin as never, USER, {
      instructions: null,
      reason: "first_plan",
    }, { client: fakeClaude([jsonTextEvents(planResponse())]) });
  } catch (error) {
    thrown = error;
  }
  assert(thrown instanceof Error);
  assertEquals(env.ledger.completed.length, 0);
  assertEquals(env.ledger.failed.length, 0);
});

Deno.test("the plan system prompt carries the seed prior and the safety lines", () => {
  assert(TRAINING_PLAN_SYSTEM.includes("Upper A → Lower A → Upper B → Lower B"));
  assert(TRAINING_PLAN_SYSTEM.includes("6–10 rep range"));
  assert(TRAINING_PLAN_SYSTEM.includes("10 minutes of easy morning bike"));
  assert(TRAINING_PLAN_SYSTEM.includes("never give medical advice"));
  assert(TRAINING_PLAN_SYSTEM.includes("Never name or quote real people"));
});
