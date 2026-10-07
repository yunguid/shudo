import {
  ACTIVITY_FAILED_MESSAGE,
  activityImagePath,
  analyzeStoredActivity,
  createActivityFromText,
  detectPersonalRecords,
  epleyE1rm,
  insertProcessingActivity,
  type LoggedExercise,
  parseActivityAnalysis,
  parseActivityOccurredAt,
  parsePlanSessionId,
  parseSetDictation,
} from "../_shared/activity_analysis.ts";
import type { CoachJob } from "../_shared/coach_dispatch.ts";
import { HttpError } from "../_shared/errors.ts";
import { assert, assertEquals } from "./assertions.ts";
import {
  fakeClaude,
  jsonTextEvents,
  messageEnd,
  messageStart,
  promptText,
  type RecordedRequest,
} from "./fake_claude.ts";
import { fakeAdmin, fakeLedger, type Row } from "./fake_rest_admin.ts";

const USER = "11111111-1111-4111-8111-111111111111";
const ACTIVITY = "22222222-2222-4222-8222-222222222222";
const REQUEST = "33333333-3333-4333-8333-333333333333";

// ---------------------------------------------------------------------------
// Deterministic dictation parsing
// ---------------------------------------------------------------------------

Deno.test("dictation: 'bench 185 for 3 sets of 8, last set 7' becomes three sets", () => {
  const parsed = parseSetDictation(
    "Bench 185 for 3 sets of 8, last set 7; incline 60s 3x10",
    "lb",
  );
  assertEquals(parsed.length, 2);
  assertEquals(parsed[0].key, "barbell_bench_press");
  assertEquals(parsed[0].sets, [
    { reps: 8, weight: 185, unit: "lb" },
    { reps: 8, weight: 185, unit: "lb" },
    { reps: 7, weight: 185, unit: "lb" },
  ]);
  // "60s" on an incline means dumbbells, 60 each.
  assertEquals(parsed[1].key, "incline_dumbbell_press");
  assertEquals(parsed[1].sets.length, 3);
  assertEquals(parsed[1].sets[0], { reps: 10, weight: 60, unit: "lb" });
});

Deno.test("dictation: common shorthand forms", () => {
  const squat = parseSetDictation("squat 225x5x3", "lb")[0];
  assertEquals(squat.key, "back_squat");
  assertEquals(squat.sets.map((set) => [set.weight, set.reps]), [
    [225, 5],
    [225, 5],
    [225, 5],
  ]);

  const pullUps = parseSetDictation("pull-ups 3x10", "lb")[0];
  assertEquals(pullUps.key, "pull_up");
  assertEquals(pullUps.sets.every((set) => set.weight === 0), true);

  const deadlift = parseSetDictation("deadlift 315 for 5", "lb")[0];
  assertEquals(deadlift.sets, [{ reps: 5, weight: 315, unit: "lb" }]);

  const rows = parseSetDictation("barbell rows 135 for 10, 10, 8", "lb")[0];
  assertEquals(rows.key, "barbell_row");
  assertEquals(rows.sets.map((set) => set.reps), [10, 10, 8]);

  const metric = parseSetDictation("bench 100 kg 5x5", "lb")[0];
  assertEquals(metric.sets.length, 5);
  assertEquals(metric.sets[0], { reps: 5, weight: 100, unit: "kg" });

  const reordered = parseSetDictation("3x8 bench at 185", "lb")[0];
  assertEquals(reordered.key, "barbell_bench_press");
  assertEquals(reordered.sets.length, 3);
  assertEquals(reordered.sets[0].weight, 185);

  const weightedDips = parseSetDictation("dips +45 3x8", "lb")[0];
  assertEquals(weightedDips.key, "dip");
  assertEquals(weightedDips.sets[0].weight, 45);
});

Deno.test("dictation skips cardio and text it does not understand", () => {
  assertEquals(parseSetDictation("10 min bike then 3 eggs and rice", "lb"), []);
  assertEquals(parseSetDictation("felt great today", "lb"), []);
  assertEquals(parseSetDictation("ran 3 miles in 27 minutes", "lb"), []);
});

