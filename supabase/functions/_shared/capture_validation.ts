import { HttpError } from "./errors.ts";

export const MAX_IMAGE_BYTES = 6 * 1024 * 1024;
export const MAX_AUDIO_BYTES = 12 * 1024 * 1024;
export const MAX_UPLOAD_BYTES = 18 * 1024 * 1024;
export const MAX_TEXT_LENGTH = 12_000;

export const IMAGE_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);
export const AUDIO_TYPES = new Set([
  "audio/aac",
  "audio/m4a",
  "audio/mp4",
  "audio/mpeg",
  "audio/wav",
  "audio/x-m4a",
]);

export function requireMultipartContentType(contentType: string | null): void {
  const mediaType = contentType?.split(";", 1)[0].trim().toLowerCase();
  if (mediaType !== "multipart/form-data") {
    throw new HttpError(415, "Expected multipart form data");
  }
}

export function formString(form: FormData, name: string): string {
  const value = form.get(name);
  return typeof value === "string" ? value.trim() : "";
}

export function formFile(form: FormData, name: string): File | null {
  const value = form.get(name);
  return value instanceof File && value.size > 0 ? value : null;
}

export function validateLocalDay(value: string): string {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new HttpError(400, "local_day must use YYYY-MM-DD");
  }
  const parsed = new Date(`${value}T00:00:00.000Z`);
  if (
    Number.isNaN(parsed.valueOf()) ||
    parsed.toISOString().slice(0, 10) !== value
  ) {
    throw new HttpError(400, "local_day is not a valid calendar date");
  }
  return value;
}

export function validateTimezone(value: string): string {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value }).format();
    return value;
  } catch {
    throw new HttpError(400, "timezone is not a valid IANA timezone");
  }
}

export function validateFile(
  file: File | null,
  allowed: Set<string>,
  maxBytes: number,
  label: string,
): void {
  if (!file) return;
  if (file.size > maxBytes) throw new HttpError(413, `${label} is too large`);
  if (!allowed.has(file.type.toLowerCase())) {
    throw new HttpError(415, `Unsupported ${label.toLowerCase()} type`);
  }
}

export function validateCaptureText(rawText: string): string | null {
  if (rawText.length > MAX_TEXT_LENGTH) {
    throw new HttpError(413, "Meal description is too long");
  }
  return rawText || null;
}

export function validateCombinedAttachmentSize(
  image: Pick<Blob, "size"> | null,
  audio: Pick<Blob, "size"> | null,
): void {
  if ((image?.size ?? 0) + (audio?.size ?? 0) > MAX_UPLOAD_BYTES) {
    throw new HttpError(413, "Combined attachments are too large");
  }
}

export function requireCaptureContent(
  text: string | null,
  image: File | null,
  audio: File | null,
): void {
  if (!text && !image && !audio) {
    throw new HttpError(400, "Add a voice note, photo, or description");
  }
}

export function imageExtension(type: string): string {
  if (type === "image/png") return "png";
  if (type === "image/webp") return "webp";
  return "jpg";
}

export function audioExtension(type: string): string {
  if (type === "audio/wav") return "wav";
  if (type === "audio/mpeg") return "mp3";
  return "m4a";
}

function dayInTimezone(date: Date, timezone: string): string {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const values = Object.fromEntries(
    parts.map((part) => [part.type, part.value]),
  );
  return `${values.year}-${values.month}-${values.day}`;
}

function timezoneOffset(at: Date, timezone: string): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(at);
  const values = Object.fromEntries(
    parts.map((part) => [part.type, part.value]),
  );
  return Date.UTC(
    Number(values.year),
    Number(values.month) - 1,
    Number(values.day),
    Number(values.hour),
    Number(values.minute),
    Number(values.second),
  ) - at.getTime();
}

export function occurredAt(localDay: string, timezone: string): string {
  const now = new Date();
  if (dayInTimezone(now, timezone) === localDay) return now.toISOString();

  const [year, month, day] = localDay.split("-").map(Number);
  const localNoonAsUtc = Date.UTC(year, month - 1, day, 12);
  let instant = new Date(localNoonAsUtc);
  instant = new Date(localNoonAsUtc - timezoneOffset(instant, timezone));
  // Re-evaluate at the resolved instant to handle daylight-saving transitions.
  instant = new Date(localNoonAsUtc - timezoneOffset(instant, timezone));
  return instant.toISOString();
}
