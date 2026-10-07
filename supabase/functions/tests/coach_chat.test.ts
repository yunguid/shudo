import {
  type CoachSendRequest,
  type CoachStreamEvent,
  detectWellbeingSignal,
  encodeSseEvent,
  parseCoachChatBody,
  renderHistory,
  runCoachTurn,
  SseChannel,
} from "../_shared/coach_chat.ts";
import type { CoachThreadRow } from "../_shared/coach_context.ts";
import { CHAT_REFUSAL_FALLBACK } from "../_shared/coach_fallbacks.ts";
import { COACH_TOOL_DEFINITIONS } from "../_shared/coach_tools.ts";
import { assert, assertEquals, assertThrows } from "./assertions.ts";
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
  type RecordedRequest,
  type SSEEvent,
} from "./fake_claude.ts";

const USER = "11111111-1111-4111-8111-111111111111";
const USER_MESSAGE = "44444444-4444-4444-8444-444444444444";
const NOW = new Date("2026-10-05T16:40:00Z");

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
      delta: { type: "text_delta", text: text.slice(0, 20) },
    },
    {
      type: "content_block_delta",
      index: 0,
      delta: { type: "text_delta", text: text.slice(20) },
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

function tables(): Record<string, Row[]> {
  return {
    profiles: [{
      user_id: USER,
      display_name: "Luke",
      timezone: "America/New_York",
      units: "imperial",
      goal_type: "gain",
      daily_macro_target: {
        calories_kcal: 2900,
        protein_g: 170,
        carbs_g: 380,
        fat_g: 80,
      },
      weight_kg: 73.7,
      target_weight_kg: 79.4,
      coach_enabled: true,
      coach_intensity: "locked_in",
      coach_profanity: "mild",
      quiet_hours_start: "23:00:00",
      quiet_hours_end: "07:00:00",
      location_recs_enabled: false,
      physique_ai_review_enabled: false,
    }],
    entries: [{
      id: crypto.randomUUID(),
      user_id: USER,
      local_day: "2026-10-05",
      occurred_at: "2026-10-05T12:30:00Z",
      created_at: "2026-10-05T12:30:00Z",
      updated_at: "2026-10-05T12:31:00Z",
      title: "Eggs and rice",
      status: "complete",
      calories_kcal: 1640,
      protein_g: 93,
      carbs_g: 180,
      fat_g: 52,
    }],
    coach_messages: [
      {
        id: crypto.randomUUID(),
        user_id: USER,
        role: "coach",
        kind: "plan",
        body: "Morning. Eat early today.",
        payload: {},
        local_day: "2026-10-05",
        deliver_at: "2026-10-05T11:10:00Z",
        status: "delivered",
        slot_key: "wake",
        created_at: "2026-10-05T03:00:00Z",
      },
      {
        id: USER_MESSAGE,
        user_id: USER,
        role: "user",
        kind: "text",
        body: "How am I doing today?",
        payload: {},
        local_day: "2026-10-05",
        deliver_at: "2026-10-05T16:39:00Z",
        status: "delivered",
        created_at: "2026-10-05T16:39:00Z",
      },
    ],
  };
}

function request(text: string): CoachSendRequest {
  return {
    clientRequestId: "55555555-5555-4555-8555-555555555555",
    text,
    inputMode: "typed",
    speechEngine: null,
    localDay: "2026-10-05",
    timezone: "America/New_York",
    attachmentPath: null,
    location: null,
    contextHint: null,
  };
}

async function runTurn(text: string, responses: SSEEvent[][]) {
  const fake = coachFakeAdmin({ tables: tables() });
  const ledger = installCoachLedger(fake, { userId: USER });
  const requests: RecordedRequest[] = [];
  const events: CoachStreamEvent[] = [];
  const outcome = await runCoachTurn(
    {
      admin: fake.admin as never,
      userId: USER,
      runId: ledger.runId,
      claimToken: ledger.claimToken,
      request: request(text),
      userMessageId: USER_MESSAGE,
      now: NOW,
    },
    (event) => events.push(event),
    { client: fakeClaude(responses, requests) },
  );
  return { fake, ledger, requests, events, outcome };
}

Deno.test("chat runs the tool loop: tool call, tool result, then the reply", async () => {
  const reply =
    "You're at 1,640 cal with 1,260 left.\n\nA shake at 3 and a big dinner closes it.";
  const { ledger, requests, events, outcome } = await runTurn(
    "How am I doing today?",
    [
      toolUseEvents("get_day_state", { local_day: "2026-10-05" }, "toolu_day"),
      textEvents(reply),
    ],
  );

  assertEquals(outcome.status, "complete");
  assertEquals(outcome.toolCalls, ["get_day_state"]);
  assertEquals(requests.length, 2);

  // Request shape: persona system blocks, strict tools + web search, and the
  // live state as a mid-conversation system message after his words.
  const first = requests[0];
  assertEquals(first.model, "claude-sonnet-5-5");
  const toolNames = (first.tools ?? []).map((tool) => tool.name);
  assert(
    toolNames.includes("get_day_state") && toolNames.includes("web_search"),
  );
  assert(
    (first.tools ?? []).filter((tool) => tool.name !== "web_search").every((
      tool,
    ) => tool.strict === true),
  );
  assertEquals(first.tool_choice, undefined);
  const firstMessages = first.messages ?? [];
  assertEquals(firstMessages.at(-1)?.role, "system");
  assert(String(firstMessages.at(-1)?.content).includes("<live_state>"));
  assertEquals(firstMessages.at(-2)?.role, "user");
  // History renders the morning text as an earlier assistant turn.
  assertEquals(firstMessages[0].role, "user");
  assertEquals(firstMessages[1].role, "assistant");

  // The assistant turn is appended unchanged and answered with one result.
  const second = requests[1].messages ?? [];
  const assistant = second.at(-2);
  assertEquals(assistant?.role, "assistant");
  assertEquals((assistant?.content as Row[])[0].type, "tool_use");
  const result = (second.at(-1)?.content as Row[])[0];
  assertEquals(result.type, "tool_result");
  assertEquals(result.tool_use_id, "toolu_day");
  assert(String(result.content).includes("Eggs and rice"));

  // Stream: status → deltas → final message → done.
  assertEquals(events[0], { type: "status", label: "Checking today's log…" });
  const deltas = events.filter((event) => event.type === "delta");
  assertEquals(
    deltas.map((event) => event.type === "delta" ? event.text : "").join(""),
    reply,
  );
  const final = events.find((event) => event.type === "message");
  assert(final?.type === "message");
  assertEquals(final.message.body, reply);
  assertEquals(events.at(-1)?.type, "done");

  // Persisted under the run fence; usage recorded per model request.
  const last = ledger.streams.at(-1)!;
  assertEquals(last.p_done, true);
  assertEquals(last.p_body, reply);
  assertEquals(ledger.completions.length, 1);
  assertEquals(ledger.completions[0].p_messages, []);
  assertEquals(ledger.usage.length, 2);
  assertEquals(ledger.usage[0].p_operation, "coach_reply");
});

Deno.test("a reply that breaks the guard is rewritten before it is final", async () => {
  const { ledger, events } = await runTurn("What should I eat?", [
    textEvents("Easy. Eat 4,200 cal today and you're set."),
    jsonTextEvents({
      bubbles: [
        "Big dinner tonight and a shake before bed. That closes the gap.",
      ],
    }),
  ]);
  const final = events.find((event) => event.type === "message");
  assert(final?.type === "message");
  assertEquals(
    final.message.body,
    "Big dinner tonight and a shake before bed. That closes the gap.",
  );
  assertEquals(ledger.streams.at(-1)?.p_body, final.message.body);
  assertEquals((ledger.streams.at(-1)?.p_payload as Row).rewritten, true);
});

Deno.test("a refusal is answered in character", async () => {
  const { events, outcome } = await runTurn("Tell me something off-limits.", [
    [messageStart(), ...messageEnd("refusal")],
  ]);
  assertEquals(outcome.text, CHAT_REFUSAL_FALLBACK);
  assert(
    events.some((event) =>
      event.type === "message" && event.message.body === CHAT_REFUSAL_FALLBACK
    ),
  );
});

Deno.test("a wellbeing signal adds the static support card and takes numbers off the table", async () => {
  const { ledger, requests } = await runTurn(
    "Honestly I've been feeling guilty after eating and kind of in a dark place.",
    [textEvents(
      "Stepping out of coach mode for a second. That sounds heavy, and I'm glad you told me. Is there someone you trust you can talk to today?",
    )],
  );
  assert(
    String(requests[0].messages?.at(-1)?.content).includes(
      '"wellbeing_signal":true',
    ),
  );
  const cards = ledger.completions[0].p_messages as Row[];
  assertEquals(cards.length, 1);
  assertEquals((cards[0].payload as Row).safety_flag, "wellbeing");
  assert(String(cards[0].body).includes("988"));
});

Deno.test("SSE events are one data line each, plus keepalive comments", async () => {
  const line = encodeSseEvent({
    type: "delta",
    message_id: "m",
    text: "two\nlines",
  });
  assertEquals(
    line,
    'data: {"type":"delta","message_id":"m","text":"two\\nlines"}\n\n',
  );
  const channel = new SseChannel(0);
  channel.send({ type: "status", label: "Checking today's log…" });
  channel.send({ type: "done", run_id: "r", message_ids: [] });
  channel.close();
  channel.send({
    type: "error",
    code: "late",
    message: "ignored",
    retryable: false,
  });
  assertEquals(
    channel.response.headers.get("content-type"),
    "text/event-stream; charset=utf-8",
  );
  const body = await channel.response.text();
  const lines = body.split("\n").filter(Boolean);
  assertEquals(lines.length, 2);
  assert(lines.every((value) => value.startsWith("data: ")));
  assertEquals(JSON.parse(lines[1].slice(6)).type, "done");
});

Deno.test("chat bodies are validated: send and card action shapes", () => {
  const send = parseCoachChatBody({
    client_request_id: "55555555-5555-4555-8555-555555555555",
    text: "  Log two eggs  ",
    input_mode: "dictated",
    speech_engine: "apple.speech_transcriber",
    local_day: "2026-10-05",
    timezone: "America/New_York",
    location: {
      captured_at: "2026-10-05T16:30:00Z",
      quality: "precise",
      locality: { city: "New York", timezone: "America/New_York" },
      stores: [{
        ref: "s1",
        name: "7-Eleven",
        category: "convenience",
        distance_m: 120,
        walk_minutes: 2,
        latitude: 40.7,
      }],
    },
  });
  assert(send.kind === "send");
  assertEquals(send.request.text, "Log two eggs");
  assertEquals(send.request.inputMode, "dictated");
  assertEquals(send.request.location?.stores[0].name, "7-Eleven");
  assertEquals("latitude" in (send.request.location?.stores[0] ?? {}), false);

  const action = parseCoachChatBody({
    client_request_id: "55555555-5555-4555-8555-555555555555",
    action: {
      kind: "goal_change",
      id: "66666666-6666-4666-8666-666666666666",
      decision: "apply",
    },
  });
  assert(action.kind === "action");
  assertEquals(action.action.decision, "apply");

  assertThrows(
    () => parseCoachChatBody({ client_request_id: "nope", text: "hi" }),
    400,
  );
  assertThrows(
    () =>
      parseCoachChatBody({
        client_request_id: "55555555-5555-4555-8555-555555555555",
        text: "",
        local_day: "2026-10-05",
        timezone: "America/New_York",
      }),
    400,
  );
});

Deno.test("wellbeing detection catches the hard lines, not ordinary hunger", () => {
  assert(detectWellbeingSignal("I made myself throw up after dinner"));
  assert(detectWellbeingSignal("been starving myself to get lean"));
  assert(detectWellbeingSignal("I'm in a dark place lately"));
  assertEquals(
    detectWellbeingSignal("I'm starving, what should I grab?"),
    false,
  );
  assertEquals(
    detectWellbeingSignal("Leg day almost made me throw up lol"),
    false,
  );
});

Deno.test("history renders as alternating text turns from yesterday on", () => {
  const row = (
    role: "coach" | "user",
    body: string,
    day: string,
  ): CoachThreadRow => ({
    id: crypto.randomUUID(),
    role,
    kind: "text",
    body,
    payload: {},
    local_day: day,
    deliver_at: `${day}T12:00:00Z`,
    slot_key: null,
    status: "delivered",
    created_at: `${day}T12:00:00Z`,
  });
  const turns = renderHistory([
    row("coach", "Two days ago.", "2026-10-03"),
    row("coach", "Morning.", "2026-10-04"),
    row("coach", "Lunch time.", "2026-10-04"),
    row("user", "On it.", "2026-10-04"),
  ], { localDay: "2026-10-05", excludeIds: new Set() });
  assertEquals(turns.map((turn) => turn.role), ["user", "assistant", "user"]);
  assertEquals(turns[1].text, "Morning.\n\nLunch time.");
  assertEquals(
    COACH_TOOL_DEFINITIONS.map((tool) => (tool as { name: string }).name),
    [
      "draft_training_plan",
      "find_nearby_food",
      "get_day_state",
      "get_weight_trend",
      "log_activity_text",
      "log_meal_text",
      "log_weight",
      "remember",
      "request_physique_review",
      "update_bio",
      "update_goals",
    ],
  );
});