// ---------------------------------------------------------------------------
// Output parsing
// ---------------------------------------------------------------------------

function strengthOutput(overrides: Record<string, unknown> = {}) {
  return {
    analysis_preview:
      "Upper session: bench and incline dumbbell press, about 55 minutes.",
    title: "Upper: bench, incline",
    kind: "strength",
    intensity: "hard",
    met_code: null,
    duration_min: 55,
    distance_km: null,
    avg_heart_rate: null,
    rpe: 8,
    device_active_kcal: null,
    device_total_kcal: null,
    device_label: null,
    exercises: [
      {
        display_name: "Bench press",
        exercise_key: "barbell_bench_press",
        set_groups: [
          {
            count: 1,
            reps: 10,
            weight: 95,
            unit: null,
            is_warmup: true,
            rpe: null,
          },
          {
            count: 2,
            reps: 8,
            weight: 185,
            unit: null,
            is_warmup: false,
            rpe: null,
          },
          {
            count: 1,
            reps: 7,
            weight: 185,
            unit: null,
            is_warmup: false,
            rpe: 9,
          },
        ],
      },
      {
        display_name: "Incline dumbbell press",
        exercise_key: "incline_dumbbell_press",
        set_groups: [
          {
            count: 3,
            reps: 10,
            weight: 60,
            unit: "lb",
            is_warmup: false,
            rpe: null,
          },
        ],
      },
    ],
    plan_session_id: null,
    confidence: 0.85,
    notes: null,
    ...overrides,
  };
}

Deno.test("set groups expand into individual sets with the default unit", () => {
  const parsed = parseActivityAnalysis(strengthOutput(), { unit: "lb" });
  assertEquals(parsed.kind, "strength");
  assertEquals(parsed.exercises[0].load_type, "barbell");
  assertEquals(parsed.exercises[0].sets, [
    { reps: 10, weight: 95, unit: "lb", is_warmup: true },
    { reps: 8, weight: 185, unit: "lb" },
    { reps: 8, weight: 185, unit: "lb" },
    { reps: 7, weight: 185, unit: "lb", rpe: 9 },
  ]);
  assertEquals(parsed.exercises[1].sets.length, 3);
  assertEquals(parsed.durationMin, 55);
});

Deno.test("parsing rejects personified copy and clamps implausible numbers", () => {
  const parsed = parseActivityAnalysis(
    strengthOutput({
      title: "Shudo thinks this was a great push day",
      analysis_preview: "I think you crushed it.",
      avg_heart_rate: 400,
      duration_min: -5,
      kind: "underwater_basket_weaving",
      exercises: [{
        display_name: "Zercher carry",
        exercise_key: "custom",
        set_groups: [{
          count: 99,
          reps: 5,
          weight: 9999,
          unit: "lb",
          is_warmup: false,
          rpe: null,
        }],
      }],
    }),
    { unit: "kg" },
  );
  assertEquals(parsed.title, "Workout");
  assertEquals(parsed.analysisPreview, null);
  assertEquals(parsed.avgHeartRate, null);
  assertEquals(parsed.durationMin, null);
  assertEquals(parsed.kind, "other");
  assertEquals(parsed.exercises[0].key, "custom:zercher_carry");
  assertEquals(parsed.exercises[0].sets.length, 30);
  assertEquals(parsed.exercises[0].sets[0].weight, 0);
});

// ---------------------------------------------------------------------------
// Personal records
// ---------------------------------------------------------------------------

function bench(
  sets: Array<[number, number]>,
  unit: "lb" | "kg" = "lb",
): LoggedExercise {
  return {
    name: "Barbell bench press",
    key: "barbell_bench_press",
    sets: sets.map(([weight, reps]) => ({ weight, reps, unit })),
  };
}

Deno.test("Epley e1RM only for 1-12 reps with load", () => {
  assertEquals(Math.round(epleyE1rm(185, 8)! * 100) / 100, 234.33);
  assertEquals(epleyE1rm(225, 1), 225);
  assertEquals(epleyE1rm(100, 13), null);
  assertEquals(epleyE1rm(0, 8), null);
});

