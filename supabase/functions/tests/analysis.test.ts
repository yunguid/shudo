import {
  parseAnalysis,
  responseOutputText,
  RESULT_SCHEMA,
} from "../_shared/analysis.ts";
import { assertEquals, assertThrows } from "./assertions.ts";

function validAnalysis(): Record<string, unknown> {
  return {
    title: "  Chicken rice bowl  ",
    items: [{
      name: " Chicken breast ",
      amount: " 6 oz ",
      protein_g: 52.04,
      carbs_g: 0,
      fat_g: 6.26,
      calories_kcal: 280.05,
      confidence: 0.91,
    }],
    totals: {
      protein_g: 52.04,
      carbs_g: 44.95,
      fat_g: 9.96,
      calories_kcal: 493.04,
    },
    confidence: 0.87,
    notes: "  Portion estimated from the photo.  ",
  };
}

Deno.test("meal analysis schema remains strict and fully required", () => {
  assertEquals(RESULT_SCHEMA.additionalProperties, false);
  assertEquals(RESULT_SCHEMA.required, [
    "title",
    "items",
    "totals",
    "confidence",
    "notes",
  ]);
  assertEquals(RESULT_SCHEMA.properties.items.maxItems, 30);
  assertEquals(
    RESULT_SCHEMA.properties.items.items.additionalProperties,
    false,
  );
  assertEquals(RESULT_SCHEMA.properties.totals.additionalProperties, false);
});

Deno.test("analysis parser validates and normalizes the complete payload", () => {
  const parsed = parseAnalysis(validAnalysis());
  assertEquals(parsed, {
    title: "Chicken rice bowl",
    items: [{
      name: "Chicken breast",
      amount: "6 oz",
      protein_g: 52,
      carbs_g: 0,
      fat_g: 6.3,
      calories_kcal: 280.1,
      confidence: 0.9,
    }],
    totals: {
      protein_g: 52,
      carbs_g: 45,
      fat_g: 10,
      calories_kcal: 493,
    },
    confidence: 0.9,
    notes: "Portion estimated from the photo.",
  });
});

Deno.test("Responses output text supports convenience and nested shapes", () => {
  assertEquals(
    responseOutputText({ output_text: '{"title":"Meal"}' }),
    '{"title":"Meal"}',
  );
  assertEquals(
    responseOutputText({
      output_text: "",
      output: [
        { content: [{ type: "reasoning" }, { text: '{"title":' }] },
        { content: [{ text: '"Meal"}' }] },
      ],
    }),
    '{"title":"Meal"}',
  );
  assertEquals(responseOutputText({ output: "not-an-array" }), "");
});

Deno.test("analysis parser rejects malformed totals and confidence", () => {
  const negative = validAnalysis();
  (negative.totals as Record<string, unknown>).protein_g = -1;
  assertThrows(() => parseAnalysis(negative), undefined, "protein_g");

  const numericString = validAnalysis();
  (numericString.totals as Record<string, unknown>).calories_kcal = "493";
  assertThrows(() => parseAnalysis(numericString), undefined, "calories_kcal");

  const overconfident = validAnalysis();
  overconfident.confidence = 1.04;
  assertThrows(() => parseAnalysis(overconfident), undefined, "confidence");
});

Deno.test("analysis parser rejects malformed structured items", () => {
  const missingName = validAnalysis();
  delete (missingName.items as Array<Record<string, unknown>>)[0].name;
  assertThrows(() => parseAnalysis(missingName), undefined, "items[0].name");

  const negativeMacro = validAnalysis();
  (negativeMacro.items as Array<Record<string, unknown>>)[0].fat_g = -0.1;
  assertThrows(() => parseAnalysis(negativeMacro), undefined, "items[0].fat_g");

  const overconfident = validAnalysis();
  (overconfident.items as Array<Record<string, unknown>>)[0].confidence = 2;
  assertThrows(
    () => parseAnalysis(overconfident),
    undefined,
    "items[0].confidence",
  );

  const tooMany = validAnalysis();
  tooMany.items = Array.from(
    { length: 31 },
    () => (validAnalysis().items as unknown[])[0],
  );
  assertThrows(() => parseAnalysis(tooMany), undefined, "items were invalid");
});

Deno.test("analysis parser rejects missing or mistyped required fields", () => {
  assertThrows(() => parseAnalysis([]), undefined, "not an object");

  const missingItems = validAnalysis();
  delete missingItems.items;
  assertThrows(
    () => parseAnalysis(missingItems),
    undefined,
    "items were invalid",
  );

  const longTitle = validAnalysis();
  longTitle.title = "x".repeat(121);
  assertThrows(() => parseAnalysis(longTitle), undefined, "title");

  const missingNotes = validAnalysis();
  delete missingNotes.notes;
  assertThrows(
    () => parseAnalysis(missingNotes),
    undefined,
    "notes were missing",
  );

  const invalidNotes = validAnalysis();
  invalidNotes.notes = { text: "not a string" };
  assertThrows(() => parseAnalysis(invalidNotes), undefined, "notes");
});
