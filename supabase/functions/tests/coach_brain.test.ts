import {
  type CoachSendRequest,
  type CoachStreamEvent,
  parseCoachChatBody,
  runCoachTurn,
} from "../_shared/coach_chat.ts";
import {
  buildCoachBrief,
  buildStatePack,
  loadCoachContext,
  renderMemoryBlock,
} from "../_shared/coach_context.ts";
import { runDayDigest } from "../_shared/coach_digest.ts";
import {
  answerOpenQuestion,
  labelledNote,
  noteKind,
  openQuestions,
  parseMemorySections,
} from "../_shared/coach_memory.ts";
import {
  COACH_CHAT_RULES,
  COACH_PERSONA_PROMPT,
  contextHintRouting,
} from "../_shared/coach_persona.ts";
import { runCoachPlan } from "../_shared/coach_plan.ts";
import { assert, assertEquals } from "./assertions.ts";
import {
  coachFakeAdmin,
  installCoachLedger,
  type Row,
} from "./coach_fake_admin.ts";
import {
  BACK_DAY,
  GOLDEN_DAY,
  GOLDEN_NOW,
  goldenMemorySections,
  goldenTables,
  LUKE,
  OPEN_QUESTIONS,
  persistMemorySaves,
  SANDWICH,
} from "./coach_golden_fixture.ts";
import {
  fakeClaude,
  jsonTextEvents,
  messageEnd,
  messageStart,
  type RecordedRequest,
  type SSEEvent,
} from "./fake_claude.ts";

/// Offline "does the coach know him" suite: everything runs against the
/// golden day (coach_golden_fixture.ts) and asserts on the prompts the
/// model would actually receive, plus what gets stored afterwards.

const SCALE_QUESTION = "Does he have a bathroom scale yet (ordering one)?";

function textEvents(text: string): SSEEvent[] {
  return [
    messageStart(),
    {
      type: "content_block_start",
      index: 0,
      content_block: { type: "text", text: "" },
    },
    {
      type: "content_block_delta",
      index: 0,
      delta: { type: "text_delta", text },
    },
    { type: "content_block_stop", index: 0 },
    ...messageEnd("end_turn"),
  ];
}

function toolUseEvents(name: string, input: unknown, id: string): SSEEvent[] {
  return [
    messageStart(),
    {
      type: "content_block_start",
      index: 0,
      content_block: { type: "tool_use", id, name, input: {} },
    },
    {
      type: "content_block_delta",
      index: 0,
      delta: { type: "input_json_delta", partial_json: JSON.stringify(input) },
    },
    { type: "content_block_stop", index: 0 },
    ...messageEnd("tool_use"),
  ];
}

function userContent(request: RecordedRequest): string {
  return String(request.messages?.[0]?.content ?? "");
}

function packOf(request: RecordedRequest): Record<string, unknown> {
  const match = /<context_pack>\n([\s\S]*?)\n<\/context_pack>/u.exec(
    userContent(request),
  );
  return JSON.parse(match?.[1] ?? "{}");
}

function systemText(request: RecordedRequest): string {
  return (request.system ?? []).map((block) => block.text).join("\n");
}

function liveNote(request: RecordedRequest): string {
  const last = request.messages?.at(-1);
  assertEquals(last?.role, "system");
  return String(last?.content ?? "");
}

function sendRequest(
  text: string,
  overrides: Partial<CoachSendRequest> = {},
): CoachSendRequest {
  return {
    clientRequestId: "55555555-5555-4555-8555-555555555555",
    text,
    inputMode: "dictated",
    speechEngine: null,
    localDay: GOLDEN_DAY,
    timezone: "America/New_York",
    attachmentPath: null,
    location: null,
    contextHint: null,
    ...overrides,
  };
}

// ------------------------------------------------------------- the brief

