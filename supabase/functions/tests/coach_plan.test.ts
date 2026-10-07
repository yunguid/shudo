import { COACH_PERSONA_PROMPT } from "../_shared/coach_persona.ts";
import { SLOT_KEYS } from "../_shared/coach_policy.ts";
import { runCoachPlan } from "../_shared/coach_plan.ts";
import { assert, assertEquals } from "./assertions.ts";
import {
  coachFakeAdmin,
  installCoachLedger,
  type Row,
} from "./coach_fake_admin.ts";
import {
  fakeClaude,
  jsonTextEvents,
  messageEnd,
  messageStart,
  promptText,
  type RecordedRequest,
} from "./fake_claude.ts";

const USER = "11111111-1111-4111-8111-111111111111";
const MEAL = "22222222-2222-4222-8222-222222222222";
const NOW = new Date("2026-10-05T16:40:00Z"); // Monday 12:40 in New York

function fixtures(overrides: { profile?: Row } = {}): Record<string, Row[]> {
  return {
    profiles: [{
      user_id: USER,
      display_name: "Luke",
      timezone: "America/New_York",
      units: "imperial",
      goal_type: "gain",
      goal_notes: null,
      daily_macro_target: {
        calories_kcal: 2900,
        protein_g: 170,
        carbs_g: 380,
        fat_g: 80,
      },
      weight_kg: 73.7,
      target_weight_kg: 79.4,
      height_cm: 178,
      activity_level: "moderate",
      goal_date: null,
      goal_started_on: null,
      goal_start_weight_kg: 73.7,
      coach_enabled: true,
      coach_intensity: "locked_in",
      coach_profanity: "mild",
      quiet_hours_start: "23:00:00",
      quiet_hours_end: "07:00:00",
      location_recs_enabled: false,
      physique_ai_review_enabled: false,
      ...overrides.profile,
    }],
    coach_memory: [{
      user_id: USER,
      version: 3,
      document: "# Bio (his own words)\n## About\nWorks six days a week.",
      sections: {
        bio: { about: "Works six days a week." },
        notes: {},
        schedule: {
          wake: "07:00",
          office_start: "09:30",
          office_days: ["mon", "tue", "wed", "thu", "fri", "sat"],
          lift_days: ["mon", "wed", "fri", "sat"],
          lift_time: "18:15",
          bed: "23:30",
          target_bed: "23:00",
        },
        equipment: [],
      },
    }],
    entries: [
      {
        id: "33333333-3333-4333-8333-333333333333",
        user_id: USER,
        local_day: "2026-10-05",
        occurred_at: "2026-10-05T12:30:00Z",
        created_at: "2026-10-05T12:30:00Z",
        updated_at: "2026-10-05T12:31:00Z",
        title: "Eggs and rice",
        status: "complete",
        calories_kcal: 640,
        protein_g: 38,
        carbs_g: 70,
        fat_g: 22,
      },
      {
        id: MEAL,
        user_id: USER,
        local_day: "2026-10-05",
        occurred_at: "2026-10-05T16:00:00Z",
        created_at: "2026-10-05T16:00:00Z",
        updated_at: "2026-10-05T16:01:00Z",
        title: "Chicken burrito",
        status: "complete",
        calories_kcal: 1000,
        protein_g: 55,
        carbs_g: 110,
        fat_g: 30,
      },
    ],
    coach_messages: [],
  };
}