Deno.test("a first-ever lift is a baseline, not a PR", () => {
  assertEquals(detectPersonalRecords([bench([[185, 8]])], []), []);
});

Deno.test("heavier weight at the same reps is a weight PR and an e1RM PR", () => {
  const prs = detectPersonalRecords(
    [bench([[190, 8], [190, 8], [185, 8]])],
    [[bench([[185, 8], [185, 8], [185, 7]])]],
  );
  assertEquals(prs.map((pr) => pr.kind), ["e1rm", "weight"]);
  assertEquals(prs[1], {
    exercise: "Barbell bench press",
    key: "barbell_bench_press",
    kind: "weight",
    value: 190,
    unit: "lb",
    weight: 190,
    reps: 8,
    previous: 185,
  });
  assertEquals(prs[0].value, 240.7);
  assertEquals(prs[0].previous, 234.3);
});

Deno.test("more reps at the same weight is a reps PR", () => {
  const prs = detectPersonalRecords(
    [bench([[185, 9]])],
    [[bench([[185, 8]])], [bench([[175, 8]])]],
  );
  const reps = prs.find((pr) => pr.kind === "reps");
  assertEquals(reps?.value, 9);
  assertEquals(reps?.previous, 8);
  assertEquals(prs.some((pr) => pr.kind === "weight"), false);
});

Deno.test("matching a previous best, warm-ups, and high-rep sets set no PRs", () => {
  assertEquals(
    detectPersonalRecords([bench([[185, 8]])], [[bench([[185, 8]])]]),
    [],
  );
  const warmup: LoggedExercise = {
    ...bench([]),
    sets: [{ weight: 225, reps: 3, unit: "lb", is_warmup: true }, {
      weight: 185,
      reps: 8,
      unit: "lb",
    }],
  };
  assertEquals(detectPersonalRecords([warmup], [[bench([[185, 8]])]]), []);
  // 14 reps is past the e1RM window and below the prior rep best.
  assertEquals(
    detectPersonalRecords([bench([[100, 14]])], [[bench([[100, 15]])]]),
    [],
  );
});

Deno.test("PRs compare across units and report in the current set's unit", () => {
  const prs = detectPersonalRecords(
    [bench([[225, 5]])],
    [[bench([[100, 5]], "kg")]],
  );
  const weight = prs.find((pr) => pr.kind === "weight");
  assertEquals(weight?.unit, "lb");
  assertEquals(weight?.previous, 220.5);
});

Deno.test("bodyweight lifts only earn reps PRs", () => {
  const pullUps = (reps: number): LoggedExercise => ({
    name: "Pull-up",
    key: "pull_up",
    sets: [{ weight: 0, reps, unit: "lb" }],
  });
  const prs = detectPersonalRecords([pullUps(12)], [[pullUps(10)]]);
  assertEquals(prs.map((pr) => [pr.kind, pr.value, pr.previous]), [[
    "reps",
    12,
    10,
  ]]);
});

// ---------------------------------------------------------------------------
// Capture helpers
// ---------------------------------------------------------------------------

Deno.test("log_activity field helpers validate and build owned paths", () => {
  assertEquals(
    activityImagePath(USER.toUpperCase(), "2026-10-06", REQUEST),
    `${USER}/2026-10-06/activity-${REQUEST}.jpg`,
  );
  const now = Date.parse("2026-10-06T22:30:00Z");
  assertEquals(
    parseActivityOccurredAt("2026-10-06T18:15:00-04:00", now),
    "2026-10-06T22:15:00.000Z",
  );
  assertEquals(parseActivityOccurredAt("", now), null);
  let status = 0;
  try {
    parseActivityOccurredAt("2025-01-01T00:00:00Z", now);
  } catch (error) {
    status = (error as HttpError).status;
  }
  assertEquals(status, 400);
  assertEquals(parsePlanSessionId("upper_a"), "upper_a");
  assertEquals(parsePlanSessionId(""), null);
  try {
    parsePlanSessionId("Upper A; drop table");
    throw new Error("expected rejection");
  } catch (error) {
    assert(error instanceof HttpError);
  }
});

