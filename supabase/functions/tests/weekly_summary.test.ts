import {
  aggregateWeeklyEntries,
  priorCompletedWeekStart,
  safePriorCompletedWeekStart,
  WEEKLY_SUMMARY_MODEL,
} from "../_shared/weekly_summary.ts";
import { assertEquals } from "./assertions.ts";

Deno.test("weekly generation is pinned and chooses the completed local week", () => {
  assertEquals(WEEKLY_SUMMARY_MODEL, "gpt-5.6-sol");
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