const GOOD_PLAN = {
  reaction: {
    kind: "meal_ack",
    body:
      "Burrito's in. 1,260 cal and 77g protein left today. A shake at 3 closes most of it.",
    push_body:
      "Burrito's in. 1,260 cal and 77g protein left. A shake at 3 closes most of it.",
  },
  slots: [
    {
      slot_key: "lunch",
      deliver_local: "13:00",
      day: "today",
      skip: false,
      kind: "checkpoint",
      body: "4,200 cal by dinner, easy.",
      push_body: "4,200 cal by dinner, easy.",
    },
    {
      slot_key: "afternoon",
      deliver_local: "15:30",
      day: "today",
      skip: false,
      kind: "checkpoint",
      body:
        "77g protein to go. Greek yogurt and a shake before you leave work.",
      push_body: null,
    },
    {
      slot_key: "training",
      deliver_local: "18:00",
      day: "today",
      skip: false,
      kind: "checkpoint",
      body: "Lift day. Eat an hour out, then go move some weight.",
      push_body: "Lift day. Eat an hour out, then go move some weight.",
    },
    {
      slot_key: "dinner",
      deliver_local: "19:45",
      day: "today",
      skip: true,
      kind: "checkpoint",
      body: "",
      push_body: null,
    },
    {
      slot_key: "wind_down",
      deliver_local: "22:30",
      day: "today",
      skip: false,
      kind: "recap",
      body: "Kitchen's closing. Milk if you're short, then bed by 11.",
      push_body: "Kitchen's closing. Milk if you're short, then bed by 11.",
    },
  ],
  day_theme: "Eat early, lift heavy",
  memory_note: "Likes burritos for lunch on workdays.",
};

const REPAIR = {
  reaction: null,
  slots: [{
    slot_key: "lunch",
    deliver_local: "13:00",
    day: "today",
    skip: false,
    kind: "checkpoint",
    body: "Make lunch the big one today. Rice and a real protein.",
    push_body: "Make lunch the big one today. Rice and a real protein.",
  }],
  day_theme: null,
  memory_note: null,
};

Deno.test("a finished meal yields one reaction plus copy for every remaining slot", async () => {
  const fake = coachFakeAdmin({ tables: fixtures() });
  const ledger = installCoachLedger(fake, { userId: USER });
  const requests: RecordedRequest[] = [];
  const client = fakeClaude(
    [jsonTextEvents(GOOD_PLAN), jsonTextEvents(REPAIR)],
    requests,
  );

  const outcome = await runCoachPlan(
    fake.admin as never,
    { userId: USER, trigger: "meal_complete", entryId: MEAL },
    { client, now: () => NOW },
  );

  assertEquals(outcome.status, "complete");
  assertEquals(outcome.generated, true);
  assertEquals(ledger.claims.length, 1);
  const claim = ledger.claims[0];
  assertEquals(claim.p_operation, "coach_checkpoint");
  assertEquals(claim.p_local_day, "2026-10-05");
  assert(String(claim.p_checkpoint_key).startsWith("plan:"));

  // One plan call, one repair for the slot that cited an unknown figure.
  assertEquals(requests.length, 2);
  assertEquals(requests[0].model, "claude-sonnet-5-5");
  assertEquals(
    (requests[0].output_config as { effort?: string }).effort,
    "low",
  );
  assert(promptText(requests[0]).includes(COACH_PERSONA_PROMPT.slice(0, 60)));
  assert(promptText(requests[0]).includes("<context_pack>"));
  assert(promptText(requests[1]).includes("unverified_figure"));

  const completion = ledger.completions[0];
  assertEquals(completion.p_status, "complete");
  assertEquals(completion.p_supersede_slot_keys, [...SLOT_KEYS]);
  const messages = completion.p_messages as Row[];
  assertEquals(messages.map((message) => message.kind), [
    "meal_ack",
    "checkpoint",
    "checkpoint",
    "checkpoint",
    "recap",
  ]);
  const reaction = messages[0];
  assertEquals(reaction.entry_id, MEAL);
  assertEquals(reaction.notify, true);
  assertEquals((reaction.payload as Row).entry_id, MEAL);
  assert(typeof (reaction.payload as Row).push_body === "string");

  const lunch = messages[1];
  assertEquals(lunch.slot_key, "lunch");
  assertEquals(
    lunch.body,
    "Make lunch the big one today. Rice and a real protein.",
  );
  assertEquals(lunch.deliver_at, "2026-10-05T17:00:00.000Z");
  assertEquals(lunch.local_day, "2026-10-05");
  // A slot written without push_body falls back to its single bubble.
  assertEquals((messages[2].payload as Row).push_body, messages[2].body);
  // A skipped slot is simply absent; the recap carries the scorecard.
  assertEquals(
    messages.some((message) => message.slot_key === "dinner"),
    false,
  );
  const recap = messages[4].payload as Row;
  assertEquals(recap.kind, "day");
  assertEquals(recap.kcal, 1640);
  assertEquals(recap.kcal_target, 2900);

  // The memory note is saved under the run, and usage is recorded per call.
  assertEquals(ledger.memorySaves.length, 1);
  assertEquals(ledger.memorySaves[0].p_run_id, ledger.runId);
  assertEquals(ledger.usage.length, 2);
  assertEquals(ledger.usage[0].p_operation, "coach_checkpoint");
});