function activityRow(overrides: Row = {}): Row {
  return {
    id: ACTIVITY,
    user_id: USER,
    client_request_id: REQUEST,
    local_day: "2026-10-06",
    occurred_at: "2026-10-06T22:15:00.000Z",
    status: "processing",
    source: "voice",
    kind: "other",
    title: "Workout",
    input_text: "bench 185 for 3 sets of 8, last set 7; incline 60s 3x10",
    transcript: null,
    image_path: null,
    speech_engine: "apple.speech_transcriber",
    details: {},
    ...overrides,
  };
}

function priorBenchSession(): Row {
  return activityRow({
    id: "44444444-4444-4444-8444-444444444444",
    client_request_id: "55555555-5555-4555-8555-555555555555",
    local_day: "2026-10-02",
    occurred_at: "2026-10-02T22:00:00.000Z",
    status: "complete",
    details: {
      exercises: [{
        name: "Barbell bench press",
        key: "barbell_bench_press",
        sets: [
          { reps: 8, weight: 180, unit: "lb" },
          { reps: 8, weight: 180, unit: "lb" },
          { reps: 8, weight: 180, unit: "lb" },
        ],
      }],
    },
  });
}

function setup(
  options: {
    activity?: Row;
    claimStatus?: string;
    saveResult?: string;
    extraActivities?: Row[];
  } = {},
) {
  const ledger = fakeLedger({ claimStatus: options.claimStatus });
  const saved: Array<Record<string, unknown>> = [];
  const fake = fakeAdmin({
    tables: {
      activities: [
        options.activity ?? activityRow(),
        priorBenchSession(),
        ...(options.extraActivities ?? []),
      ],
      profiles: [{
        user_id: USER,
        units: "imperial",
        weight_kg: 73.7,
        height_cm: 178,
      }],
      weight_checkins: [],
      training_plans: [],
    },
    unique: { activities: [["user_id", "client_request_id"]] },
    rpc: {
      ...ledger.handlers,
      save_activity_analysis(args) {
        saved.push(args);
        return options.saveResult ?? "saved";
      },
    },
  });
  return { ...fake, ledger, saved };
}

Deno.test("analysis saves parsed sets, MET burn, PRs, then asks the coach to react", async () => {
  const env = setup();
  const requests: RecordedRequest[] = [];
  const dispatched: CoachJob[] = [];
  await analyzeStoredActivity(env.admin as never, USER, ACTIVITY, {
    client: fakeClaude([jsonTextEvents(strengthOutput())], requests),
    dispatch: (job) => {
      dispatched.push(job);
      return Promise.resolve();
    },
  });

  assertEquals(requests.length, 1);
  assertEquals(requests[0].model, "claude-sonnet-5-5");
  assertEquals(
    (requests[0].output_config as { effort?: string }).effort,
    "low",
  );
  assert(requests[0].output_config?.format, "structured output format is set");
  assertEquals(requests[0].tools, undefined);
  const prompt = promptText(requests[0]);
  assert(prompt.includes("Preferred weight unit: lb"));
  assert(prompt.includes("pre-parsed"));
  assert(prompt.includes("185lbx8"));
  assert(prompt.includes("analysis_preview first"));

  const claim = env.ledger.claims[0];
  assertEquals(claim.p_operation, "activity_analysis");
  assertEquals(claim.p_checkpoint_key, `activity:${ACTIVITY}`);
  assertEquals(claim.p_local_day, "2026-10-06");

  assertEquals(env.saved.length, 1);
  const analysis = env.saved[0].p_analysis as Record<string, unknown>;
  assertEquals(env.saved[0].p_activity_id, ACTIVITY);
  assertEquals(env.saved[0].p_claim_token, env.ledger.claimToken);
  assertEquals(analysis.kind, "strength");
  assertEquals(analysis.title, "Upper: bench, incline");
  assertEquals(analysis.intensity, "hard");
  // (6 − 1) × 73.7 kg × 55/60 h = 337.8 → 338, from the profile weight.
  assertEquals(analysis.active_kcal, 338);
  const details = analysis.details as Record<string, unknown>;
  assertEquals(details.burn_method, "met");
  assertEquals(details.weight_source, "profile");
  assertEquals(details.weight_kg_used, 73.7);
  assertEquals(env.ledger.usage.length, 1);
  assertEquals(env.ledger.usage[0].p_operation, "activity_analysis");
  assertEquals(env.ledger.usage[0].p_run_id, env.ledger.runId);
  assertEquals(env.ledger.usage[0].p_user_id, USER);
  const exercises = details.exercises as LoggedExercise[];
  assertEquals(exercises[0].sets.length, 4);
  const prs = details.prs as Array<Record<string, unknown>>;
  const weightPr = prs.find((pr) => pr.kind === "weight");
  assertEquals(weightPr?.value, 185);
  assertEquals(weightPr?.previous, 180);

  assertEquals(env.ledger.completed.length, 1);
  assertEquals(env.ledger.completed[0].p_status, "complete");
  assertEquals(env.ledger.completed[0].p_messages, []);
  assertEquals(dispatched, [{
    job: "plan",
    user_id: USER,
    payload: { trigger: "activity_complete", activity_id: ACTIVITY },
  }]);
});

