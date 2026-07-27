import { analyzeMeal } from "../_shared/entry_processor.ts";
import { assert, assertEquals } from "./assertions.ts";

function validAnalysis() {
  return {
    analysis_preview: "A chicken burrito with rice, beans, and salsa.",
    title: "Chicken burrito",
    items: [{
      name: "Chicken burrito",
      amount: "1 burrito",
      protein_g: 45,
      carbs_g: 90,
      fat_g: 25,
      calories_kcal: 760,
      confidence: 0.9,
    }],
    totals: {
      protein_g: 45,
      carbs_g: 90,
      fat_g: 25,
      calories_kcal: 760,
    },
    confidence: 0.9,
    notes: "Official restaurant values used where available.",
  };
}

function completedStream(options: {
  responseId: string;
  webSearch?: boolean;
  sources?: string[];
}): Response {
  const output: Array<Record<string, unknown>> = [];
  if (options.webSearch) {
    output.push({
      type: "web_search_call",
      id: "ws_test",
      status: "completed",
      action: {
        type: "search",
        queries: ["restaurant chicken burrito nutrition"],
        sources: (options.sources ?? []).map((url) => ({ type: "url", url })),
      },
    });
  }
  output.push({
    type: "message",
    content: [{
      type: "output_text",
      text: JSON.stringify(validAnalysis()),
      annotations: [],
    }],
  });
  const type = "response.completed";
  const event = `event: ${type}\ndata: ${
    JSON.stringify({
      type,
      response: {
        id: options.responseId,
        status: "completed",
        output,
      },
    })
  }\n\n`;
  return new Response(event, {
    status: 200,
    headers: { "content-type": "text/event-stream" },
  });
}

function testDependencies(fetchMock: typeof fetch) {
  return {
    fetch: fetchMock,
    apiKey: "test-key-not-a-secret",
    safetyIdentifier: () => Promise.resolve("shudo_test"),
  };
}

Deno.test("explicit restaurant lookup grants and requires hosted web search in the structured meal call", async () => {
  const requests: Array<Record<string, unknown>> = [];
  const fetchMock = ((_input: URL | Request | string, init?: RequestInit) => {
    requests.push(JSON.parse(String(init?.body)));
    return Promise.resolve(completedStream({
      responseId: "resp_researched",
      webSearch: true,
      sources: ["https://restaurant.example/nutrition/chicken-burrito"],
    }));
  }) as typeof fetch;

  const result = await analyzeMeal(
    "user-id",
    "Look up the restaurant's chicken burrito nutrition online and log it",
    null,
    null,
    () => Promise.resolve(),
    testDependencies(fetchMock),
  );

  assertEquals(requests.length, 1);
  assertEquals(requests[0].tools, [{
    type: "web_search",
    search_context_size: "low",
  }]);
  assertEquals(requests[0].tool_choice, "required");
  assertEquals(requests[0].max_tool_calls, 2);
  assertEquals(requests[0].include, ["web_search_call.action.sources"]);
  const text = requests[0].text as Record<string, unknown>;
  assertEquals(
    (text.format as Record<string, unknown>).name,
    "shudo_meal_analysis",
  );
  assertEquals(result.responseId, "resp_researched");
  assertEquals(result.research.used, true);
  assertEquals(result.research.sources.length, 1);
  assert(result.analysis.notes?.includes("restaurant.example"));
});

Deno.test("ordinary meal logging stays on the tool-free fast path", async () => {
  const requests: Array<Record<string, unknown>> = [];
  const fetchMock = ((_input: URL | Request | string, init?: RequestInit) => {
    requests.push(JSON.parse(String(init?.body)));
    return Promise.resolve(completedStream({ responseId: "resp_ordinary" }));
  }) as typeof fetch;

  const result = await analyzeMeal(
    "user-id",
    "Chicken, rice, broccoli, and olive oil",
    null,
    null,
    () => Promise.resolve(),
    testDependencies(fetchMock),
  );

  assertEquals(requests.length, 1);
  assertEquals("tools" in requests[0], false);
  assertEquals("tool_choice" in requests[0], false);
  assertEquals("include" in requests[0], false);
  assertEquals(result.research, {
    requested: false,
    used: false,
    degraded: false,
    sources: [],
  });
  assertEquals(result.analysis.title, "Chicken burrito");
});

Deno.test("failed web search retries without tools and preserves a labeled structured estimate", async () => {
  const requests: Array<Record<string, unknown>> = [];
  const fetchMock = ((_input: URL | Request | string, init?: RequestInit) => {
    requests.push(JSON.parse(String(init?.body)));
    return Promise.resolve(
      requests.length === 1
        ? new Response(null, { status: 502 })
        : completedStream({ responseId: "resp_fallback" }),
    );
  }) as typeof fetch;

  const result = await analyzeMeal(
    "user-id",
    "Find the current nutrition for this restaurant menu item",
    null,
    null,
    () => Promise.resolve(),
    testDependencies(fetchMock),
  );

  assertEquals(requests.length, 2);
  assertEquals(requests[0].tool_choice, "required");
  assertEquals("tools" in requests[1], false);
  const fallbackInput = requests[1].input as Array<Record<string, unknown>>;
  const fallbackContent = fallbackInput[0].content as Array<
    Record<string, unknown>
  >;
  assertEquals(
    String(fallbackContent[0].text).includes("web search was unavailable"),
    true,
  );
  assertEquals(result.responseId, "resp_fallback");
  assertEquals(result.research.degraded, true);
  assertEquals(result.analysis.confidence, 0.5);
  assertEquals(
    result.analysis.notes?.includes("estimates rather than verified"),
    true,
  );
});

Deno.test("an empty web search result remains structured and explicitly uncertain", async () => {
  const fetchMock = (() =>
    Promise.resolve(completedStream({
      responseId: "resp_empty_search",
      webSearch: true,
      sources: [],
    }))) as typeof fetch;

  const result = await analyzeMeal(
    "user-id",
    "Look up this restaurant meal online",
    null,
    null,
    () => Promise.resolve(),
    testDependencies(fetchMock),
  );

  assertEquals(result.research.used, true);
  assertEquals(result.research.sources, []);
  assertEquals(result.analysis.title, "Chicken burrito");
  assertEquals(result.analysis.confidence, 0.5);
  assertEquals(
    result.analysis.notes?.includes("No authoritative online nutrition source"),
    true,
  );
});
