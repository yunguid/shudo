import {
  ANALYSIS_TIMEOUT_MS,
  PROCESSING_BUDGET_MS,
  PROCESSING_OVERHEAD_RESERVE_MS,
  TRANSCRIPTION_TIMEOUT_MS,
} from "../_shared/entry_processor.ts";
import { assertEquals } from "./assertions.ts";

Deno.test("OpenAI request timeouts preserve worker overhead inside the processing budget", () => {
  assertEquals(TRANSCRIPTION_TIMEOUT_MS, 60_000);
  assertEquals(
    TRANSCRIPTION_TIMEOUT_MS + ANALYSIS_TIMEOUT_MS +
      PROCESSING_OVERHEAD_RESERVE_MS,
    PROCESSING_BUDGET_MS,
  );
});
