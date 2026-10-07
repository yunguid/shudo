import { handleCardAction } from "../_shared/coach_cards.ts";
import { parseDigestOutput } from "../_shared/coach_digest.ts";
import { dispatchCoachJob } from "../_shared/coach_dispatch.ts";
import {
  type GoalChangeRequest,
  type GoalProfile,
  planGoalChange,
} from "../_shared/coach_goals.ts";
import {
  addMemoryNote,
  applyNoteOperations,
  parseMemorySections,
  renderMemoryDocument,
} from "../_shared/coach_memory.ts";
import {
  postWeeklyRecapMessage,
  weeklyRecapCopy,
} from "../_shared/coach_recap.ts";
import {
  deviceSnapshotRow,
  handleCoachSync,
  parseCoachSyncRequest,
} from "../_shared/coach_sync.ts";
import { createTextEntry } from "../_shared/entry_capture.ts";
import type { TargetEngineInput } from "../_shared/target_engine.ts";
import { assert, assertEquals } from "./assertions.ts";
import { coachFakeAdmin, type Row } from "./coach_fake_admin.ts";
import { fakeAdmin } from "./fake_rest_admin.ts";

const USER = "11111111-1111-4111-8111-111111111111";

const PROFILE: GoalProfile = {
  goal_type: "maintain",
  target_weight_kg: null,
  goal_date: null,
  daily_macro_target: {
    calories_kcal: 2500,
    protein_g: 140,
    carbs_g: 305,
    fat_g: 69,
  },
  weight_kg: 73.7,
  height_cm: 178,
  activity_level: "moderate",
};

const CONTEXT: TargetEngineInput = {
  goal_type: "maintain",
  height_cm: 178,
  weight_kg: 73.7,
  activity_level: "moderate",
  age_years: 26,
  sex_for_equation: "male",
  training_days_per_week: 4,
  goal_rate_percent_per_week: null,
  protein_bias: "standard",
  fat_bias: "standard",
};

function goalRequest(overrides: Partial<GoalChangeRequest>): GoalChangeRequest {
  return {
    phase: null,
    goal_weight: null,
    goal_date: null,
    weekly_rate_pct: null,
    activity_level: null,
    training_days_per_week: null,
    protein_bias: null,
    fat_bias: null,
    explicit_targets: null,
    reason: "",
    ...overrides,
  };
}

Deno.test("a lean bulk to 175 lb needs confirmation and projects a date", () => {
  const proposal = planGoalChange(
    PROFILE,
    CONTEXT,
    goalRequest({
      phase: "lean_bulk",
      goal_weight: { value: 175, unit: "lb" },
    }),
    { today: "2026-10-06", currentWeightKg: 73.7, changeId: "c1" },
  );
  assertEquals(proposal.status, "needs_confirmation");
  assertEquals(proposal.after.goal_type, "gain");
  assertEquals(proposal.after.target_weight_kg, 79.38);
  assertEquals(proposal.rate_percent_per_week, 0.25);
  assert(proposal.after.calories_kcal > proposal.before.calories_kcal);
  assert(
    proposal.projected_goal_date !== null &&
      proposal.projected_goal_date > "2027-01-01",
  );
  assertEquals(proposal.after.goal_date, proposal.projected_goal_date);
});

Deno.test("a crash-bulk date is capped at the safe pace with a warning", () => {
  const proposal = planGoalChange(
    { ...PROFILE, goal_type: "gain" },
    { ...CONTEXT, goal_type: "gain" },
    goalRequest({
      goal_weight: { value: 185, unit: "lb" },
      goal_date: "2026-11-01",
    }),
    { today: "2026-10-06", currentWeightKg: 73.7, changeId: "c2" },
  );
  assertEquals(proposal.rate_percent_per_week, 0.5);
  assert(
    proposal.warnings.some((warning) => warning.includes("capped at 0.5%")),
  );
  assertEquals(proposal.status, "needs_confirmation");
});

Deno.test("a small explicit protein bump applies straight away", () => {
  const proposal = planGoalChange(
    PROFILE,
    CONTEXT,
    goalRequest({
      explicit_targets: {
        calories_kcal: null,
        protein_g: 160,
        carbs_g: null,
        fat_g: null,
      },
    }),
    { today: "2026-10-06", currentWeightKg: 73.7, changeId: "c3" },
  );
  assertEquals(proposal.status, "applied");
  assertEquals(proposal.after.protein_g, 160);
  assertEquals(proposal.after.goal_type, "maintain");
});

