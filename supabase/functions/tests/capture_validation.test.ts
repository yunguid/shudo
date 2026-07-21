import {
  AUDIO_TYPES,
  audioExtension,
  formFile,
  formString,
  IMAGE_TYPES,
  imageExtension,
  MAX_TEXT_LENGTH,
  MAX_UPLOAD_BYTES,
  occurredAt,
  requireCaptureContent,
  requireMultipartContentType,
  validateCaptureText,
  validateCombinedAttachmentSize,
  validateFile,
  validateLocalDay,
  validateTimezone,
} from "../_shared/capture_validation.ts";
import { assertEquals, assertThrows } from "./assertions.ts";

Deno.test("multipart capture requires a multipart content type", () => {
  requireMultipartContentType("Multipart/Form-Data; boundary=meal");
  assertThrows(
    () => requireMultipartContentType("application/json"),
    415,
    "Expected multipart",
  );
  assertThrows(
    () => requireMultipartContentType("text/plain; note=multipart/form-data"),
    415,
  );
  assertThrows(
    () => requireMultipartContentType("multipart/form-data-not-really"),
    415,
  );
  assertThrows(() => requireMultipartContentType(null), 415);
});

Deno.test("form values are trimmed and empty files are ignored", () => {
  const form = new FormData();
  form.set("text", "  turkey sandwich  ");
  form.set("empty", new File([], "empty.m4a", { type: "audio/mp4" }));
  const image = new File(["jpg"], "meal.jpg", { type: "image/jpeg" });
  form.set("image", image);

  assertEquals(formString(form, "text"), "turkey sandwich");
  assertEquals(formString(form, "missing"), "");
  assertEquals(formFile(form, "empty"), null);
  assertEquals(formFile(form, "image")?.name, "meal.jpg");
});

Deno.test("calendar day and IANA timezone validation rejects malformed input", () => {
  assertEquals(validateLocalDay("2024-02-29"), "2024-02-29");
  assertThrows(() => validateLocalDay("2023-02-29"), 400, "calendar date");
  assertThrows(() => validateLocalDay("02/29/2024"), 400, "YYYY-MM-DD");
  assertEquals(validateTimezone("America/New_York"), "America/New_York");
  assertThrows(() => validateTimezone("Mars/Olympus_Mons"), 400, "IANA");
});

Deno.test("backdated captures resolve local noon across DST boundaries", () => {
  assertEquals(
    occurredAt("2024-03-10", "America/New_York"),
    "2024-03-10T16:00:00.000Z",
  );
  assertEquals(
    occurredAt("2024-11-03", "America/New_York"),
    "2024-11-03T17:00:00.000Z",
  );
});

Deno.test("capture text enforces its exact size boundary", () => {
  const maximum = "x".repeat(MAX_TEXT_LENGTH);
  assertEquals(validateCaptureText(maximum), maximum);
  assertEquals(validateCaptureText(""), null);
  assertThrows(
    () => validateCaptureText(`${maximum}x`),
    413,
    "description is too long",
  );
});

Deno.test("attachment validation enforces bytes and MIME allowlists", () => {
  const image = new File(["jpg"], "meal.jpg", { type: "image/jpeg" });
  const audio = new File(["m4a"], "voice.m4a", { type: "audio/x-m4a" });
  validateFile(image, IMAGE_TYPES, image.size, "Image");
  validateFile(audio, AUDIO_TYPES, audio.size, "Voice note");

  const oversized = new File(["1234"], "meal.jpg", { type: "image/jpeg" });
  assertThrows(
    () => validateFile(oversized, IMAGE_TYPES, 3, "Image"),
    413,
    "too large",
  );
  const unsupported = new File(["gif"], "meal.gif", { type: "image/gif" });
  assertThrows(
    () => validateFile(unsupported, IMAGE_TYPES, 10, "Image"),
    415,
    "Unsupported image type",
  );
});

Deno.test("combined attachments and empty captures are rejected", () => {
  validateCombinedAttachmentSize({ size: MAX_UPLOAD_BYTES }, null);
  assertThrows(
    () =>
      validateCombinedAttachmentSize(
        { size: MAX_UPLOAD_BYTES },
        { size: 1 },
      ),
    413,
    "Combined attachments",
  );
  assertThrows(
    () => requireCaptureContent(null, null, null),
    400,
    "Add a voice note",
  );
  requireCaptureContent("meal", null, null);
});

Deno.test("stored attachment extensions are derived from accepted MIME types", () => {
  assertEquals(imageExtension("image/jpeg"), "jpg");
  assertEquals(imageExtension("image/png"), "png");
  assertEquals(imageExtension("image/webp"), "webp");
  assertEquals(audioExtension("audio/mpeg"), "mp3");
  assertEquals(audioExtension("audio/wav"), "wav");
  assertEquals(audioExtension("audio/mp4"), "m4a");
});
