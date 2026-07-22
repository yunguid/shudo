import {
  MAX_STREAMED_OUTPUT_CHARACTERS,
  readResponsesEventStream,
} from "../_shared/responses_stream.ts";
import { assertEquals } from "./assertions.ts";

function streamChunks(chunks: string[]): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder();
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk));
      controller.close();
    },
  });
}

function event(type: string, payload: Record<string, unknown>): string {
  return `event: ${type}\ndata: ${JSON.stringify({ type, ...payload })}\n\n`;
}

Deno.test("Responses SSE parser survives chunk boundaries and returns canonical completion", async () => {
  const partials: string[] = [];
  const created = event("response.created", {
    response: { id: "resp_test", status: "in_progress" },
  });
  const first = event("response.output_text.delta", {
    delta: '{"analysis_preview":"A chicken ',
  });
  const second = event("response.output_text.delta", {
    delta: 'bowl","title":"Chicken bowl"}',
  });
  const completed = event("response.completed", {
    response: {
      id: "resp_test",
      status: "completed",
      output: [{
        content: [{
          type: "output_text",
          text: '{"analysis_preview":"A chicken bowl","title":"Chicken bowl"}',
        }],
      }],
    },
  });
  const source = created + first + second + completed;
  const result = await readResponsesEventStream(
    streamChunks([source.slice(0, 17), source.slice(17, 83), source.slice(83)]),
    (output) => {
      partials.push(output);
      return Promise.resolve();
    },
  );

  assertEquals(result.responseId, "resp_test");
  assertEquals(
    result.outputText,
    '{"analysis_preview":"A chicken bowl","title":"Chicken bowl"}',
  );
  assertEquals(partials, [
    '{"analysis_preview":"A chicken ',
    '{"analysis_preview":"A chicken bowl","title":"Chicken bowl"}',
  ]);
});

Deno.test("Responses SSE parser rejects provider errors and truncated streams", async () => {
  for (
    const source of [
      event("response.failed", { response: { id: "resp_failed" } }),
      event("response.output_text.delta", { delta: '{"title":"Meal"}' }),
    ]
  ) {
    let message = "";
    try {
      await readResponsesEventStream(streamChunks([source]));
    } catch (error) {
      message = error instanceof Error ? error.message : String(error);
    }
    if (!message) throw new Error("Expected the incomplete stream to fail");
  }
});

Deno.test("Responses SSE parser enforces a bounded assembled output", async () => {
  const source = event("response.output_text.delta", {
    delta: "x".repeat(MAX_STREAMED_OUTPUT_CHARACTERS + 1),
  });
  let message = "";
  try {
    await readResponsesEventStream(streamChunks([source]));
  } catch (error) {
    message = error instanceof Error ? error.message : String(error);
  }
  assertEquals(message, "Meal analysis output exceeded its safe limit");
});
