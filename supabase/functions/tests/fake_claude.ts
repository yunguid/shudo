import { Anthropic } from "../_shared/claude.ts";

/// The SDK types its transport against Node-flavoured fetch; the Deno
/// global is structurally the same at runtime.
type ClaudeFetch = NonNullable<
  ConstructorParameters<typeof Anthropic>[0]
>["fetch"];

/// Test doubles for the Anthropic Messages API. Each fake response is the
/// exact SSE event sequence the API streams, so the real SDK parses it.

export type SSEEvent = Record<string, unknown> & { type: string };

export function sseResponse(events: SSEEvent[]): Response {
  const body = events.map((event) =>
    `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`
  ).join("");
  return new Response(body, {
    status: 200,
    headers: { "content-type": "text/event-stream" },
  });
}

export function messageStart(model = "claude-sonnet-5-5"): SSEEvent {
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

export function messageEnd(stopReason: string, outputTokens = 20): SSEEvent[] {
  return [
    {
      type: "message_delta",
      delta: { stop_reason: stopReason, stop_sequence: null },
      usage: { output_tokens: outputTokens },
    },
    { type: "message_stop" },
  ];
}

/** A complete JSON-format response streamed as text deltas. */
export function jsonTextEvents(
  value: unknown,
  options: { model?: string; chunks?: number } = {},
): SSEEvent[] {
  const text = JSON.stringify(value);
  const chunks = Math.max(1, options.chunks ?? 2);
  const size = Math.ceil(text.length / chunks);
  const deltas: SSEEvent[] = [];
  for (let offset = 0; offset < text.length; offset += size) {
    deltas.push({
      type: "content_block_delta",
      index: 0,
      delta: { type: "text_delta", text: text.slice(offset, offset + size) },
    });
  }
  return [
    messageStart(options.model),
    {
      type: "content_block_start",
      index: 0,
      content_block: { type: "text", text: "" },
    },
    ...deltas,
    { type: "content_block_stop", index: 0 },
    ...messageEnd("end_turn"),
  ];
}

/** Optional web search, then the strict submission tool carrying `value`. */
export function submitToolEvents(
  toolName: string,
  value: unknown,
  options: { search?: boolean; sources?: string[]; model?: string } = {},
): SSEEvent[] {
  const events: SSEEvent[] = [messageStart(options.model)];
  let index = 0;
  if (options.search) {
    events.push(
      {
        type: "content_block_start",
        index,
        content_block: {
          type: "server_tool_use",
          id: "srvtoolu_1",
          name: "web_search",
          input: {},
        },
      },
      {
        type: "content_block_delta",
        index,
        delta: {
          type: "input_json_delta",
          partial_json: '{"query":"nutrition"}',
        },
      },
      { type: "content_block_stop", index },
    );
    index += 1;
    events.push(
      {
        type: "content_block_start",
        index,
        content_block: {
          type: "web_search_tool_result",
          tool_use_id: "srvtoolu_1",
          content: (options.sources ?? []).map((url) => ({
            type: "web_search_result",
            url,
            title: "Source",
            encrypted_content: "x",
            page_age: null,
          })),
        },
      },
      { type: "content_block_stop", index },
    );
    index += 1;
  }
  const json = JSON.stringify(value);
  events.push(
    {
      type: "content_block_start",
      index,
      content_block: {
        type: "tool_use",
        id: "toolu_submit",
        name: toolName,
        input: {},
      },
    },
    {
      type: "content_block_delta",
      index,
      delta: {
        type: "input_json_delta",
        partial_json: json.slice(0, Math.ceil(json.length / 2)),
      },
    },
    {
      type: "content_block_delta",
      index,
      delta: {
        type: "input_json_delta",
        partial_json: json.slice(Math.ceil(json.length / 2)),
      },
    },
    { type: "content_block_stop", index },
    ...messageEnd("tool_use"),
  );
  return events;
}

export type RecordedRequest = Record<string, unknown> & {
  model?: string;
  tools?: Array<Record<string, unknown>>;
  output_config?: Record<string, unknown>;
  system?: Array<{ text: string }>;
  messages?: Array<{ role: string; content: unknown }>;
};

/**
 * An SDK client whose transport replays scripted responses in order (the
 * last one repeats). A response can be an event list or an HTTP status to
 * simulate API errors.
 */
export function fakeClaude(
  responses: Array<SSEEvent[] | number>,
  requests: RecordedRequest[] = [],
): Anthropic {
  let index = 0;
  return new Anthropic({
    apiKey: "test-key-not-a-secret",
    maxRetries: 0,
    fetch: ((_input: RequestInfo | URL, init?: RequestInit) => {
      requests.push(JSON.parse(String(init?.body ?? "{}")));
      const scripted = responses[Math.min(index, responses.length - 1)];
      index += 1;
      if (typeof scripted === "number") {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              type: "error",
              error: { type: "api_error", message: "scripted" },
            }),
            {
              status: scripted,
              headers: { "content-type": "application/json" },
            },
          ),
        );
      }
      return Promise.resolve(sseResponse(scripted));
    }) as unknown as ClaudeFetch,
  });
}

/** All user-visible prompt text in a recorded request (system + user turns). */
export function promptText(request: RecordedRequest): string {
  const parts: string[] = [];
  for (const block of request.system ?? []) parts.push(block.text);
  for (const message of request.messages ?? []) {
    if (typeof message.content === "string") parts.push(message.content);
    else if (Array.isArray(message.content)) {
      for (const block of message.content as Array<Record<string, unknown>>) {
        if (typeof block.text === "string") parts.push(block.text);
      }
    }
  }
  return parts.join("\n");
}