Deno.test("an unchanged state collapses onto the completed run without a model call", async () => {
  const fake = coachFakeAdmin({ tables: fixtures() });
  const ledger = installCoachLedger(fake, {
    userId: USER,
    claimStatus: "complete",
  });
  const requests: RecordedRequest[] = [];
  const outcome = await runCoachPlan(
    fake.admin as never,
    { userId: USER, trigger: "foreground", foreground: true },
    {
      client: fakeClaude([jsonTextEvents(GOOD_PLAN)], requests),
      now: () => NOW,
    },
  );
  assertEquals(outcome.status, "complete");
  assertEquals(outcome.generated, false);
  assertEquals(requests.length, 0);
  assertEquals(ledger.completions.length, 0);
});

Deno.test("a refusal falls back to template copy instead of going silent", async () => {
  const fake = coachFakeAdmin({ tables: fixtures() });
  const ledger = installCoachLedger(fake, { userId: USER });
  const refusal = [messageStart(), ...messageEnd("refusal")];
  const outcome = await runCoachPlan(
    fake.admin as never,
    { userId: USER, trigger: "meal_complete", entryId: MEAL, foreground: true },
    { client: fakeClaude([refusal]), now: () => NOW },
  );
  assertEquals(outcome.generated, true);
  const completion = ledger.completions[0];
  assertEquals((completion.p_result as Row).fallback, true);
  const messages = completion.p_messages as Row[];
  assertEquals(messages[0].kind, "meal_ack");
  assertEquals(messages[0].body, "1,260 cal and 77g protein to go.");
  // In the foreground the reaction lands in the thread without a push.
  assertEquals(messages[0].notify, false);
  // Silence wins where the templates have nothing useful to say.
  assertEquals(
    messages.slice(1).map((message) => message.slot_key),
    ["training", "dinner", "wind_down"],
  );
});

Deno.test("a meal that already has an ack is not acknowledged twice", async () => {
  const tables = fixtures();
  tables.coach_messages.push({
    id: crypto.randomUUID(),
    user_id: USER,
    role: "coach",
    kind: "meal_ack",
    body: "Got it.",
    payload: { entry_id: MEAL },
    entry_id: MEAL,
    local_day: "2026-10-05",
    deliver_at: "2026-10-05T16:02:00Z",
    status: "delivered",
    created_at: "2026-10-05T16:02:00Z",
  });
  const fake = coachFakeAdmin({ tables });
  const ledger = installCoachLedger(fake, { userId: USER });
  await runCoachPlan(
    fake.admin as never,
    { userId: USER, trigger: "meal_complete", entryId: MEAL },
    {
      client: fakeClaude([
        jsonTextEvents({ ...GOOD_PLAN, reaction: null }),
        jsonTextEvents(REPAIR),
      ]),
      now: () => NOW,
    },
  );
  const messages = ledger.completions[0].p_messages as Row[];
  assertEquals(messages.some((message) => message.kind === "meal_ack"), false);
});

Deno.test("the coach stays silent when it is switched off", async () => {
  const fake = coachFakeAdmin({
    tables: fixtures({ profile: { coach_enabled: false } }),
  });
  const ledger = installCoachLedger(fake, { userId: USER });
  const outcome = await runCoachPlan(
    fake.admin as never,
    { userId: USER, trigger: "foreground" },
    { client: fakeClaude([jsonTextEvents(GOOD_PLAN)]), now: () => NOW },
  );
  assertEquals(outcome.status, "disabled");
  assertEquals(ledger.claims.length, 0);
});