Deno.test("streamed analysis_preview is published into details while processing", async () => {
  const env = setup();
  await analyzeStoredActivity(env.admin as never, USER, ACTIVITY, {
    client: fakeClaude([jsonTextEvents(strengthOutput(), { chunks: 6 })]),
    dispatch: () => Promise.resolve(),
  });
  const previewWrite = env.mutations.find((mutation) =>
    mutation.operation === "update" &&
    (mutation.values?.details as Record<string, unknown> | undefined)
      ?.analysis_preview
  );
  assert(previewWrite, "a preview update was written");
});

Deno.test("photo workouts send the signed coach-media image to the model", async () => {
  const env = setup({
    activity: activityRow({
      input_text: null,
      source: "photo",
      image_path: `${USER}/2026-10-06/activity-${REQUEST}.jpg`,
    }),
  });
  const requests: RecordedRequest[] = [];
  await analyzeStoredActivity(env.admin as never, USER, ACTIVITY, {
    client: fakeClaude([
      jsonTextEvents(strengthOutput({
        kind: "run",
        exercises: [],
        duration_min: 30,
        device_active_kcal: 310,
        device_label: "apple_watch",
      })),
    ], requests),
    dispatch: () => Promise.resolve(),
  });
  const content = requests[0].messages?.[0].content as Array<
    Record<string, unknown>
  >;
  assertEquals(content[0].type, "image");
  assertEquals(
    (content[0].source as Record<string, unknown>).url,
    `https://storage.test/coach-media/${USER}/2026-10-06/activity-${REQUEST}.jpg?token=t`,
  );
  const analysis = env.saved[0].p_analysis as Record<string, unknown>;
  assertEquals(analysis.active_kcal, 310);
  assertEquals(
    (analysis.details as Record<string, unknown>).burn_method,
    "device",
  );
});

Deno.test("the deterministic parser fills in when the model returns no sets", async () => {
  const env = setup();
  await analyzeStoredActivity(env.admin as never, USER, ACTIVITY, {
    client: fakeClaude([
      jsonTextEvents(strengthOutput({ exercises: [], duration_min: null })),
    ]),
    dispatch: () => Promise.resolve(),
  });
  const details = (env.saved[0].p_analysis as Record<string, unknown>)
    .details as Record<string, unknown>;
  const exercises = details.exercises as LoggedExercise[];
  assertEquals(exercises.map((exercise) => exercise.key), [
    "barbell_bench_press",
    "incline_dumbbell_press",
  ]);
  assertEquals(exercises[0].sets.map((set) => set.reps), [8, 8, 7]);
  // 6 working sets × 2.5 min, minimum 10 → 15 min estimated.
  assertEquals(details.duration_estimated, true);
  assertEquals(details.duration_min_estimated, 15);
});

