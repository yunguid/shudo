import {
  ANALYSIS_TIMEOUT_MS,
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
  assertEquals(ANALYSIS_PREVIEW_UPDATE_INTERVAL_MS, 500);
  assertEquals(MAX_STREAMED_OUTPUT_CHARACTERS, 40_000);
});
