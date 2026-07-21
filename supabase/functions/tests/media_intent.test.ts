import {
  incompleteMediaMessage,
  missingIntendedMedia,
  type StoredMediaIntent,
} from "../_shared/media_intent.ts";
import { assertEquals } from "./assertions.ts";

function entry(
  overrides: Partial<StoredMediaIntent> = {},
): StoredMediaIntent {
  return {
    intended_image: false,
    intended_audio: false,
    image_path: null,
    audio_path: null,
    transcript: null,
    ...overrides,
  };
}

Deno.test("unpublished intended attachments cannot be resumed", () => {
  assertEquals(
    missingIntendedMedia(entry({ intended_image: true })),
    ["photo"],
  );
  assertEquals(
    missingIntendedMedia(entry({ intended_audio: true })),
    ["voice note"],
  );
  assertEquals(
    missingIntendedMedia(entry({
      intended_image: true,
      intended_audio: true,
    })),
    ["photo", "voice note"],
  );
  assertEquals(
    incompleteMediaMessage(["photo", "voice note"]),
    "This meal's photo and voice note never finished uploading. Delete it and log it again.",
  );
});

Deno.test("published media and durably transcribed audio remain resumable", () => {
  assertEquals(
    missingIntendedMedia(entry({
      intended_image: true,
      image_path: "user/entry/token/photo.jpg",
    })),
    [],
  );
  assertEquals(
    missingIntendedMedia(entry({
      intended_audio: true,
      audio_path: "user/entry/token/voice.m4a",
    })),
    [],
  );
  assertEquals(
    missingIntendedMedia(entry({
      intended_audio: true,
      transcript: "durable voice transcript",
    })),
    [],
  );
  assertEquals(
    missingIntendedMedia(entry({
      intended_image: false,
      intended_audio: false,
    })),
    [],
  );
});