Deno.test("an unclaimed run never calls the model", async () => {
  const env = setup({ claimStatus: "running" });
  const requests: RecordedRequest[] = [];
  await analyzeStoredActivity(env.admin as never, USER, ACTIVITY, {
    client: fakeClaude([jsonTextEvents(strengthOutput())], requests),
    dispatch: () => Promise.resolve(),
  });
  assertEquals(requests.length, 0);
  assertEquals(env.saved.length, 0);
});

Deno.test("an exhausted run marks the workout failed", async () => {
  const env = setup({ claimStatus: "exhausted" });
  await analyzeStoredActivity(env.admin as never, USER, ACTIVITY, {
    dispatch: () => Promise.resolve(),
  });
  const row = env.tables.activities.find((activity) =>
    activity.id === ACTIVITY
  )!;
  assertEquals(row.status, "failed");
  assertEquals(row.error_message, ACTIVITY_FAILED_MESSAGE);
});

Deno.test("a refusal fails the run and the workout with a friendly message", async () => {
  const env = setup();
  const dispatched: CoachJob[] = [];
  await analyzeStoredActivity(env.admin as never, USER, ACTIVITY, {
    client: fakeClaude([[messageStart(), ...messageEnd("refusal")]]),
    dispatch: (job) => {
      dispatched.push(job);
      return Promise.resolve();
    },
  });
  assertEquals(env.ledger.failed.length, 1);
  // Refusals repeat on retry, so the run is terminal.
  assertEquals(env.ledger.failed[0].p_retryable, false);
  assertEquals(env.saved.length, 0);
  assertEquals(dispatched.length, 0);
  const row = env.tables.activities.find((activity) =>
    activity.id === ACTIVITY
  )!;
  assertEquals(row.status, "failed");
  assertEquals(row.error_message, ACTIVITY_FAILED_MESSAGE);
});

Deno.test("a transient model error stays retryable; a budget stop says so", async () => {
  const env = setup();
  await analyzeStoredActivity(env.admin as never, USER, ACTIVITY, {
    client: fakeClaude([503]),
    dispatch: () => Promise.resolve(),
  });
  assertEquals(env.ledger.failed[0].p_retryable, true);
  const row = env.tables.activities.find((activity) =>
    activity.id === ACTIVITY
  )!;
  assertEquals(row.status, "failed");

  const budget = setup({ claimStatus: "quota" });
  const requests: RecordedRequest[] = [];
  await analyzeStoredActivity(budget.admin as never, USER, ACTIVITY, {
    client: fakeClaude([jsonTextEvents(strengthOutput())], requests),
    dispatch: () => Promise.resolve(),
  });
  assertEquals(requests.length, 0);
  const blocked = budget.tables.activities.find((activity) =>
    activity.id === ACTIVITY
  )!;
  assertEquals(blocked.status, "failed");
  assert(String(blocked.error_message).includes("AI limit"));
});

Deno.test("a stale fence stops without failing the workout", async () => {
  const env = setup({ saveResult: "stale" });
  await analyzeStoredActivity(env.admin as never, USER, ACTIVITY, {
    client: fakeClaude([jsonTextEvents(strengthOutput())]),
    dispatch: () => Promise.resolve(),
  });
  assertEquals(env.ledger.completed.length, 0);
  assertEquals(env.ledger.failed.length, 0);
  const row = env.tables.activities.find((activity) =>
    activity.id === ACTIVITY
  )!;
  assertEquals(row.status, "processing");
});

// ---------------------------------------------------------------------------
// createActivityFromText / insert idempotency
// ---------------------------------------------------------------------------

