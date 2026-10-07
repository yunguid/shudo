import {
  analyzeMeal,
  MEAL_ANALYST_SYSTEM,
  MEAL_COMPONENT_PRESERVATION_INSTRUCTION,
  type MealResearchObservation,
  RESEARCH_STATUS_MESSAGES,
} from "../_shared/entry_processor.ts";
import { assert, assertEquals } from "./assertions.ts";
import {
  fakeClaude,
  jsonTextEvents,
  promptText,
  type RecordedRequest,
  type SSEEvent,
  submitToolEvents,
} from "./fake_claude.ts";

const SUBMIT = "submit_meal_analysis";

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
    totals: { protein_g: 25, carbs_g: 41, fat_g: 10, calories_kcal: 360 },
    confidence: 0.9,
    notes: "Official restaurant portions used.",
  };
}

function run(
  description: string,
  responses: Array<SSEEvent[] | number>,
  options: {
    requests?: RecordedRequest[];
    statuses?: string[];
    observations?: MealResearchObservation[];
  } = {},
) {
  return analyzeMeal(
    "user-id",
    description,
    null,
    null,
    () => Promise.resolve(),
    (message) => {
      options.statuses?.push(message);
      return Promise.resolve();
    },
    {
      client: fakeClaude(responses, options.requests ?? []),
      observeResearch: (observation) => options.observations?.push(observation),
    },
  );
}

Deno.test("explicit restaurant lookup grants web search and finishes through the strict submit tool", async () => {
  const requests: RecordedRequest[] = [];
  const result = await run(
    "Look up the restaurant's chicken burrito nutrition online and log it",
    [submitToolEvents(SUBMIT, validAnalysis(), {
      search: true,
      sources: ["https://restaurant.example/nutrition/chicken-burrito"],
    })],
    { requests },
  );

  assertEquals(requests.length, 1);
  const tools = requests[0].tools ?? [];
  assertEquals(tools[0].type, "web_search_20260209");
  assertEquals(tools[0].max_uses, 3);
  assertEquals(tools[1].name, SUBMIT);
  assertEquals(tools[1].strict, true);
  assertEquals(requests[0].output_config?.format, undefined);
  assertEquals(requests[0].model, "claude-sonnet-5-5");
  assert(
    promptText(requests[0]).includes("explicitly asked for an online lookup"),
  );
  assertEquals(result.research.used, true);
  assertEquals(result.research.sources.length, 1);
  assert(result.analysis.notes?.includes("restaurant.example"));
});

Deno.test("the exact Chipotle lookup searches and preserves white rice plus steak", async () => {
  const requests: RecordedRequest[] = [];
  const result = await run(
    "Look up a Chipotle bowl with white rice and steak.",
    [submitToolEvents(SUBMIT, chipotleAnalysis(), {
      search: true,
      sources: ["https://www.chipotle.com/nutrition"],
    })],
    { requests },
  );

  const prompt = promptText(requests[0]);
  assert(prompt.includes("white rice and steak"));
  assert(prompt.includes(MEAL_COMPONENT_PRESERVATION_INSTRUCTION));
  assert(MEAL_ANALYST_SYSTEM.includes("cooking oil"));
  assertEquals(
    result.analysis.items.map((item) => item.name),
    ["Cilantro-Lime White Rice", "Steak"],
  );
  assertEquals(result.research.sources, [{
    url: "https://www.chipotle.com/nutrition",
  }]);
});

Deno.test("brand-first restaurant context makes search available but optional", async () => {
  const requests: RecordedRequest[] = [];
  await run(
    "Chipotle bowl with white rice and steak",
    [submitToolEvents(SUBMIT, chipotleAnalysis())],
    { requests },
  );
  assertEquals(requests[0].tools?.[0].type, "web_search_20260209");
  assert(promptText(requests[0]).includes("Web search is available"));
});

