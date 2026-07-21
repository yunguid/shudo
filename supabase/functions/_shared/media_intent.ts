export type StoredMediaIntent = {
  intended_image: boolean;
  intended_audio: boolean;
  image_path: string | null;
  audio_path: string | null;
  transcript: string | null;
};

export type MissingMedia = "photo" | "voice note";

/**
 * Media intent is written before Storage upload begins. A path (or a durable
 * transcript after raw-audio cleanup) proves that the promised attachment was
 * published before processing or retry is allowed.
 */
export function missingIntendedMedia(
  entry: StoredMediaIntent,
): MissingMedia[] {
  const missing: MissingMedia[] = [];
  if (entry.intended_image && !entry.image_path) missing.push("photo");
  if (entry.intended_audio && !entry.audio_path && !entry.transcript?.trim()) {
    missing.push("voice note");
  }
  return missing;
}

export function incompleteMediaMessage(missing: MissingMedia[]): string {
  const description = missing.length === 2
    ? "photo and voice note"
    : missing[0] ?? "attachment";
  return `This meal's ${description} never finished uploading. Delete it and log it again.`;
}