Deno.test("createActivityFromText inserts a processing row and starts analysis", async () => {
  const fake = fakeAdmin({
    tables: { activities: [] },
    unique: { activities: [["user_id", "client_request_id"]] },
    // Another worker owns the run, so the background analysis exits cleanly.
    rpc: fakeLedger({ claimStatus: "running" }).handlers,
  });
  const scheduled: Array<Promise<unknown>> = [];
  const result = await createActivityFromText(fake.admin as never, USER, {
    clientRequestId: REQUEST.toUpperCase(),
    localDay: "2026-10-06",
    timezone: "America/New_York",
    text: "  10 min bike, easy  ",
    source: "coach_chat",
    sourceMessageId: "66666666-6666-4666-8666-666666666666",
  }, {
    background: (promise) => scheduled.push(promise.catch(() => undefined)),
  });
  assertEquals(result.duplicate, false);
  assertEquals(scheduled.length, 1);
  await Promise.all(scheduled);
  const row = fake.tables.activities[0];
  assertEquals(row.id, result.activityId);
  assertEquals(row.status, "processing");
  assertEquals(row.source, "coach_chat");
  assertEquals(row.client_request_id, REQUEST);
  assertEquals(row.input_text, "10 min bike, easy");
  assertEquals(row.title, "Workout");
  assertEquals(row.source_message_id, "66666666-6666-4666-8666-666666666666");
  assertEquals(row.speech_engine, null);
});

Deno.test("the phone's speech engine is stored on its own column", async () => {
  const fake = fakeAdmin({ tables: { activities: [] } });
  await insertProcessingActivity(fake.admin as never, USER, {
    clientRequestId: REQUEST,
    localDay: "2026-10-06",
    timezone: "America/New_York",
    text: "bench 185 for 3 sets of 8",
    source: "voice",
    speechEngine: "apple.speech_transcriber",
    planSessionId: "upper_a",
  });
  const row = fake.tables.activities[0];
  assertEquals(row.speech_engine, "apple.speech_transcriber");
  assertEquals(row.details, { plan_session_id: "upper_a" });
});

Deno.test("a replayed request is a duplicate; a failed one is re-armed", async () => {
  const complete = fakeAdmin({
    tables: { activities: [activityRow({ status: "complete" })] },
  });
  const scheduled: Array<Promise<unknown>> = [];
  const replay = await createActivityFromText(complete.admin as never, USER, {
    clientRequestId: REQUEST,
    localDay: "2026-10-06",
    timezone: "America/New_York",
    text: "bench",
    source: "coach_chat",
  }, { background: (promise) => scheduled.push(promise) });
  assertEquals(replay, { activityId: ACTIVITY, duplicate: true });
  assertEquals(scheduled.length, 0);
  assertEquals(complete.mutations.length, 0);

  const failed = fakeAdmin({
    tables: {
      activities: [activityRow({ status: "failed", error_message: "x" })],
    },
  });
  const prepared = await insertProcessingActivity(failed.admin as never, USER, {
    clientRequestId: REQUEST,
    localDay: "2026-10-06",
    timezone: "America/New_York",
    text: "bench",
    source: "text",
  });
  assertEquals(prepared, {
    activityId: ACTIVITY,
    status: "processing",
    duplicate: true,
    analyze: true,
  });
  assertEquals(failed.tables.activities[0].status, "processing");
  assertEquals(failed.tables.activities[0].error_message, null);
});

Deno.test("capture quotas surface as 429s and oversize text as 413", async () => {
  const fake = fakeAdmin({
    tables: { activities: [] },
    insertErrors: {
      activities: { message: "activity_daily_quota_exceeded", code: "P0001" },
    },
  });
  let status = 0;
  try {
    await insertProcessingActivity(fake.admin as never, USER, {
      clientRequestId: REQUEST,
      localDay: "2026-10-06",
      timezone: "America/New_York",
      text: "bench",
      source: "text",
    });
  } catch (error) {
    status = (error as HttpError).status;
  }
  assertEquals(status, 429);

  status = 0;
  try {
    await createActivityFromText(fake.admin as never, USER, {
      clientRequestId: REQUEST,
      localDay: "2026-10-06",
      timezone: "America/New_York",
      text: "x".repeat(4_001),
      source: "voice",
    });
  } catch (error) {
    status = (error as HttpError).status;
  }
  assertEquals(status, 413);
});