Deno.test("unsafe explicit targets are rejected, never applied", () => {
  const proposal = planGoalChange(
    PROFILE,
    CONTEXT,
    goalRequest({
      explicit_targets: {
        calories_kcal: 900,
        protein_g: null,
        carbs_g: null,
        fat_g: null,
      },
    }),
    { today: "2026-10-06", currentWeightKg: 73.7, changeId: "c4" },
  );
  assertEquals(proposal.status, "rejected");
  assertEquals(proposal.after, proposal.before);
});

Deno.test("goal cards apply, then undo, against the live profile", async () => {
  const before = {
    goal_type: "maintain",
    target_weight_kg: null,
    goal_date: null,
    calories_kcal: 2500,
    protein_g: 140,
    carbs_g: 305,
    fat_g: 69,
  };
  const after = {
    goal_type: "gain",
    target_weight_kg: 79.38,
    goal_date: "2027-05-01",
    calories_kcal: 2800,
    protein_g: 125,
    carbs_g: 382,
    fat_g: 78,
  };
  const card = {
    id: "77777777-7777-4777-8777-777777777777",
    user_id: USER,
    role: "coach",
    kind: "goal_change",
    body: "New goals, ready when you are.",
    payload: {
      change_id: "88888888-8888-4888-8888-888888888888",
      status: "needs_confirmation",
      before,
      after,
      warnings: [],
    },
    local_day: "2026-10-06",
    deliver_at: "2026-10-06T15:00:00Z",
    status: "delivered",
  };
  const fake = coachFakeAdmin({
    tables: {
      coach_messages: [card],
      profiles: [{
        user_id: USER,
        ...PROFILE,
        updated_at: "2026-10-06T14:00:00Z",
      }],
    },
  });
  let refreshed = 0;
  const applied = await handleCardAction(
    fake.admin as never,
    USER,
    {
      kind: "goal_change",
      id: "88888888-8888-4888-8888-888888888888",
      decision: "apply",
    },
    { refreshPlan: () => refreshed++ },
  );
  assertEquals((applied[0].payload as Row).status, "applied");
  const profile = fake.tables.profiles[0];
  assertEquals(profile.goal_type, "gain");
  assertEquals((profile.daily_macro_target as Row).calories_kcal, 2800);
  assertEquals(profile.goal_started_on, "2026-10-06");

  const undone = await handleCardAction(
    fake.admin as never,
    USER,
    { kind: "goal_change", id: card.id, decision: "undo" },
    { refreshPlan: () => refreshed++ },
  );
  assertEquals((undone[0].payload as Row).status, "undone");
  assertEquals(fake.tables.profiles[0].goal_type, "maintain");
  assertEquals(refreshed, 2);
});

Deno.test("log_meal_text creates a durable text entry and hands it to processing", async () => {
  const { admin, rpcCalls } = fakeAdmin({
    tables: { entries: [] },
    unique: { entries: [["user_id", "client_request_id"]] },
    rpc: {
      claim_entry_upload: () => "upload-token",
      publish_entry_upload: () => true,
    },
  });
  const dispatched: string[] = [];
  const created = await createTextEntry(admin as never, USER, {
    clientRequestId: "99999999-9999-4999-8999-999999999999",
    localDay: "2026-10-06",
    timezone: "America/New_York",
    text: "Two eggs and a bagel",
    speechEngine: "apple.speech_transcriber",
  }, (entryId) => dispatched.push(entryId));
  assertEquals(created.status, "queued");
  assertEquals(created.duplicate, false);
  assertEquals(dispatched, [created.entryId]);
  const publish = rpcCalls.find((call) => call.name === "publish_entry_upload");
  assertEquals(publish?.args.p_input_text, "Two eggs and a bagel");
  assertEquals(publish?.args.p_upload_token, "upload-token");
});

Deno.test("a replayed text entry returns the existing meal without republishing", async () => {
  const { admin, rpcCalls } = fakeAdmin({
    tables: {
      entries: [{
        id: "e1",
        user_id: USER,
        client_request_id: "99999999-9999-4999-8999-999999999999",
        status: "complete",
        processing_attempts: 1,
      }],
    },
    unique: { entries: [["user_id", "client_request_id"]] },
  });
  const created = await createTextEntry(admin as never, USER, {
    clientRequestId: "99999999-9999-4999-8999-999999999999",
    localDay: "2026-10-06",
    timezone: "America/New_York",
    text: "Two eggs and a bagel",
  }, () => {
    throw new Error("must not dispatch");
  });
  assertEquals(created, { entryId: "e1", status: "complete", duplicate: true });
  assertEquals(rpcCalls.length, 0);
});