Deno.test("the brief knows who Luke is right now, in a few dense lines", async () => {
  const fake = coachFakeAdmin({ tables: goldenTables() });
  const context = await loadCoachContext(fake.admin as never, LUKE, {
    now: GOLDEN_NOW,
  });
  const brief = buildCoachBrief(context);
  for (
    const expected of [
      "Goal: lean bulk, 162.5 → 175 lb",
      "no recent weigh-ins",
      "needs +0.6 lb/wk to hit 175 by Mon Mar 1",
      "Today (Wed Oct 7, 13:05): 780 of 3,000 cal and 28 of 170g protein, 2 meals; behind pace for the hour; last log 12:40.",
      "So far: trained (Morning bike).",
      "office 09:30 Mon–Sat; lifts Mon/Wed/Fri 18:30; bed 23:45, aiming for 23:00",
      "Today: office day, lift day (Chest day).",
      'Today\'s plan: "Eat early, lift heavy"',
      "Yesterday: Rest day, under-ate: 1,900 of 3,000 cal.",
      "Mon back day, 48 min: barbell row 135×10, pull-ups 8 reps",
      // Eight days back: outside the old 7-day window, named by date.
      "Wed Sep 30 chest day, 55 min: bench press 185×6 (PR), incline db press 70×8",
      'He said lately: yesterday 21:40 "chest day tomorrow at the Monterey Gym, finally.',
      "Open commitments: Buy whey and pre-workout on Saturday.",
      "Running jokes (sparingly): Milk era",
      "Use at most one of these as a natural callback.",
    ]
  ) {
    assert(brief.includes(expected), `brief is missing: ${expected}\n${brief}`);
  }
  // Compact, and it never quizzes him: plans assign the question to a slot.
  assert(brief.length < 1_600, `${brief.length} chars`);
  assertEquals(brief.includes("bathroom scale"), false);

  // Chat offers exactly one open question and leaves his words to history.
  const chat = buildCoachBrief(context, {
    includeHisWords: false,
    offerOpenQuestion: true,
  });
  assert(
    chat.includes(
      `Open question to ask when it fits (only this one): ${SCALE_QUESTION} (2 more after it)`,
    ),
  );
  assertEquals(chat.includes("Which gym"), false);
  assertEquals(chat.includes("He said lately"), false);

  // Sessions this week count the last 7 days only; the 8-day-old chest day
  // shows up as a callback but not as this week's work.
  assertEquals(
    (buildStatePack(context).recent as Row).sessions_this_week,
    1,
  );
});

Deno.test("the cached memory block holds durable things, not open questions or duplicates", async () => {
  const fake = coachFakeAdmin({ tables: goldenTables() });
  const context = await loadCoachContext(fake.admin as never, LUKE, {
    now: GOLDEN_NOW,
  });
  const block = renderMemoryBlock(context);
  assert(block.includes("## Training history"));
  assert(block.includes("- pattern: Eats almost nothing until lunch"));
  assert(block.includes("- running jokes: Milk era"));
  // Open questions live in the brief, one at a time; the schedule line too.
  assertEquals(block.includes("bathroom scale"), false);
  assertEquals(block.includes("Schedule (structured)"), false);
  // Note keys are noise outside the digest.
  assertEquals(block.includes("(n_20261005_1)"), false);
  // Older digests shrink to a headline; the last two keep their summary.
  assert(block.includes("2026-10-06 tue (score 55): Rest day, under-ate"));
  assert(block.includes("Coffee until lunch again."));
  const digestBlock = renderMemoryBlock(context, {
    noteKeys: true,
    includeOpenQuestions: true,
  });
  assert(digestBlock.includes(`- (open_questions) ${OPEN_QUESTIONS}`));
  assert(digestBlock.includes("- (n_20261006_1) commitment: Buy whey"));
});

// ------------------------------------------------------------- the plan

