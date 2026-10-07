import {
  Anthropic,
  callClaudeStructured,
  CLAUDE_MODELS,
  ClaudeRefusalError,
  systemBlocks,
  toClaudeSchema,
} from "../_shared/claude.ts";
import { assert, assertEquals } from "./assertions.ts";

/// The SDK types its transport against Node-flavoured fetch; the Deno
/// global is structurally the same at runtime.
type ClaudeFetch = NonNullable<
  ConstructorParameters<typeof Anthropic>[0]
>["fetch"];

type SSEEvent = Record<string, unknown> & { type: string };

function sseResponse(events: SSEEvent[]): Response {
  const body = events.map((event) =>
    `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`
  ).join("");
  return new Response(body, {
    status: 200,
    headers: { "content-type": "text/event-stream" },
  });
}

function messageStart(model: string = CLAUDE_MODELS.sonnet): SSEEvent {
  return {
    type: "message_start",
    message: {
      id: "msg_test",
      type: "message",
      role: "assistant",
      model,
      content: [],
      stop_reason: null,
      stop_sequence: null,
      usage: { input_tokens: 10, output_tokens: 0 },
    },
  };
}

function messageEnd(stopReason: string, outputTokens = 20): SSEEvent[] {
  return [
    {
      type: "message_delta",
      delta: { stop_reason: stopReason, stop_sequence: null },
      usage: { output_tokens: outputTokens },
    },
    { type: "message_stop" },
  ];
}

function fakeClient(
  responses: SSEEvent[][],
  requests: Array<Record<string, unknown>> = [],
): Anthropic {
  let index = 0;
  return new Anthropic({
    apiKey: "test-key",
    maxRetries: 0,
    fetch: ((_input: RequestInfo | URL, init?: RequestInit) => {
      requests.push(JSON.parse(String(init?.body ?? "{}")));
      const events = responses[Math.min(index, responses.length - 1)];
      index += 1;
      return Promise.resolve(sseResponse(events));
    }) as unknown as ClaudeFetch,
  });
}

const SCHEMA = {
  type: "object",
  additionalProperties: false,
  properties: {
    preview: { type: "string", minLength: 1, maxLength: 40 },
    calories: { type: "number", minimum: 0 },
    note: { type: ["string", "null"] },
    tags: {
      type: "array",
      maxItems: 3,
      minItems: 2,
      items: { type: "string" },
    },
  },
  required: ["preview", "calories", "note", "tags"],
};

Deno.test("toClaudeSchema drops unsupported constraints and keeps structure", () => {
  const converted = toClaudeSchema(SCHEMA) as {
    properties: Record<string, Record<string, unknown>>;
    required: string[];
    additionalProperties: boolean;
  };
  assertEquals(converted.properties.preview, { type: "string" });
  assertEquals(converted.properties.calories, { type: "number" });
  assertEquals(converted.properties.note, {
    anyOf: [{ type: "string" }, { type: "null" }],
  });
  assertEquals(converted.properties.tags, {
    type: "array",
    minItems: 1,
    items: { type: "string" },
  });
  assertEquals(converted.required, ["preview", "calories", "note", "tags"]);
  assertEquals(converted.additionalProperties, false);
});

Deno.test("structured calls stream JSON text and parse the final object", async () => {
  const json =
    '{"preview":"Eggs and rice","calories":520,"note":null,"tags":["a"]}';
  const requests: Array<Record<string, unknown>> = [];
  const client = fakeClient([[
    messageStart(),
    {
      type: "content_block_start",
      index: 0,
      content_block: { type: "text", text: "" },
    },
    {
      type: "content_block_delta",
      index: 0,
      delta: { type: "text_delta", text: json.slice(0, 30) },
    },
    {
      type: "content_block_delta",
      index: 0,
      delta: { type: "text_delta", text: json.slice(30) },
    },
    { type: "content_block_stop", index: 0 },
    ...messageEnd("end_turn"),
  ]], requests);

  const partials: string[] = [];
  const phases: string[] = [];
  const result = await callClaudeStructured({
    workload: "test",
    model: CLAUDE_MODELS.sonnet,
    effort: "low",
    system: systemBlocks([{ text: "Be precise.", cache: true }]),
    messages: [{ role: "user", content: "Breakfast" }],
    schema: SCHEMA,
    schemaName: "submit_test",
    timeoutMs: 5_000,
    client,
    onPartialJSON: (partial) => {
      partials.push(partial);
      return Promise.resolve();
    },
    onPhase: (phase) => {
      phases.push(phase);
      return Promise.resolve();
    },
  });

  assertEquals(result.output, JSON.parse(json));
  assertEquals(partials.length, 2);
  assertEquals(partials[1], json);
  assertEquals(phases, ["output_started"]);
  assertEquals(result.webSearchUsed, false);
  const request = requests[0] as {
    model: string;
    output_config: { effort: string; format: { type: string } };
    fallbacks: string;
    tools?: unknown;
  };
  assertEquals(request.model, "claude-sonnet-5-5");
  assertEquals(request.output_config.effort, "low");
  assertEquals(request.output_config.format.type, "json_schema");
  assertEquals(request.fallbacks, "default");
  assertEquals(request.tools, undefined);
});