Deno.test("coach job dispatch posts to coach_tick with the secret and never throws", async () => {
  const sent: Array<{ url: string; init: RequestInit }> = [];
  const env = (name: string) =>
    ({
      SUPABASE_URL: "https://project.test/",
      SHUDO_WEEKLY_SECRET: "x".repeat(40),
      SUPABASE_ANON_KEY: "anon",
    })[name];
  const ok = await dispatchCoachJob(
    { job: "plan", user_id: USER, payload: { trigger: "meal_complete" } },
    {
      env,
      fetch: ((url: string, init: RequestInit) => {
        sent.push({ url, init });
        return Promise.resolve(new Response("{}", { status: 202 }));
      }) as typeof fetch,
    },
  );
  assertEquals(ok, true);
  assertEquals(sent[0].url, "https://project.test/functions/v1/coach_tick");
  assertEquals(
    (sent[0].init.headers as Record<string, string>)["x-shudo-weekly-secret"],
    "x".repeat(40),
  );
  assertEquals(JSON.parse(String(sent[0].init.body)), {
    mode: "job",
    job: "plan",
    user_id: USER,
    payload: { trigger: "meal_complete" },
  });
  const failed = await dispatchCoachJob({ mode: "daily" }, {
    env,
    fetch: (() =>
      Promise.resolve(new Response("", { status: 500 }))) as typeof fetch,
  });
  assertEquals(failed, false);
  const unconfigured = await dispatchCoachJob({ mode: "daily" }, {
    env: () => undefined,
  });
  assertEquals(unconfigured, false);
});

Deno.test("memory renders deterministically and keeps notes bounded", () => {
  const sections = parseMemorySections({
    bio: {
      goals: "Lean bulk to 175.",
      about: "Works six days a week.",
      bogus: "x",
    },
    notes: { n_20261001_1: "Likes milk." },
    schedule: {
      wake: "07:00",
      lift_days: ["Mon", "wednesday", "xyz"],
      lift_time: "6pm",
    },
    equipment: ["dumbbells", 3],
  });
  assertEquals(Object.keys(sections.bio), ["about", "goals"]);
  assertEquals(sections.schedule, { wake: "07:00", lift_days: ["mon", "wed"] });
  assertEquals(sections.equipment, ["dumbbells"]);
  const document = renderMemoryDocument(sections);
  assertEquals(document, renderMemoryDocument(parseMemorySections(sections)));
  assert(document.indexOf("## About") < document.indexOf("## Goals"));
  const now = new Date("2026-10-06T12:00:00Z");
  const added = addMemoryNote(sections, "Prefers lifting after work.", now);
  assertEquals(added.key, "n_20261006_1");
  const patched = applyNoteOperations(added.sections, [
    { op: "update", key: "n_20261001_1", text: "Likes whole milk." },
    { op: "remove", key: "n_20261006_1", text: null },
    {
      op: "add",
      key: null,
      text: "Commitment: in bed by 23:00 on weeknights.",
    },
  ], now);
  assertEquals(Object.values(patched.notes), [
    "Likes whole milk.",
    "Commitment: in bed by 23:00 on weeknights.",
  ]);
});

Deno.test("an unsafe digest headline is refused; unsafe list items are dropped", () => {
  const digest = parseDigestOutput({
    headline: "Under-ate again, but trained.",
    summary: "Two meals logged, about 1,600 cal. Probably incomplete.",
    highlights: ["Hit the gym.", "Skip breakfast tomorrow to make up for it."],
    misses: [],
    tomorrow_focus: ["Breakfast before work."],
    score: 140,
    game_plan: {
      theme: "Eat early",
      focus: ["Shake at 3"],
      training: { session_name: "Upper A" },
    },
    memory_ops: [
      { op: "add", key: null, text: "Skips breakfast on Mondays." },
      { op: "nuke", key: null, text: "x" },
    ],
  });
  assertEquals(digest.highlights, ["Hit the gym."]);
  assertEquals(digest.score, 100);
  assertEquals(digest.memory_ops.length, 1);
  let threw = false;
  try {
    parseDigestOutput({ headline: "Starve tomorrow to fix it.", summary: "x" });
  } catch {
    threw = true;
  }
  assert(threw);
});

