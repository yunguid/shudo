import {
  ANALYSIS_MODEL,
  ANALYSIS_TIMEOUT_MS,
  MEAL_COPY_INSTRUCTION,
  PROCESSING_BUDGET_MS,
  PROCESSING_OVERHEAD_RESERVE_MS,
  TRANSCRIPTION_TIMEOUT_MS,
} from "../_shared/entry_processor.ts";
import {
  ANALYSIS_PREVIEW_MAX_CHARACTERS,
  RESULT_SCHEMA,
} from "../_shared/analysis.ts";
import { ANALYSIS_PREVIEW_UPDATE_INTERVAL_MS } from "../_shared/analysis_preview.ts";
import { MAX_STREAMED_OUTPUT_CHARACTERS } from "../_shared/responses_stream.ts";
import { assertEquals } from "./assertions.ts";

Deno.test("OpenAI request timeouts preserve worker overhead inside the processing budget", () => {
  assertEquals(ANALYSIS_MODEL, "gpt-5.6-sol");
  assertEquals(MEAL_COPY_INSTRUCTION.includes("Never speak as Shudo"), true);
  assertEquals(TRANSCRIPTION_TIMEOUT_MS, 60_000);
  assertEquals(
    TRANSCRIPTION_TIMEOUT_MS + ANALYSIS_TIMEOUT_MS +
      PROCESSING_OVERHEAD_RESERVE_MS,
    PROCESSING_BUDGET_MS,
  );
});

Deno.test("streaming analysis remains bounded in memory and database write rate", () => {
  assertEquals(ANALYSIS_PREVIEW_MAX_CHARACTERS, 240);
  assertEquals(RESULT_SCHEMA.properties.analysis_preview.maxLength, 240);
  // Matches the app's streaming poll cadence (TodayViewModel
  // streamingPreviewPollingInterval, 650 ms) so no preview write is published
  // faster than any client will ever read it.
  assertEquals(ANALYSIS_PREVIEW_UPDATE_INTERVAL_MS, 650);
  assertEquals(MAX_STREAMED_OUTPUT_CHARACTERS, 40_000);
});
