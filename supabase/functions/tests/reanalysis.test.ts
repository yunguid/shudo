import {
  MAX_REANALYSIS_CONTEXT_CHARACTERS,
  parseReanalysisRequest,
} from "../_shared/reanalysis.ts";
import { assertEquals, assertThrows } from "./assertions.ts";

Deno.test("reanalysis request normalizes the stable mobile contract", () => {
  assertEquals(
    parseReanalysisRequest({
      entry_id: "10000000-0000-4000-8000-000000000001",
      context: "  It was two servings, not one.  ",
    }),
    {
      entryId: "10000000-0000-4000-8000-000000000001",
      context: "It was two servings, not one.",
    },
  );
});

Deno.test("reanalysis rejects missing or oversized correction context", () => {
  assertThrows(
    () =>
      parseReanalysisRequest({
        entry_id: "10000000-0000-4000-8000-000000000001",
        context: "  ",
      }),
    400,
    "context is required",
  );
  assertThrows(
    () =>
      parseReanalysisRequest({
        entry_id: "10000000-0000-4000-8000-000000000001",
        context: "x".repeat(MAX_REANALYSIS_CONTEXT_CHARACTERS + 1),
      }),
    413,
  );
});