Deno.test("web-search calls finish through the strict submit tool and keep sources", async () => {
  const input =
    '{"preview":"Chipotle bowl","calories":845,"note":"Official menu","tags":["x"]}';
  const requests: Array<Record<string, unknown>> = [];
  const client = fakeClient([[
    messageStart(),
    {
      type: "content_block_start",
      index: 0,
      content_block: {
        type: "server_tool_use",
        id: "srvtoolu_1",
        name: "web_search",
        input: {},
      },
    },
    {
      type: "content_block_delta",
      index: 0,
      delta: {
        type: "input_json_delta",
        partial_json: '{"query":"chipotle bowl nutrition"}',
      },
    },
    { type: "content_block_stop", index: 0 },
    {
      type: "content_block_start",
      index: 1,
      content_block: {
        type: "web_search_tool_result",
        tool_use_id: "srvtoolu_1",
        content: [{
          type: "web_search_result",
          url: "https://www.chipotle.com/nutrition-calculator#top",
          title: "Nutrition",
          encrypted_content: "abc",
          page_age: null,
        }],
      },
    },
    { type: "content_block_stop", index: 1 },
    {
      type: "content_block_start",
      index: 2,
      content_block: {
        type: "tool_use",
        id: "toolu_1",
        name: "submit_test",
        input: {},
      },
    },
    {
      type: "content_block_delta",
      index: 2,
      delta: { type: "input_json_delta", partial_json: input.slice(0, 25) },
    },
    {
      type: "content_block_delta",
      index: 2,
      delta: { type: "input_json_delta", partial_json: input.slice(25) },
    },
    { type: "content_block_stop", index: 2 },
    ...messageEnd("tool_use"),
  ]], requests);

  const phases: string[] = [];
  const partials: string[] = [];
  const result = await callClaudeStructured({
    workload: "test",
    model: CLAUDE_MODELS.sonnet,
    effort: "medium",
    system: systemBlocks([{ text: "Look it up." }]),
    messages: [{ role: "user", content: "Chipotle bowl" }],
    schema: SCHEMA,
    schemaName: "submit_test",
    timeoutMs: 5_000,
    webSearch: {
      maxUses: 2,
      userLocation: { city: "New York", country: "US" },
    },
    client,
    onPhase: (phase) => {
      phases.push(phase);
      return Promise.resolve();
    },
    onPartialJSON: (partial) => {
      partials.push(partial);
      return Promise.resolve();
    },
  });

  assertEquals(result.output, JSON.parse(input));
  assertEquals(phases, [
    "web_search_started",
    "web_search_completed",
    "output_started",
  ]);
  assertEquals(partials[partials.length - 1], input);
  assertEquals(result.webSearchUsed, true);
  assertEquals(result.webSearchSources, [{
    url: "https://www.chipotle.com/nutrition-calculator",
  }]);
  const request = requests[0] as {
    output_config: Record<string, unknown>;
    tools: Array<Record<string, unknown>>;
  };
  assertEquals(request.output_config.format, undefined);
  assertEquals(request.tools[0].type, "web_search_20260209");
  assertEquals(request.tools[0].allowed_callers, ["direct"]);
  assertEquals(
    (request.tools[0].user_location as Record<string, unknown>).city,
    "New York",
  );
  assertEquals(request.tools[1].strict, true);
});

Deno.test("refusals surface as ClaudeRefusalError", async () => {
  const client = fakeClient([[
    messageStart(),
    ...messageEnd("refusal", 0),
  ]]);
  let caught: unknown = null;
  try {
    await callClaudeStructured({
      workload: "test",
      model: CLAUDE_MODELS.opus,
      effort: "medium",
      system: [],
      messages: [{ role: "user", content: "x" }],
      schema: SCHEMA,
      schemaName: "submit_test",
      timeoutMs: 5_000,
      client,
    });
  } catch (error) {
    caught = error;
  }
  assert(caught instanceof ClaudeRefusalError, "expected a refusal error");
});

Deno.test("haiku requests omit effort and fallbacks", async () => {
  const requests: Array<Record<string, unknown>> = [];
  const client = fakeClient([[
    messageStart(CLAUDE_MODELS.haiku),
    {
      type: "content_block_start",
      index: 0,
      content_block: { type: "text", text: "" },
    },
    {
      type: "content_block_delta",
      index: 0,
      delta: {
        type: "text_delta",
        text: '{"preview":"x","calories":1,"note":null,"tags":[]}',
      },
    },
    { type: "content_block_stop", index: 0 },
    ...messageEnd("end_turn"),
  ]], requests);
  await callClaudeStructured({
    workload: "test",
    model: CLAUDE_MODELS.haiku,
    effort: "low",
    system: [],
    messages: [{ role: "user", content: "x" }],
    schema: SCHEMA,
    schemaName: "submit_test",
    timeoutMs: 5_000,
    client,
  });
  const request = requests[0] as {
    output_config: Record<string, unknown>;
    fallbacks?: unknown;
  };
  assertEquals(request.output_config.effort, undefined);
  assertEquals(request.fallbacks, undefined);
});
