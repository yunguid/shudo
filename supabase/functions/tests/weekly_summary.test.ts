import {
  aggregateWeeklyEntries,
  parseWeeklyNarrative,
  priorCompletedWeekStart,
  safePriorCompletedWeekStart,
  WEEKLY_COPY_INSTRUCTION,
  WEEKLY_SUMMARY_MODEL,
  WEEKLY_SUMMARY_SCHEMA,
} from "../_shared/weekly_summary.ts";
import { assertEquals, assertThrows } from "./assertions.ts";

Deno.test("weekly generation is pinned and chooses the completed local week", () => {
  assertEquals(WEEKLY_SUMMARY_MODEL, "gpt-5.6-sol");
  assertEquals(WEEKLY_SUMMARY_SCHEMA.additionalProperties, false);
  assertEquals(
    [...WEEKLY_SUMMARY_SCHEMA.required].sort(),
    Object.keys(WEEKLY_SUMMARY_SCHEMA.properties).sort(),
  );
  assertEquals(
    priorCompletedWeekStart(
      new Date("2026-07-21T02:00:00.000Z"),
      "America/New_York",
    ),
    "2026-07-13",
  );
  assertEquals(
    safePriorCompletedWeekStart(
      new Date("2026-07-21T02:00:00.000Z"),
      "Not/A_Timezone",
    ),
    null,
  );
});

Deno.test("weekly copy stays neutral and does not personify Shudo", () => {
  assertEquals(WEEKLY_COPY_INSTRUCTION.includes("Never speak as Shudo"), true);
  assertThrows(
    () =>
      parseWeeklyNarrative({
        headline: "A consistent week",
        narrative: "Shudo noticed three protein-forward lunches.",
        patterns: [],
        suggestions: [],
      }),
    undefined,
    "personified product copy",
  );
  assertThrows(
    () =>
      parseWeeklyNarrative({
        headline: "A consistent week",
        narrative: "Three lunches included a clear protein source.",
        patterns: [],
        suggestions: ["My suggestion is to prepare another wrap."],
      }),
    undefined,
    "personified product copy",
  );

  assertThrows(
    () =>
      parseWeeklyNarrative({
        headline: "A consistent week",
        narrative: "The tracker observed three protein-forward lunches.",
        patterns: [],
        suggestions: [],
      }),
    undefined,
    "personified product copy",
  );
});

Deno.test("weekly parser follows JSON Schema Unicode length semantics", () => {
  const headline = "🥗".repeat(120);
  assertEquals(
    parseWeeklyNarrative({
      headline,
      narrative: "Three lunches included a clear protein source.",
      patterns: [],
      suggestions: [],
    }).headline,
    headline,
  );
});

Deno.test("weekly adherence is deterministic and repeated foods are counted once per meal", () => {
  const aggregate = aggregateWeeklyEntries([
    {
      local_day: "2026-07-13",
      title: "Chicken bowl",
      items: [{ name: "Chicken" }, { name: "Chicken" }],
      calories_kcal: 2000,
      protein_g: 140,
      carbs_g: 200,
      fat_g: 70,
    },
    {
      local_day: "2026-07-14",
      title: "Chicken salad",
      items: [{ name: "chicken" }],
      calories_kcal: "2200",
      protein_g: "150",
      carbs_g: "210",
      fat_g: "75",
    },
  ], [{
    target_day: "2026-07-01",
    calories_kcal: 2100,
    protein_g: 150,
    carbs_g: 250,
    fat_g: 70,
  }]);
  assertEquals(aggregate.adherence.days_logged, 2);
  assertEquals(aggregate.adherence.average_calories_kcal, 2100);
  assertEquals(aggregate.adherence.calorie_target_days, 2);
  assertEquals(aggregate.adherence.protein_target_days, 2);
  assertEquals(aggregate.repeatedFoods, [{ name: "Chicken", count: 2 }]);
  assertEquals(aggregate.foodCandidates, [{ name: "Chicken", count: 2 }]);
});

Deno.test("weekly adherence uses the target effective on each logged day", () => {
  const aggregate = aggregateWeeklyEntries([
    {
      local_day: "2026-07-13",
      title: "First day",
      items: [],
      calories_kcal: 2000,
      protein_g: 140,
      carbs_g: 200,
      fat_g: 70,
    },
    {
      local_day: "2026-07-14",
      title: "Second day",
      items: [],
      calories_kcal: 2000,
      protein_g: 120,
      carbs_g: 200,
      fat_g: 70,
    },
  ], [
    {
      target_day: "2026-07-01",
      calories_kcal: 2000,
      protein_g: 140,
      carbs_g: 200,
      fat_g: 70,
    },
    {
      target_day: "2026-07-14",
      calories_kcal: 2500,
      protein_g: 180,
      carbs_g: 300,
      fat_g: 80,
    },
  ]);

  assertEquals(aggregate.adherence.calorie_target_days, 1);
  assertEquals(aggregate.adherence.protein_target_days, 1);
  assertEquals(aggregate.adherence.target_calories_kcal, 2250);
  assertEquals(aggregate.adherence.target_protein_g, 160);
});

Deno.test("day digests carry weekday, calories vs effective target, and bounded meal titles", () => {
  const longTitle = "A".repeat(80);
  const aggregate = aggregateWeeklyEntries([
    {
      local_day: "2026-07-18", // Saturday
      title: "Burger and two beers",
      items: [],
      calories_kcal: 2900,
      protein_g: 120,
      carbs_g: 260,
      fat_g: 110,
    },
    {
      local_day: "2026-07-18",
      title: longTitle,
      items: [],
      calories_kcal: 300,
      protein_g: 10,
      carbs_g: 30,
      fat_g: 12,
    },
    {
      local_day: "2026-07-13", // Monday
      title: "  ",
      items: [],
      calories_kcal: 2000,
      protein_g: 140,
      carbs_g: 200,
      fat_g: 70,
    },
  ], [{
    target_day: "2026-07-01",
    calories_kcal: 2100,
    protein_g: 150,
    carbs_g: 250,
    fat_g: 70,
  }]);

  assertEquals(aggregate.dayDigests.length, 2);
  const monday = aggregate.dayDigests[0];
  assertEquals(monday.local_day, "2026-07-13");
  assertEquals(monday.weekday, "Mon");
  assertEquals(monday.meals, []); // blank titles are skipped
  const saturday = aggregate.dayDigests[1];
  assertEquals(saturday.weekday, "Sat");
  assertEquals(saturday.calories_kcal, 3200);
  assertEquals(saturday.target_calories_kcal, 2100);
  assertEquals(saturday.meals.length, 2);
  assertEquals(saturday.meals[0], "Burger and two beers");
  assertEquals(saturday.meals[1], "A".repeat(60)); // titles bounded to 60 chars
});