Deno.test("ordinary meal logging stays on the tool-free JSON fast path", async () => {
  const requests: RecordedRequest[] = [];
  const observations: MealResearchObservation[] = [];
  const result = await run(
    "Chicken, rice, broccoli, and olive oil",
    [jsonTextEvents(validAnalysis())],
    { requests, observations },
  );

  assertEquals(requests.length, 1);
  assertEquals(requests[0].tools, undefined);
  assertEquals(
    (requests[0].output_config?.format as { type: string }).type,
    "json_schema",
  );
  assertEquals(result.research, {
    requested: false,
    used: false,
    degraded: false,
    sources: [],
  });
  assertEquals(result.analysis.title, "Chicken burrito");
  assertEquals(
    observations.map((observation) => observation.phase),
    ["routed", "completed"],
  );
  assertEquals(JSON.stringify(observations).includes("Chicken"), false);
});

Deno.test("failed web search retries without tools and preserves a labeled estimate", async () => {
  const requests: RecordedRequest[] = [];
  const result = await run(
    "Find the current nutrition for this restaurant menu item",
    [502, jsonTextEvents(validAnalysis())],
    { requests },
  );

  assertEquals(requests.length, 2);
  assertEquals(requests[0].tools?.length, 2);
  assertEquals(requests[1].tools, undefined);
  assert(promptText(requests[1]).includes("web search was unavailable"));
  assertEquals(result.research.degraded, true);
  assertEquals(result.analysis.confidence, 0.5);
  assert(result.analysis.notes?.includes("estimates rather than verified"));
});

Deno.test("an empty web search result remains structured and explicitly uncertain", async () => {
  const result = await run(
    "Look up this restaurant meal online",
    [submitToolEvents(SUBMIT, validAnalysis(), { search: true, sources: [] })],
  );
  assertEquals(result.research.used, true);
  assertEquals(result.research.sources, []);
  assertEquals(result.analysis.confidence, 0.5);
  assert(
    result.analysis.notes?.includes("No authoritative online nutrition source"),
  );
});

Deno.test("a researched meal narrates real search phases in stream order", async () => {
  const statuses: string[] = [];
  const observations: MealResearchObservation[] = [];
  const result = await run(
    "Look it up online for this restaurant burrito",
    [submitToolEvents(SUBMIT, validAnalysis(), {
      search: true,
      sources: ["https://restaurant.example/nutrition"],
    })],
    { statuses, observations },
  );

  assertEquals(statuses, [
    RESEARCH_STATUS_MESSAGES.searching,
    RESEARCH_STATUS_MESSAGES.reviewingSources,
    RESEARCH_STATUS_MESSAGES.calculating,
  ]);
  assertEquals(result.research.sources.length, 1);
  assertEquals(observations[1], {
    phase: "completed",
    requestedMode: "required",
    activeMode: "required",
    toolConfigured: true,
    toolCallObserved: true,
    degraded: false,
    sourceCount: 1,
  });
});

Deno.test("ordinary meals never receive research phase messages", async () => {
  const statuses: string[] = [];
  await run(
    "Chicken, rice, broccoli, and olive oil",
    [jsonTextEvents(validAnalysis())],
    { statuses },
  );
  assertEquals(statuses, []);
});

Deno.test("the degraded fallback announces the switch away from online lookup", async () => {
  const statuses: string[] = [];
  const result = await run(
    "Search online for this menu item's macros",
    [502, jsonTextEvents(validAnalysis())],
    { statuses },
  );
  assertEquals(statuses, [RESEARCH_STATUS_MESSAGES.estimatingWithoutSources]);
  assertEquals(result.research.degraded, true);
});

Deno.test("required lookup without an observed search is disclosed as unavailable", async () => {
  const result = await run(
    "Look up chicken nutrition",
    [submitToolEvents(SUBMIT, validAnalysis())],
  );
  assertEquals(result.research.used, false);
  assertEquals(result.research.degraded, true);
  assertEquals(result.analysis.confidence, 0.5);
  assert(result.analysis.notes?.includes("Online lookup was unavailable"));
});

Deno.test("a personified preview frame is skipped instead of failing the meal", async () => {
  const previews: string[] = [];
  const personified = {
    ...validAnalysis(),
    analysis_preview: "I estimate a chicken burrito with rice.",
  };
  const result = await analyzeMeal(
    "user-id",
    "chicken and rice wrapped in a tortilla",
    null,
    null,
    (preview) => {
      previews.push(preview);
      return Promise.resolve();
    },
    () => Promise.resolve(),
    { client: fakeClaude([jsonTextEvents(personified, { chunks: 6 })]) },
  );
  assertEquals(result.analysis.analysis_preview, result.analysis.title);
});
