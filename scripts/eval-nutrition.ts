/** Live synthetic eval; no Supabase reads/writes or personal meal data.
 * ANTHROPIC_API_KEY=... deno run --allow-env --allow-net=api.anthropic.com scripts/eval-nutrition.ts
 * Prints only synthetic case IDs, numeric scores, and research flags.
 */
import { analyzeMeal } from "../supabase/functions/_shared/entry_processor.ts";

type Case = {
  id: string;
  text: string;
  correction?: string;
  ranges: [number, number][]; // protein, carbs, fat, kcal
  question?: boolean;
  research?: boolean;
};
const cases: Case[] = [
  {
    id: "label_two_servings",
    text:
      "I ate 2 servings of a bar. Nutrition label per serving: protein 20g, carbs 23g, fat 7g, calories 200. Use this label.",
    ranges: [[40, 40], [46, 46], [14, 14], [400, 400]],
  },
  {
    id: "label_per_100g",
    text:
      "I ate 150g yogurt. The label per 100g says 10g protein, 4g carbs, 0g fat, 56 kcal.",
    ranges: [[15, 15], [6, 6], [0, 0], [84, 84]],
  },
  {
    id: "powder_not_protein",
    text:
      "One 30g scoop of powder. Label per 30g scoop: 24g protein, 3g carbs, 2g fat, 126 kcal.",
    ranges: [[24, 24], [3, 3], [2, 2], [126, 126]],
  },
  {
    id: "ounces_food_weight",
    text: "I ate 6 ounces of cooked skinless chicken breast, no oil or sauce.",
    ranges: [[45, 58], [0, 2], [3, 10], [240, 320]],
  },
  {
    id: "cooked_rice",
    text: "150g cooked white rice, plain, no oil.",
    ranges: [[3, 6], [38, 48], [0, 2], [170, 220]],
  },
  {
    id: "dry_rice",
    text:
      "I cooked and ate all of 150g dry white rice, weighed before cooking. No oil.",
    ranges: [[8, 14], [110, 130], [0, 3], [510, 580]],
  },
  {
    id: "newest_correction",
    text: "2 bars. Label per bar: 20g protein, 23g carbs, 7g fat, 200 kcal.",
    correction:
      "Actually I ate half of ONE bar, not two.\nOlder correction: I ate three bars.",
    ranges: [[10, 10], [11.5, 11.5], [3.5, 3.5], [100, 100]],
  },
  {
    id: "ambiguous_rice",
    text: "100g rice. I do not know if that was the dry or cooked weight.",
    ranges: [[1, 10], [20, 90], [0, 5], [100, 400]],
    question: true,
  },
  {
    id: "targeted_usda_lookup",
    text:
      "Look up USDA nutrition for 100g cooked roasted chicken breast, meat only, no oil. Use it for my meal.",
    ranges: [[27, 34], [0, 2], [2, 6], [145, 185]],
    research: true,
  },
];
let failures = 0;
for (const test of cases) {
  try {
    const started = Date.now();
    const result = await analyzeMeal(
      "synthetic-nutrition-eval",
      test.text,
      test.correction ?? null,
      null,
      async () => {},
      async () => {},
      { observeResearch: () => {} },
    );
    const totals = result.analysis.totals;
    const values = [
      totals.protein_g,
      totals.carbs_g,
      totals.fat_g,
      totals.calories_kcal,
    ];
    const numeric = values.every((value, index) =>
      value >= test.ranges[index][0] && value <= test.ranges[index][1]
    );
    const clarification = !test.question ||
      (result.analysis.notes?.includes("?") ?? false);
    const research = !test.research ||
      (result.research.used && !result.research.degraded &&
        result.research.sources.length > 0);
    const passed = numeric && clarification && research;
    if (!passed) failures++;
    console.log(
      JSON.stringify({
        id: test.id,
        passed,
        values,
        clarification,
        research,
        seconds: Math.round((Date.now() - started) / 1000),
      }),
    );
  } catch (error) {
    const status = /failed \((\d{3})\)/.exec(String(error))?.[1];
    if (status === "401" || status === "403") {
      console.log(
        JSON.stringify({
          blocked: true,
          httpStatus: Number(status),
          reason: "OpenAI credential rejected; no model results evaluated",
        }),
      );
      Deno.exit(2);
    }
    failures++;
    console.log(
      JSON.stringify({
        id: test.id,
        passed: false,
        error: "Request or validation failed",
      }),
    );
  }
}
console.log(JSON.stringify({ cases: cases.length, failures }));
if (failures) Deno.exit(1);