Deno.test("the weekly recap posts once per week, after quiet hours", async () => {
  const copy = weeklyRecapCopy("2026-09-28", {
    days_logged: 6,
    average_calories_kcal: 2634.4,
    average_protein_g: 151.6,
    target_calories_kcal: 2900,
    target_protein_g: 170,
  });
  // The card carries the numbers; the text says what they mean, and the
  // lock-screen line fits in one glance.
  assertEquals(
    copy.body,
    "Week of Sep 28: 2,630 cal a day, right on the number. Same again. Full recap's on the Body tab.",
  );
  assertEquals(
    copy.push_body,
    "Week of Sep 28: 2,630 cal a day against 2,900.",
  );
  assert(copy.push_body.length <= 90);
  const short = weeklyRecapCopy("2026-09-28", {
    days_logged: 3,
    average_calories_kcal: 2350,
    average_protein_g: 120,
    target_calories_kcal: 2900,
    target_protein_g: 170,
  });
  assertEquals(
    short.body,
    "Week of Sep 28: 2,350 cal a day against 2,900. Closing that gap is the week. Only 3 of 7 days logged, so it's a partial read. Full recap's on the Body tab.",
  );
  const fake = coachFakeAdmin({
    tables: {
      profiles: [{
        user_id: USER,
        coach_enabled: true,
        timezone: "America/New_York",
        coach_profanity: "mild",
        quiet_hours_start: "23:00:00",
        quiet_hours_end: "07:00:00",
      }],
    },
    rpc: {
      post_coach_message: () => ({ status: "created", message_id: "m1" }),
    },
  });
  await postWeeklyRecapMessage(fake.admin as never, {
    userId: USER,
    summaryId: "s1",
    weekStart: "2026-09-28",
    headline: "Steady week",
    metrics: {
      days_logged: 6,
      average_calories_kcal: 2634.4,
      average_protein_g: 151.6,
      target_calories_kcal: 2900,
      target_protein_g: 170,
    },
  }, new Date("2026-10-05T09:17:00Z"));
  const call = fake.rpcCalls[0];
  assertEquals(call.name, "post_coach_message");
  assertEquals(call.args.p_dedupe_key, "weekly:2026-09-28");
  assertEquals(call.args.p_kind, "recap");
  assertEquals(call.args.p_notify, true);
  assertEquals(call.args.p_deliver_at, "2026-10-05T11:00:00.000Z");
  assertEquals(call.args.p_local_day, "2026-10-05");
  assertEquals((call.args.p_payload as Row).summary_id, "s1");
});

Deno.test("coach_sync stores device context without coordinates and plans", async () => {
  const request = parseCoachSyncRequest({
    trigger: "meal_complete",
    local_day: "2026-10-06",
    timezone: "America/New_York",
    entry_id: "22222222-2222-4222-8222-222222222222",
    device: {
      device_id: "ABCDEFAB-1234-4123-8123-ABCDEFABCDEF",
      app_version: "2.0",
      os_version: "26.0",
      notification_status: "authorized",
      location_status: "when_in_use",
    },
    location: {
      captured_at: "2026-10-06T16:00:00Z",
      quality: "approximate",
      locality: {
        city: "New York",
        region: "NY",
        country: "US",
        timezone: "America/New_York",
      },
      stores: [{
        ref: "s1",
        name: "CVS",
        category: "pharmacy",
        distance_m: 240,
        walk_minutes: 3,
        lat: 40.7,
      }],
    },
    wait: true,
  });
  assertEquals(
    request.device?.deviceId,
    "abcdefab-1234-4123-8123-abcdefabcdef",
  );
  const row = deviceSnapshotRow(
    USER,
    request,
    new Date("2026-10-06T16:01:00Z"),
  )!;
  assertEquals(row.city, "New York");
  assertEquals(row.country_code, "US");
  assertEquals("lat" in (row.nearby as Row[])[0], false);
  assertEquals("coarse_latitude" in row, false);

  const fake = coachFakeAdmin({ tables: { device_snapshots: [] } });
  const planned: Row[] = [];
  const result = await handleCoachSync(fake.admin as never, USER, request, {
    observe: () => undefined,
    runPlan: (_admin, planRequest) => {
      planned.push(planRequest as unknown as Row);
      return Promise.resolve({
        status: "complete",
        runId: "run-1",
        generated: true,
        messageIds: ["m"],
      });
    },
  });
  assertEquals(result.plan_run_id, "run-1");
  assertEquals(result.generated, true);
  assertEquals(planned[0].trigger, "meal_complete");
  assertEquals(planned[0].entryId, "22222222-2222-4222-8222-222222222222");
  assertEquals(planned[0].foreground, true);
  assertEquals(fake.tables.device_snapshots.length, 1);
});
