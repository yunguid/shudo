import {
  assertNeutralGeneratedCopy,
  NEUTRAL_PRODUCT_COPY_INSTRUCTION,
} from "../_shared/generated_copy.ts";
import { assertEquals, assertThrows } from "./assertions.ts";

Deno.test("neutral generated-copy policy accepts direct product copy", () => {
  assertEquals(
    assertNeutralGeneratedCopy(
      "Three lunches included a clear protein source.",
      "summary",
    ),
    "Three lunches included a clear protein source.",
  );
  assertEquals(
    assertNeutralGeneratedCopy(
      "Toast with I Can't Believe It's Not Butter.",
      "meal title",
    ),
    "Toast with I Can't Believe It's Not Butter.",
  );
  assertEquals(NEUTRAL_PRODUCT_COPY_INSTRUCTION.includes("I/we/my/our"), true);
});

Deno.test("neutral generated-copy policy rejects product speakers", () => {
  for (
    const value of [
      "Shudo observed three similar lunches.",
      "Our estimate is 2,100 calories.",
      "My recommendation is to prepare another wrap.",
      "The app noticed a repeated pattern.",
    ]
  ) {
    assertThrows(
      () => assertNeutralGeneratedCopy(value, "summary"),
      undefined,
      "personified product copy",
    );
  }
});
