import {
  combineEntryCorrectionText,
  CORRECTION_ANALYSIS_TIMEOUT_MS,
  CORRECTION_OVERHEAD_RESERVE_MS,
  CORRECTION_PROCESSING_BUDGET_MS,
  CORRECTION_TRANSCRIPTION_TIMEOUT_MS,
  correctionAudioFilename,
  MAX_CORRECTION_AUDIO_BYTES,
  MAX_CORRECTION_CHARACTERS,
  MAX_CORRECTION_REQUEST_BYTES,
  parseEntryCorrectionForm,
  validateCorrectionContentLength,
} from "../_shared/entry_correction.ts";
import { assertEquals, assertThrows } from "./assertions.ts";

const ENTRY_ID = "10000000-0000-4000-8000-000000000001";
const REQUEST_ID = "20000000-0000-4000-8000-000000000001";

function formWithIdentifiers(): FormData {
  const form = new FormData();
  form.set("entry_id", ENTRY_ID.toUpperCase());
  form.set("client_request_id", REQUEST_ID.toUpperCase());
  return form;
}

Deno.test("correction multipart contract normalizes text and stable IDs", () => {
  const form = formWithIdentifiers();
  form.set("text", "  The bowl also had steak.  ");
  const parsed = parseEntryCorrectionForm(form);

  assertEquals(parsed.entryId, ENTRY_ID);
  assertEquals(parsed.clientRequestId, REQUEST_ID);
  assertEquals(parsed.text, "The bowl also had steak.");
  assertEquals(parsed.audio, null);
});

Deno.test("correction multipart accepts bounded iPhone audio MIME", () => {
  const form = formWithIdentifiers();
  form.set(
    "audio",
    new File([new Uint8Array([1, 2, 3])], "voice.m4a", {
      type: "audio/m4a",
    }),
  );
  const parsed = parseEntryCorrectionForm(form);

  assertEquals(parsed.audio?.size, 3);
  assertEquals(parsed.audio?.type, "audio/m4a");
  assertEquals(correctionAudioFilename(parsed.audio!), "correction.m4a");
});

Deno.test("correction multipart rejects empty, invalid, and oversized inputs", () => {
  assertThrows(() => parseEntryCorrectionForm(formWithIdentifiers()), 400);

  const invalidID = formWithIdentifiers();
  invalidID.set("entry_id", "not-an-entry");
  invalidID.set("text", "Add steak");
  assertThrows(() => parseEntryCorrectionForm(invalidID), 400, "entry_id");

  const unsupported = formWithIdentifiers();
  unsupported.set(
    "audio",
    new File([new Uint8Array([1])], "voice.mov", { type: "video/quicktime" }),
  );
  assertThrows(() => parseEntryCorrectionForm(unsupported), 415);

  const oversizedText = formWithIdentifiers();
  oversizedText.set("text", "🥩".repeat(MAX_CORRECTION_CHARACTERS + 1));
  assertThrows(() => parseEntryCorrectionForm(oversizedText), 413);

  const oversizedAudio = formWithIdentifiers();
  oversizedAudio.set(
    "audio",
    new File(
      [new Uint8Array(MAX_CORRECTION_AUDIO_BYTES + 1)],
      "voice.m4a",
      { type: "audio/mp4" },
    ),
  );
  assertThrows(() => parseEntryCorrectionForm(oversizedAudio), 413);
});

Deno.test("correction combines voice first with optional clarifying text", () => {
  assertEquals(
    combineEntryCorrectionText(
      "It was grilled, not fried.",
      "The bowl also had steak.",
    ),
    "The bowl also had steak.\nIt was grilled, not fried.",
  );
  assertThrows(() => combineEntryCorrectionText(null, "  "), 400);
  assertThrows(
    () =>
      combineEntryCorrectionText(
        "x".repeat(MAX_CORRECTION_CHARACTERS),
        "extra",
      ),
    413,
  );
});

Deno.test("correction rejects declared bodies beyond its multipart budget", () => {
  validateCorrectionContentLength(null);
  validateCorrectionContentLength(String(MAX_CORRECTION_REQUEST_BYTES));
  assertThrows(
    () =>
      validateCorrectionContentLength(
        String(MAX_CORRECTION_REQUEST_BYTES + 1),
      ),
    413,
  );
  assertThrows(() => validateCorrectionContentLength("not-a-number"), 413);
});

Deno.test("correction OpenAI phases leave bounded free-runtime overhead", () => {
  assertEquals(
    CORRECTION_TRANSCRIPTION_TIMEOUT_MS + CORRECTION_ANALYSIS_TIMEOUT_MS +
        CORRECTION_OVERHEAD_RESERVE_MS <= CORRECTION_PROCESSING_BUDGET_MS,
    true,
  );
  assertEquals(CORRECTION_PROCESSING_BUDGET_MS < 150_000, true);
});
