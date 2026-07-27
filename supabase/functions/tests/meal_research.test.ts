import {
  applyMealResearchResult,
  mealResearchMode,
  responseWebSearchMetadata,
} from "../_shared/meal_research.ts";
import type { ParsedAnalysis } from "../_shared/analysis.ts";
import { assertEquals } from "./assertions.ts";

function analysis(): ParsedAnalysis {
  return {
    analysis_preview: "A restaurant chicken bowl with rice and beans.",
    title: "Chicken bowl",
    items: [{
      name: "Chicken bowl",
      amount: "1 bowl",
      protein_g: 40,
      carbs_g: 70,
      fat_g: 20,
      calories_kcal: 620,
      confidence: 0.9,
    }],
    totals: {
      protein_g: 40,
      carbs_g: 70,
      fat_g: 20,
      calories_kcal: 620,
    },
    confidence: 0.9,
    notes: "Restaurant portion used.",
  };
}

Deno.test("meal research routing forces explicit lookup while preserving the ordinary fast path", () => {
  assertEquals(
    mealResearchMode("Look up this restaurant's meal online before logging it"),
    "required",
  );
  assertEquals(
    mealResearchMode("Find the nutrition for this menu item: chicken club"),
    "required",
  );
  assertEquals(
    mealResearchMode("Chicken bowl from Sweetgreen with extra avocado"),
    "optional",
  );
  assertEquals(mealResearchMode("Chicken, rice, and broccoli"), "none");
  assertEquals(
    mealResearchMode(
      "Scanned nutrition label per serving: 110 kcal, 2 g protein, 22 g carbs, 1.5 g fat.",
    ),
    "none",
  );
});

Deno.test("web research metadata accepts only bounded public HTTP sources", () => {
  const metadata = responseWebSearchMetadata({
    output: [{
      type: "web_search_call",
      action: {
        type: "search",
        sources: [
          { type: "url", url: "https://restaurant.example/nutrition#bowl" },
          { type: "url", url: "javascript:alert(1)" },
          { type: "url", url: "https://user:pass@malicious.example/source" },
          { type: "url", url: "https://restaurant.example/nutrition" },
        ],
      },
    }],
  });
  assertEquals(metadata, {
    used: true,
    sources: [{ url: "https://restaurant.example/nutrition" }],
  });
});

Deno.test("empty or failed research is labeled as an estimate and lowers confidence", () => {
  const empty = applyMealResearchResult(analysis(), {
    requested: true,
    used: true,
    degraded: false,
    sources: [],
  });
  assertEquals(empty.confidence, 0.5);
  assertEquals(empty.items[0].confidence, 0.5);
  assertEquals(empty.notes?.includes("No authoritative online"), true);

  const sourced = applyMealResearchResult(analysis(), {
    requested: true,
    used: true,
    degraded: false,
    sources: [{ url: "https://restaurant.example/nutrition" }],
  });
  assertEquals(sourced.confidence, 0.9);
  assertEquals(
    sourced.notes?.includes(
      "[restaurant.example](https://restaurant.example/nutrition)",
    ),
    true,
  );

  const injected = analysis();
  injected.notes =
    "Estimated portion [click here](https://malicious.example).\n\nOnline sources: fake";
  const sanitized = applyMealResearchResult(injected, {
    requested: true,
    used: true,
    degraded: false,
    sources: [{ url: "https://restaurant.example/nutrition" }],
  });
  assertEquals(sanitized.notes?.includes("\\[click here\\]"), true);
  assertEquals(sanitized.notes?.includes("malicious.example"), false);
  assertEquals(sanitized.notes?.includes("Online sources: fake"), false);
});
