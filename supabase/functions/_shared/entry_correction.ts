import { HttpError } from "./errors.ts";
import { isUuid } from "./http.ts";

export const MAX_CORRECTION_CHARACTERS = 4_000;
export const MAX_CORRECTION_AUDIO_BYTES = 8 * 1024 * 1024;
export const MAX_CORRECTION_REQUEST_BYTES = MAX_CORRECTION_AUDIO_BYTES +
  64 * 1024;
export const CORRECTION_PROCESSING_BUDGET_MS = 125_000;
export const CORRECTION_TRANSCRIPTION_TIMEOUT_MS = 45_000;
export const CORRECTION_ANALYSIS_TIMEOUT_MS = 60_000;
export const CORRECTION_OVERHEAD_RESERVE_MS = 20_000;

export const CORRECTION_AUDIO_TYPES = new Set([
  "audio/aac",
  "audio/m4a",
  "audio/mp4",
  "audio/mpeg",
  "audio/wav",
  "audio/x-m4a",
]);

export type EntryCorrectionCapture = {
  entryId: string;
  clientRequestId: string;
  text: string | null;
  audio: File | null;
};

function formString(form: FormData, name: string): string {
  const value = form.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function unicodeLength(value: string): number {
  return Array.from(value).length;
}

export function validateCorrectionContentLength(value: string | null): void {
  if (!value) return;
  const parsed = Number(value);
  if (
    !Number.isSafeInteger(parsed) || parsed < 0 ||
    parsed > MAX_CORRECTION_REQUEST_BYTES
  ) {
    throw new HttpError(413, "Correction recording is too large");
  }
}

export function parseEntryCorrectionForm(
  form: FormData,
): EntryCorrectionCapture {
  const entryId = formString(form, "entry_id").toLowerCase();
  const clientRequestId = formString(form, "client_request_id").toLowerCase();
  if (!isUuid(entryId)) {
    throw new HttpError(400, "entry_id must be a UUID");
  }
  if (!isUuid(clientRequestId)) {
    throw new HttpError(400, "client_request_id must be a UUID");
  }

  const rawText = formString(form, "text");
  if (unicodeLength(rawText) > MAX_CORRECTION_CHARACTERS) {
    throw new HttpError(
      413,
      `Correction text must be ${MAX_CORRECTION_CHARACTERS} characters or fewer`,
    );
  }

  const audioValue = form.get("audio");
  const audio = audioValue instanceof File && audioValue.size > 0
    ? audioValue
    : null;
  if (audio) {
    if (audio.size > MAX_CORRECTION_AUDIO_BYTES) {
      throw new HttpError(413, "Correction recording is too large");
    }
    if (!CORRECTION_AUDIO_TYPES.has(audio.type.toLowerCase())) {
      throw new HttpError(415, "Unsupported correction recording type");
    }
  }

  const text = rawText || null;
  if (!text && !audio) {
    throw new HttpError(400, "Record or type what should change");
  }
  return { entryId, clientRequestId, text, audio };
}

export function combineEntryCorrectionText(
  text: string | null,
  transcript: string | null,
): string {
  const correction = [transcript?.trim(), text?.trim()]
    .filter((value): value is string => Boolean(value))
    .join("\n")
    .trim();
  if (!correction) throw new HttpError(400, "Correction was empty");
  if (unicodeLength(correction) > MAX_CORRECTION_CHARACTERS) {
    throw new HttpError(
      413,
      "That correction is too long. Try a shorter voice note or note.",
    );
  }
  return correction;
}

export function correctionAudioType(audio: Blob): string {
  const type = audio.type.toLowerCase();
  return CORRECTION_AUDIO_TYPES.has(type) ? type : "audio/mp4";
}

export function correctionAudioFilename(audio: Blob): string {
  switch (correctionAudioType(audio)) {
    case "audio/wav":
      return "correction.wav";
    case "audio/mpeg":
      return "correction.mp3";
    case "audio/aac":
      return "correction.aac";
    default:
      return "correction.m4a";
  }
}
