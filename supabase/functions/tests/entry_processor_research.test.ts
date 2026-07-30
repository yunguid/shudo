import {
  analyzeMeal,
  MEAL_COMPONENT_PRESERVATION_INSTRUCTION,
  type MealResearchObservation,
  RESEARCH_STATUS_MESSAGES,
  TRANSCRIPTION_PROMPT,
} from "../_shared/entry_processor.ts";
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

function chipotleAnalysis() {
  return {
    analysis_preview: "A Chipotle bowl with white rice and steak.",
    title: "Chipotle steak bowl",
    items: [
      {
        name: "Cilantro-Lime White Rice",
        amount: "4 oz",
        protein_g: 4,
        carbs_g: 40,
        fat_g: 4,
        calories_kcal: 210,
        confidence: 0.9,
      },
      {
        name: "Steak",
        amount: "4 oz",
        protein_g: 21,
        carbs_g: 1,
        fat_g: 6,
        calories_kcal: 150,
        confidence: 0.9,
      },
    ],
    totals: {
      protein_g: 25,
      carbs_g: 41,
      fat_g: 10,
      calories_kcal: 360,
    },
    confidence: 0.9,
    notes: "Official restaurant portions used.",
  };
}

function completedStream(options: {
  responseId: string;
  webSearch?: boolean;
  sources?: string[];
  analysis?:
    | ReturnType<typeof validAnalysis>
    | ReturnType<typeof chipotleAnalysis>;
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
      text: JSON.stringify(options.analysis ?? validAnalysis()),
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

/**
 * A stream that reports the search lifecycle the way the provider actually
 * does — search begins, search completes, then structured output streams —
 * so phase-status assertions run against realistic event ordering.
 */
function researchLifecycleStream(options: {
  responseId: string;
  sources?: string[];
}): Response {
  const searchCall = {
    type: "web_search_call",
    id: "ws_live",
    status: "completed",
    action: {
      type: "search",
      queries: ["restaurant chicken burrito nutrition"],
      sources: (options.sources ?? []).map((url) => ({ type: "url", url })),
    },
  };
  const outputJSON = JSON.stringify(validAnalysis());
  const events: Array<Record<string, unknown>> = [
    { type: "response.web_search_call.in_progress", item_id: "ws_live" },
    { type: "response.web_search_call.searching", item_id: "ws_live" },
    { type: "response.web_search_call.completed", item_id: "ws_live" },
    { type: "response.output_item.done", item: searchCall },
    { type: "response.output_text.delta", delta: outputJSON },
    {
      type: "response.completed",
      response: {
        id: options.responseId,
        status: "completed",
        output: [
          searchCall,
          {
            type: "message",
            content: [
              { type: "output_text", text: outputJSON, annotations: [] },
            ],
          },
        ],
      },
    },
  ];
  const body = events
    .map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`)
    .join("");
  return new Response(body, {
    status: 200,
    headers: { "content-type": "text/event-stream" },
  });
}

function testDependencies(
  fetchMock: typeof fetch,
  observeResearch?: (observation: MealResearchObservation) => void,
) {
  return {
    fetch: fetchMock,
    apiKey: "test-key-not-a-secret",
    safetyIdentifier: () => Promise.resolve("shudo_test"),
    observeResearch: observeResearch ?? (() => undefined),
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

Deno.test("the exact Chipotle lookup forces search and preserves white rice plus steak", async () => {
  const requests: Array<Record<string, unknown>> = [];
  const fetchMock = ((_input: URL | Request | string, init?: RequestInit) => {
    requests.push(JSON.parse(String(init?.body)));
    return Promise.resolve(completedStream({
      responseId: "resp_chipotle_regression",
      webSearch: true,
      sources: ["https://www.chipotle.com/nutrition"],
      analysis: chipotleAnalysis(),
    }));
  }) as typeof fetch;

  const result = await analyzeMeal(
    "synthetic-user-id",
    "Look up a Chipotle bowl with white rice and steak.",
    null,
    null,
    () => Promise.resolve(),
    () => Promise.resolve(),
    testDependencies(fetchMock),
  );

  assertEquals(requests.length, 1);
  assertEquals(requests[0].tool_choice, "required");
  const input = requests[0].input as Array<Record<string, unknown>>;
  const content = input[0].content as Array<Record<string, unknown>>;
  const prompt = String(content[0].text);
  assert(prompt.includes("white rice and steak"));
  assert(prompt.includes(MEAL_COMPONENT_PRESERVATION_INSTRUCTION));
  assert(
    TRANSCRIPTION_PROMPT.includes(
      "explicit lookup, search, or online-research intent",
    ),
  );
  assert(TRANSCRIPTION_PROMPT.includes("every stated food"));
  assertEquals(
    result.analysis.items.map((item) => item.name),
    ["Cilantro-Lime White Rice", "Steak"],
  );
  assertEquals(result.research.used, true);
  assertEquals(result.research.sources, [{
    url: "https://www.chipotle.com/nutrition",
  }]);
});

Deno.test("brand-first restaurant context makes hosted search available but optional", async () => {
  const requests: Array<Record<string, unknown>> = [];
  const fetchMock = ((_input: URL | Request | string, init?: RequestInit) => {
    requests.push(JSON.parse(String(init?.body)));
    return Promise.resolve(completedStream({
      responseId: "resp_chipotle_context",
      analysis: chipotleAnalysis(),
    }));
  }) as typeof fetch;

  await analyzeMeal(
    "synthetic-user-id",
    "Chipotle bowl with white rice and steak",
    null,
    null,
    () => Promise.resolve(),
    () => Promise.resolve(),
    testDependencies(fetchMock),
  );

  assertEquals(requests[0].tools, [{
    type: "web_search",
    search_context_size: "low",
  }]);
  assertEquals(requests[0].tool_choice, "auto");
});

Deno.test("ordinary meal logging stays on the tool-free fast path", async () => {
  const requests: Array<Record<string, unknown>> = [];
  const observations: MealResearchObservation[] = [];
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
    () => Promise.resolve(),
    testDependencies(
      fetchMock,
      (observation) => observations.push(observation),
    ),
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
  assertEquals(
    observations.map((observation) => ({
      phase: observation.phase,
      requestedMode: observation.requestedMode,
      toolConfigured: observation.toolConfigured,
      toolCallObserved: observation.toolCallObserved,
    })),
    [
      {
        phase: "routed",
        requestedMode: "none",
        toolConfigured: false,
        toolCallObserved: false,
      },
      {
        phase: "completed",
        requestedMode: "none",
        toolConfigured: false,
        toolCallObserved: false,
      },
    ],
  );
  assertEquals(JSON.stringify(observations).includes("Chicken"), false);
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

Deno.test("a researched meal narrates real search phases in stream order", async () => {
  const fetchMock = (() =>
    Promise.resolve(researchLifecycleStream({
      responseId: "resp_phases",
      sources: ["https://restaurant.example/nutrition"],
    }))) as typeof fetch;
  const statusMessages: string[] = [];
  const observations: MealResearchObservation[] = [];

  const result = await analyzeMeal(
    "user-id",
    "Look it up online for this restaurant burrito",
    null,
    null,
    () => Promise.resolve(),
    (message) => {
      statusMessages.push(message);
      return Promise.resolve();
    },
    testDependencies(
      fetchMock,
      (observation) => observations.push(observation),
    ),
  );

  assertEquals(statusMessages, [
    RESEARCH_STATUS_MESSAGES.searching,
    RESEARCH_STATUS_MESSAGES.reviewingSources,
    RESEARCH_STATUS_MESSAGES.calculating,
  ]);
  assertEquals(result.research.used, true);
  assertEquals(result.research.sources.length, 1);
  assertEquals(observations, [
    {
      phase: "routed",
      requestedMode: "required",
      activeMode: "required",
      toolConfigured: true,
      toolCallObserved: false,
      degraded: false,
      sourceCount: 0,
    },
    {
      phase: "completed",
      requestedMode: "required",
      activeMode: "required",
      toolConfigured: true,
      toolCallObserved: true,
      degraded: false,
      sourceCount: 1,
    },
  ]);
});

Deno.test("ordinary meals never receive research phase messages", async () => {
  const fetchMock = (() =>
    Promise.resolve(
      completedStream({ responseId: "resp_plain" }),
    )) as typeof fetch;
  const statusMessages: string[] = [];

  await analyzeMeal(
    "user-id",
    "Chicken, rice, broccoli, and olive oil",
    null,
    null,
    () => Promise.resolve(),
    (message) => {
      statusMessages.push(message);
      return Promise.resolve();
    },
    testDependencies(fetchMock),
  );

  assertEquals(statusMessages, []);
});

Deno.test("the degraded fallback announces the switch away from online lookup", async () => {
  const requests: Array<Record<string, unknown>> = [];
  const fetchMock = ((_input: URL | Request | string, init?: RequestInit) => {
    requests.push(JSON.parse(String(init?.body)));
    return Promise.resolve(
      requests.length === 1
        ? new Response(null, { status: 502 })
        : completedStream({ responseId: "resp_degraded_status" }),
    );
  }) as typeof fetch;
  const statusMessages: string[] = [];

  const result = await analyzeMeal(
    "user-id",
    "Search online for this menu item's macros",
    null,
    null,
    () => Promise.resolve(),
    (message) => {
      statusMessages.push(message);
      return Promise.resolve();
    },
    testDependencies(fetchMock),
  );

  assertEquals(statusMessages, [
    RESEARCH_STATUS_MESSAGES.estimatingWithoutSources,
  ]);
  assertEquals(result.research.degraded, true);
});
