import {
  assertCardCopy,
  CardCopyViolation,
  guardedCopy,
} from "../_shared/card_copy.ts";
import { assert, assertEquals } from "./assertions.ts";

function code(text: string, profanity: "off" | "mild" | "salty" = "off"): string | null {
  try {
    assertCardCopy(text, "field", { maxChars: 200, profanity });
    return null;
  } catch (error) {
    if (error instanceof CardCopyViolation) return error.code;
    throw error;
  }
}

Deno.test("coach card copy in the persona voice passes", () => {
  assertEquals(
    assertCardCopy(
      "  7-Eleven's a 2-min walk. Core Power should have you covered.  ",
      "headline",
      { maxChars: 120 },
    ),
    "7-Eleven's a 2-min walk. Core Power should have you covered.",
  );
  assertEquals(code("Four days, upper/lower, about 60 minutes. I built it around your 9:30 start."), null);
  assertEquals(code("Rows up 10 lb. Damn.", "mild"), null);
});

Deno.test("the guard rejects unsafe or off-voice card copy", () => {
  assertEquals(code("Let's go!"), "exclamation");
  assertEquals(code("Details at https://example.com"), "url");
  assertEquals(code("Nice work 🔥"), "emoji");
  assertEquals(code("Skip dinner and you'll lean out."), "extreme_diet");
  assertEquals(code("Burn it off tomorrow."), "extreme_diet");
  assertEquals(code("You look soft in this one."), "body_shaming");
  assertEquals(code("Looking flabby around the middle."), "body_shaming");
  assertEquals(code("You're around 15% body fat."), "body_fat_guess");
  assertEquals(code("Ask your doctor about TRT."), "medical");
  assertEquals(code("That's very alpha male of you."), "politics");
  assertEquals(code("Good set, bro."), "address");
  assertEquals(code("You got this."), "cliche");
  assertEquals(code("Rows up 10 lb. Damn."), "profanity");
  assertEquals(code("What the fuck was that set.", "mild"), "profanity");
  assertEquals(code("- bench\n- rows"), "markdown");
  assertEquals(code("x".repeat(201)), "length");
});

Deno.test("guardedCopy falls back on violations and non-strings", () => {
  const options = { maxChars: 50 };
  assertEquals(guardedCopy(assertCardCopy, "Fine copy.", "f", options, "fb"), "Fine copy.");
  assertEquals(guardedCopy(assertCardCopy, "Go!", "f", options, "fb"), "fb");
  assertEquals(guardedCopy(assertCardCopy, 42, "f", options, "fb"), "fb");
  // An injected guard (e.g. the coach lane's assertCoachCopy) is honored.
  let called = false;
  const custom = (text: string) => {
    called = true;
    return text.toUpperCase();
  };
  assertEquals(guardedCopy(custom, "ok", "f", options, "fb"), "OK");
  assert(called);
});