const GOLDEN_PLAN = {
  reaction: {
    kind: "meal_ack",
    body: "Sandwich helps. 2,220 cal and 142g protein still to go.",
    push_body: "Sandwich helps. 2,220 cal and 142g protein to go.",
  },
  slots: [
    {
      slot_key: "afternoon",
      deliver_local: "15:30",
      day: "today",
      skip: false,
      kind: "checkpoint",
      body:
        "Quick one: got a bathroom scale yet? Weekly weigh-ins tell us if the bulk is working.",
      push_body:
        "Quick one: got a bathroom scale yet? Weigh-ins tell us if the bulk works.",
    },
    {
      slot_key: "training",
      deliver_local: "18:15",
      day: "today",
      skip: false,
      kind: "checkpoint",
      body:
        "Chest day at the Monterey Gym. Eat an hour out, then go beat 185 for 6.",
      push_body: "Chest day. Eat an hour out, then go beat 185 for 6.",
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
  day_theme: null,
  memory_note: null,
};

Deno.test("plan prompts carry the brief, and exactly one slot asks the next open question", async () => {
  const fake = coachFakeAdmin({ tables: goldenTables() });
  const ledger = installCoachLedger(fake, {
    userId: LUKE,
    localDay: GOLDEN_DAY,
  });
  const requests: RecordedRequest[] = [];
  const outcome = await runCoachPlan(
    fake.admin as never,
    { userId: LUKE, trigger: "meal_complete", entryId: SANDWICH },
    {
      client: fakeClaude([jsonTextEvents(GOLDEN_PLAN)], requests),
      now: () => GOLDEN_NOW,
    },
  );
  assertEquals(outcome.status, "complete");
  // Clean copy: one call, no repair.
  assertEquals(requests.length, 1);
  const content = userContent(requests[0]);
  assert(content.startsWith("<brief>\nGoal: lean bulk, 162.5 → 175 lb"));
  assert(content.includes("bench press 185×6 (PR)"));
  assert(content.includes("Monterey Gym"));
  assert(systemText(requests[0]).includes(COACH_PERSONA_PROMPT.slice(0, 60)));
  assert(systemText(requests[0]).includes("one concrete callback"));
  // The open questions never sit in the prompt as a list to fire off.
  assertEquals(systemText(requests[0]).includes("bathroom scale"), false);
  const slots = (packOf(requests[0]).request as Row).slots as Row[];
  assertEquals(slots.map((slot) => slot.slot_key), [
    "afternoon",
    "training",
    "dinner",
    "wind_down",
  ]);
  assertEquals(slots.filter((slot) => slot.ask).map((slot) => slot.ask), [
    SCALE_QUESTION,
  ]);
  assertEquals(slots[0].ask, SCALE_QUESTION);
  // Weekday of the coached day, from the calendar.
  assertEquals((packOf(requests[0]).local as Row).weekday, "wed");

  const messages = ledger.completions[0].p_messages as Row[];
  assertEquals(messages.map((message) => message.kind), [
    "meal_ack",
    "checkpoint",
    "checkpoint",
    "recap",
  ]);
  assertEquals(messages[0].local_day, GOLDEN_DAY);
  const asks = messages.filter((message) =>
    typeof (message.payload as Row).asks === "string"
  );
  assertEquals(asks.length, 1);
  assertEquals(asks[0].slot_key, "afternoon");
  assertEquals((asks[0].payload as Row).asks, SCALE_QUESTION);
  // Lock-screen lines stay short.
  for (const message of messages) {
    const push = (message.payload as Row).push_body;
    if (typeof push === "string") assert(push.length <= 90, push);
  }
});

Deno.test("an open question asked in the last day and a half isn't asked again", async () => {
  const tables = goldenTables();
  tables.coach_messages.push({
    id: crypto.randomUUID(),
    user_id: LUKE,
    role: "coach",
    kind: "checkpoint",
    body: "Quick one: got a bathroom scale yet?",
    payload: { asks: SCALE_QUESTION },
    local_day: "2026-10-06",
    deliver_at: "2026-10-06T15:30:00Z",
    slot_key: "afternoon",
    status: "delivered",
    created_at: "2026-10-06T15:00:00Z",
  });
  const fake = coachFakeAdmin({ tables });
  installCoachLedger(fake, { userId: LUKE, localDay: GOLDEN_DAY });
  const requests: RecordedRequest[] = [];
  await runCoachPlan(
    fake.admin as never,
    { userId: LUKE, trigger: "foreground", foreground: true },
    {
      client: fakeClaude(
        [jsonTextEvents({ ...GOLDEN_PLAN, reaction: null })],
        requests,
      ),
      now: () => GOLDEN_NOW,
    },
  );
  const slots = (packOf(requests[0]).request as Row).slots as Row[];
  assertEquals(slots.some((slot) => slot.ask), false);
  // The brief tells the coach what is pending so a reply can settle it.
  assert(
    userContent(requests[0]).includes(
      `You last asked him (yesterday 11:30): "${SCALE_QUESTION}"`,
    ),
  );
});

Deno.test("voice-only misses get one repair and then ship; unsafe copy is dropped", async () => {
  const longPush =
    "Chest day at the Monterey Gym tonight. Eat something an hour out, bring the pre-workout, and go beat 185 for 6.";
  const draft = {
    ...GOLDEN_PLAN,
    reaction: null,
    slots: [
      { ...GOLDEN_PLAN.slots[1], push_body: longPush },
      {
        ...GOLDEN_PLAN.slots[3],
        body: "Ate too much? Skip breakfast tomorrow to even it out.",
        push_body: "Skip breakfast tomorrow to even it out.",
      },
    ],
  };
  const fake = coachFakeAdmin({ tables: goldenTables() });
  const ledger = installCoachLedger(fake, {
    userId: LUKE,
    localDay: GOLDEN_DAY,
  });
  const requests: RecordedRequest[] = [];
  await runCoachPlan(
    fake.admin as never,
    { userId: LUKE, trigger: "foreground", foreground: true },
    {
      // The repair comes back unchanged.
      client: fakeClaude(
        [jsonTextEvents(draft), jsonTextEvents(draft)],
        requests,
      ),
      now: () => GOLDEN_NOW,
    },
  );
  assertEquals(requests.length, 2);
  const repairPrompt = String(requests[1].messages?.[0]?.content);
  assert(repairPrompt.includes("verbose"));
  assert(repairPrompt.includes("extreme_diet"));
  const messages = ledger.completions[0].p_messages as Row[];
  const training = messages.find((message) => message.slot_key === "training");
  assertEquals((training?.payload as Row).push_body, longPush);
  assertEquals(
    messages.some((message) => message.slot_key === "wind_down"),
    false,
  );
});

Deno.test("a meal he logged by talking to the coach isn't acknowledged twice", async () => {
  const tables = goldenTables();
  tables.coach_messages.push({
    id: crypto.randomUUID(),
    user_id: LUKE,
    role: "coach",
    kind: "text",
    body: "Turkey sandwich, good. Shake at 3.",
    payload: { acked_entry_ids: [SANDWICH] },
    local_day: GOLDEN_DAY,
    deliver_at: "2026-10-07T16:41:00Z",
    status: "delivered",
    created_at: "2026-10-07T16:41:00Z",
  });
  const fake = coachFakeAdmin({ tables });
  const ledger = installCoachLedger(fake, {
    userId: LUKE,
    localDay: GOLDEN_DAY,
  });
  const requests: RecordedRequest[] = [];
  await runCoachPlan(
    fake.admin as never,
    { userId: LUKE, trigger: "meal_complete", entryId: SANDWICH },
    {
      client: fakeClaude([jsonTextEvents(GOLDEN_PLAN)], requests),
      now: () => GOLDEN_NOW,
    },
  );
  assertEquals((packOf(requests[0]).request as Row).reaction, null);
  const messages = ledger.completions[0].p_messages as Row[];
  assertEquals(messages.some((message) => message.kind === "meal_ack"), false);
});

Deno.test("after midnight, a late snack is acknowledged on the day the app filed it", async () => {
  const snack = "a1a1a1a1-0000-4000-8000-000000000009";
  const tables = goldenTables();
  tables.entries.push({
    id: snack,
    user_id: LUKE,
    local_day: "2026-10-08",
    occurred_at: "2026-10-08T04:20:00Z",
    created_at: "2026-10-08T04:20:00Z",
    updated_at: "2026-10-08T04:21:00Z",
    title: "Cereal with whole milk",
    status: "complete",
    calories_kcal: 420,
    protein_g: 16,
    carbs_g: 70,
    fat_g: 9,
  });
  const fake = coachFakeAdmin({ tables });
  const ledger = installCoachLedger(fake, {
    userId: LUKE,
    localDay: GOLDEN_DAY,
  });
  const requests: RecordedRequest[] = [];
  await runCoachPlan(
    fake.admin as never,
    { userId: LUKE, trigger: "meal_complete", entryId: snack },
    {
      client: fakeClaude([
        jsonTextEvents({
          reaction: {
            kind: "meal_ack",
            body: "Cereal and milk at 12:20, good call. Now bed.",
            push_body: null,
          },
          slots: [],
          day_theme: null,
          memory_note: null,
        }),
      ], requests),
      now: () => new Date("2026-10-08T04:30:00Z"), // Thu 00:30 EDT
    },
  );
  const reaction = (packOf(requests[0]).request as Row).reaction as Row;
  assert(String((reaction.subject as Row).day_note).includes("2026-10-08"));
  const ack = (ledger.completions[0].p_messages as Row[])
    .find((message) => message.kind === "meal_ack");
  assertEquals(ack?.local_day, "2026-10-08");
  assertEquals(ack?.entry_id, snack);
  // Quiet hours: it lands in the thread without buzzing the phone.
  assertEquals(ack?.notify, false);
});

// ------------------------------------------------------------- chat

async function chatTurn(
  fake: ReturnType<typeof coachFakeAdmin>,
  ledger: ReturnType<typeof installCoachLedger>,
  request: CoachSendRequest,
  responses: SSEEvent[][],
  services: Record<string, unknown> = {},
) {
  const requests: RecordedRequest[] = [];
  const events: CoachStreamEvent[] = [];
  const outcome = await runCoachTurn(
    {
      admin: fake.admin as never,
      userId: LUKE,
      runId: ledger.runId,
      claimToken: crypto.randomUUID(),
      request,
      userMessageId: crypto.randomUUID(),
      now: GOLDEN_NOW,
    },
    (event) => events.push(event),
    { client: fakeClaude(responses, requests), services: services as never },
  );
  return { requests, events, outcome };
}

Deno.test("from the Train screen, dictation is logged as a workout and confirmed in a few words", async () => {
  const fake = coachFakeAdmin({ tables: goldenTables() });
  const ledger = installCoachLedger(fake, {
    userId: LUKE,
    localDay: GOLDEN_DAY,
  });
  const activityId = "e5e5e5e5-0000-4000-8000-000000000001";
  const created: Row[] = [];
  const { requests, outcome } = await chatTurn(
    fake,
    ledger,
    sendRequest("bench 185 for 7, 185 for 6, incline 75s for 8", {
      contextHint: "train",
    }),
    [
      toolUseEvents("log_activity_text", {
        description: "bench 185 for 7, 185 for 6, incline 75s for 8",
        local_day: GOLDEN_DAY,
      }, "toolu_lift"),
      textEvents("Logged. Bench moving: 185 for 7 beats last week."),
    ],
    {
      createActivityFromText: (_admin: unknown, _user: unknown, input: Row) => {
        created.push(input);
        return Promise.resolve({ activityId, duplicate: false });
      },
    },
  );
  assertEquals(outcome.toolCalls, ["log_activity_text"]);
  assertEquals(created[0].source, "coach_chat");
  const note = liveNote(requests[0]);
  assert(note.startsWith("<brief>\nGoal: lean bulk"));
  assert(note.includes("<live_state>"));
  assert(note.includes("<routing>He spoke from the Train screen"));
  assert(note.includes("log_activity_text"));
  assert(note.includes("Logged. Bench moving."));
  // One open question on offer, never the list.
  assert(note.includes(`(only this one): ${SCALE_QUESTION}`));
  assertEquals(note.includes("Which gym"), false);
  const turn = requests[0].messages?.at(-2)?.content as Row[];
  const turnText = turn.map((block) => String(block.text ?? "")).join("\n");
  assert(turnText.includes("(wed 2026-10-07 13:05 · dictated"));
  assert(turnText.includes("from the Train screen"));
  // The tool result gives the model nothing to narrate.
  const result = JSON.stringify(requests[1].messages?.at(-2)?.content);
  assertEquals(result.includes(activityId), false);
  assertEquals(result.includes("estimate"), false);

  assertEquals(
    outcome.text,
    "Logged. Bench moving: 185 for 7 beats last week.",
  );
  const final = ledger.streams.at(-1)!;
  assertEquals((final.p_payload as Row).acked_activity_ids, [activityId]);
  assertEquals((final.p_payload as Row).context_hint, "train");
});

Deno.test("routing notes steer Body and Bio dictation; the Today mic gets none", async () => {
  const train = contextHintRouting("train")!;
  assert(train.includes("log_activity_text"));
  assert(train.includes("unless it is clearly a question"));
  const body = contextHintRouting("body")!;
  assert(body.includes("log_weight"));
  assert(body.includes("remember"));
  assert(body.includes("never the single reading"));
  const bio = contextHintRouting("bio")!;
  assert(bio.includes("update_bio in merge_current_message mode"));
  assertEquals(contextHintRouting(null), null);
  for (const text of [train, body, bio]) {
    assertEquals(/I've logged|saved to/iu.test(text), false);
  }

  const fake = coachFakeAdmin({ tables: goldenTables() });
  const ledger = installCoachLedger(fake, {
    userId: LUKE,
    localDay: GOLDEN_DAY,
  });
  const today = await chatTurn(
    fake,
    ledger,
    sendRequest("what should I eat before chest?"),
    [
      textEvents("Rice and chicken around 5. Then go move some weight."),
    ],
  );
  assertEquals(liveNote(today.requests[0]).includes("<routing>"), false);
  const weighIn = await chatTurn(
    fake,
    ledger,
    sendRequest("163.4 this morning", { contextHint: "body" }),
    [textEvents("Trend needs a few more weigh-ins. Keep stepping on it.")],
  );
  assert(
    liveNote(weighIn.requests[0]).includes(
      "<routing>He spoke from the Body screen",
    ),
  );
  // The chat rules point at the routing note and keep replies human.
  assert(COACH_CHAT_RULES.includes("routing note"));
  assert(COACH_CHAT_RULES.includes("never narrate logging"));
});

Deno.test("the parser accepts every mic context and drops anything else", () => {
  const body = (hint: unknown) => ({
    client_request_id: "55555555-5555-4555-8555-555555555555",
    text: "bench 185 for 6",
    local_day: GOLDEN_DAY,
    timezone: "America/New_York",
    ...(hint === undefined ? {} : { context_hint: hint }),
  });
  const hints: Array<[unknown, string | null]> = [
    ["train", "train"],
    [" BODY ", "body"],
    ["bio", "bio"],
    [null, null],
    [undefined, null],
    ["today", null],
    [7, null],
  ];
  for (const [input, expected] of hints) {
    const parsed = parseCoachChatBody(body(input));
    assert(parsed.kind === "send");
    assertEquals(parsed.request.contextHint, expected);
  }
});

Deno.test("machinery in a chat reply is rewritten; a leading preamble is just dropped", async () => {
  const fake = coachFakeAdmin({ tables: goldenTables() });
  const ledger = installCoachLedger(fake, {
    userId: LUKE,
    localDay: GOLDEN_DAY,
  });
  const machinery = await chatTurn(
    fake,
    ledger,
    sendRequest("had a protein bar"),
    [
      textEvents("I've logged that for you. Good bridge to dinner."),
      jsonTextEvents({ bubbles: ["Good bridge to dinner. Real meal by 7."] }),
    ],
  );
  assertEquals(
    machinery.outcome.text,
    "Good bridge to dinner. Real meal by 7.",
  );
  assert(
    String(machinery.requests[1].messages?.[0]?.content).includes(
      "talked about the app's machinery",
    ),
  );
  const preamble = await chatTurn(
    fake,
    ledger,
    sendRequest("rice or pasta tonight?"),
    [
      textEvents("Great question. Rice, double portion."),
    ],
  );
  assertEquals(preamble.outcome.text, "Rice, double portion.");
  // A safe reply that is merely long is kept as streamed: no swap.
  const long =
    "Rice tonight, a double portion with chicken, and a glass of whole milk on the side. Then a bowl of cereal before bed if you're still short. That closes most of the gap without forcing anything, and tomorrow starts with a real breakfast.";
  const verbose = await chatTurn(fake, ledger, sendRequest("dinner?"), [
    textEvents(long),
  ]);
  assertEquals(verbose.outcome.text, long);
  assertEquals(verbose.requests.length, 1);
});

Deno.test("an answer settles the open question, and the next turn already knows it", async () => {
  const fake = coachFakeAdmin({ tables: goldenTables() });
  const ledger = installCoachLedger(fake, {
    userId: LUKE,
    localDay: GOLDEN_DAY,
  });
  persistMemorySaves(fake);
  const first = await chatTurn(
    fake,
    ledger,
    sendRequest(
      "scale comes friday. and I train at the Monterey Gym, full rack and dumbbells to 100. hate oats btw",
    ),
    [
      toolUseEvents("answer_open_question", {
        question: "Does he have a bathroom scale yet?",
        answer: "Scale arrives Friday.",
      }, "toolu_q1"),
      toolUseEvents("answer_open_question", {
        question: "Which gym / what equipment now?",
        answer: "Trains at the Monterey Gym: full rack, dumbbells to 100.",
      }, "toolu_q2"),
      toolUseEvents(
        "remember",
        { note: "Hates oats.", kind: "preference" },
        "toolu_r",
      ),
      textEvents("Monterey has everything you need. No oats, noted for life."),
    ],
  );
  assertEquals(first.outcome.toolCalls, [
    "answer_open_question",
    "answer_open_question",
    "remember",
  ]);
  const notes = (fake.tables.coach_memory[0].sections as Row).notes as Row;
  assertEquals(notes.open_questions, "Which days can he realistically lift?");
  const values = Object.values(notes);
  assert(values.includes("Scale arrives Friday."));
  assert(
    values.includes("Trains at the Monterey Gym: full rack, dumbbells to 100."),
  );
  assert(values.includes("preference: Hates oats."));

  const second = await chatTurn(
    fake,
    ledger,
    sendRequest("what's the plan tonight?"),
    [
      textEvents("Chest at the Monterey. Eat at 5, lift at 6:30."),
    ],
  );
  const system = systemText(second.requests[0]);
  assert(
    system.includes(
      "- Trains at the Monterey Gym: full rack, dumbbells to 100.",
    ),
  );
  assert(system.includes("- preference: Hates oats."));
  assertEquals(system.includes("bathroom scale"), false);
  assert(
    liveNote(second.requests[0]).includes(
      "(only this one): Which days can he realistically lift?",
    ),
  );
});

// ------------------------------------------------------------- the digest

Deno.test("the nightly digest reads local times, keeps durable notes, and settles answered questions", async () => {
  const tables = goldenTables();
  tables.entries.push({
    id: crypto.randomUUID(),
    user_id: LUKE,
    local_day: "2026-10-06",
    occurred_at: "2026-10-06T23:10:00Z",
    created_at: "2026-10-06T23:10:00Z",
    updated_at: "2026-10-06T23:11:00Z",
    title: "Chicken burrito",
    status: "complete",
    calories_kcal: 1100,
    protein_g: 60,
    carbs_g: 120,
    fat_g: 38,
  });
  const fake = coachFakeAdmin({ tables });
  const ledger = installCoachLedger(fake, {
    userId: LUKE,
    localDay: "2026-10-06",
  });
  persistMemorySaves(fake);
  const saved: Row[] = [];
  fake.rpc.save_day_digest = (args) => {
    saved.push(args);
    return { status: "saved" };
  };
  const requests: RecordedRequest[] = [];
  const outcome = await runDayDigest(
    fake.admin as never,
    { userId: LUKE, digestDay: "2026-10-06" },
    {
      client: fakeClaude([
        jsonTextEvents({
          headline: "One real meal, then chest-day plans",
          summary:
            "Only dinner logged, so the log is probably incomplete. He named the gym for tomorrow.",
          highlights: ["Big burrito at dinner."],
          misses: ["Nothing logged before 7pm."],
          tomorrow_focus: ["Breakfast before 9"],
          score: null,
          game_plan: {
            theme: "Eat early, lift heavy",
            focus: ["Breakfast before 9"],
            training: { session_name: "Chest day" },
          },
          memory_ops: [
            {
              op: "add",
              key: null,
              text: "Trains at the Monterey Gym.",
              kind: "fact",
            },
            {
              op: "add",
              key: null,
              text: "Grab pre-workout before chest day.",
              kind: "commitment",
            },
            {
              op: "update",
              key: "open_questions",
              text:
                "Does he have a bathroom scale yet (ordering one)? Which days can he realistically lift?",
              kind: null,
            },
          ],
        }),
      ], requests),
      now: () => new Date("2026-10-07T09:00:00Z"),
    },
  );
  assertEquals(outcome.status, "complete");
  const content = userContent(requests[0]);
  assert(content.startsWith("<brief>\nGoal: lean bulk"));
  assert(
    content.includes("That day (Tue Oct 6): finished at 1,100 of 3,000 cal"),
  );
  // Meal times are his wall clock, not UTC stamps.
  assert(content.includes('"at":"19:10"'));
  assertEquals(content.includes("2026-10-06T23:10:00Z"), false);
  assert(content.includes('"role":"luke"'));
  // The digest sees note keys and the open questions it may settle.
  const system = systemText(requests[0]);
  assert(system.includes(`- (open_questions) ${OPEN_QUESTIONS}`));
  assert(system.includes("Set kind for each add"));
  assertEquals(saved.length, 1);
  const notes = (fake.tables.coach_memory[0].sections as Row).notes as Row;
  const values = Object.values(notes);
  assert(values.includes("Trains at the Monterey Gym."));
  assert(values.includes("commitment: Grab pre-workout before chest day."));
  assertEquals(
    notes.open_questions,
    "Does he have a bathroom scale yet (ordering one)? Which days can he realistically lift?",
  );
  assert(ledger.memorySaves.length >= 1);
});

// ------------------------------------------------------------- memory

Deno.test("open questions parse one per line and settle by meaning, not exact text", () => {
  const sections = parseMemorySections(goldenMemorySections());
  assertEquals(openQuestions(sections), [
    SCALE_QUESTION,
    "Which gym / what equipment now?",
    "Which days can he realistically lift?",
  ]);
  const now = new Date("2026-10-07T17:05:00Z");
  const answered = answerOpenQuestion(
    sections,
    "which days can you lift",
    "Lifts Mon, Wed, Fri after work.",
    now,
  );
  assertEquals(answered.question, "Which days can he realistically lift?");
  assertEquals(
    openQuestions(answered.sections),
    [SCALE_QUESTION, "Which gym / what equipment now?"],
  );
  assert(
    Object.values(answered.sections.notes).includes(
      "Lifts Mon, Wed, Fri after work.",
    ),
  );
  // An unrelated "question" keeps the list and still keeps the answer.
  const unrelated = answerOpenQuestion(
    sections,
    "favorite color?",
    "Blue.",
    now,
  );
  assertEquals(unrelated.question, null);
  assertEquals(openQuestions(unrelated.sections).length, 3);
  // The last answer removes the note entirely.
  let last = parseMemorySections({
    notes: { open_questions: "Does he have a scale yet?" },
  });
  last = answerOpenQuestion(last, "scale yet?", "Scale arrives Friday.", now)
    .sections;
  assertEquals(last.notes.open_questions, undefined);

  assertEquals(
    labelledNote("Hates oats.", "preference"),
    "preference: Hates oats.",
  );
  assertEquals(
    labelledNote("commitment: bed by 23:00", "commitment"),
    "commitment: bed by 23:00",
  );
  assertEquals(noteKind("running_jokes", "Milk era."), "running_joke");
  assertEquals(noteKind("n_1", "commitment: whey Saturday"), "commitment");
  assertEquals(noteKind("n_1", "Likes milk."), "fact");
});

Deno.test("training loads two weeks, newest last; the week is the last seven days", async () => {
  const fake = coachFakeAdmin({ tables: goldenTables() });
  const context = await loadCoachContext(fake.admin as never, LUKE, {
    now: GOLDEN_NOW,
  });
  assertEquals(context.recentActivities.map((activity) => activity.title), [
    "Chest day",
    "Back day",
    "Morning bike",
  ]);
  assertEquals(
    context.weekActivities.map((activity) => activity.id).includes(BACK_DAY),
    true,
  );
  assertEquals(
    context.weekActivities.some((activity) => activity.title === "Chest day"),
    false,
  );
  assertEquals(context.activities.map((activity) => activity.title), [
    "Morning bike",
  ]);
  // His own words load separately from the coach's texts.
  assertEquals(context.recentUserMessages.length, 1);
});
