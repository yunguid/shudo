import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import { occurredAt } from "./capture_validation.ts";
import { HttpError } from "./errors.ts";
import { modelQuotaHttpError } from "./quotas.ts";

/// The durable half of a meal capture, shared by create_entry (multipart
/// uploads) and the coach's log_meal_text tool (text only): insert-or-find
/// the idempotent entry row, claim its upload token, publish it, and leave
/// processing to process_entry.

export const ENTRY_FIELDS =
  "id,status,status_message,processing_attempts,lease_expires_at,upload_token,image_path,audio_path";

export type EntryRecord = {
  id: string;
  status: string;
  status_message: string | null;
  processing_attempts: number;
  lease_expires_at: string | null;
  upload_token: string | null;
  image_path: string | null;
  audio_path: string | null;
};

export type PreparedEntry =
  | { kind: "prepared"; entry: EntryRecord; uploadToken: string }
  /// The request was already handled; respond with the existing state.
  | {
    kind: "existing";
    entryId: string;
    status: string;
    httpStatus: 200 | 202;
  };

export async function fetchEntry(
  admin: SupabaseClient,
  userId: string,
  clientRequestId: string,
): Promise<EntryRecord | null> {
  const { data, error } = await admin.from("entries")
    .select(ENTRY_FIELDS)
    .eq("user_id", userId)
    .eq("client_request_id", clientRequestId)
    .maybeSingle();
  if (error) throw error;
  return data as EntryRecord | null;
}

export async function prepareEntry(
  admin: SupabaseClient,
  userId: string,
  clientRequestId: string,
  localDay: string,
  timezone: string,
  text: string | null,
  intendedImage: boolean,
  intendedAudio: boolean,
  dispatchEntry: (entryId: string) => void,
  occurredAtOverride: string | null = null,
): Promise<PreparedEntry> {
  const { data: inserted, error: insertError } = await admin.from("entries")
    .insert({
      user_id: userId,
      client_request_id: clientRequestId,
      local_day: localDay,
      occurred_at: occurredAtOverride ?? occurredAt(localDay, timezone),
      timezone_snapshot: timezone,
      status: "queued",
      status_message: "Uploading",
      input_text: text,
      raw_text: text,
      intended_image: intendedImage,
      intended_audio: intendedAudio,
    })
    .select(ENTRY_FIELDS)
    .maybeSingle();

  if (insertError && insertError.code !== "23505") {
    throw modelQuotaHttpError(insertError) ?? insertError;
  }

  const existing = (inserted as EntryRecord | null) ??
    await fetchEntry(admin, userId, clientRequestId);
  if (!existing) throw insertError ?? new Error("Could not prepare meal entry");
  if (existing.status === "complete") {
    return {
      kind: "existing",
      entryId: existing.id,
      status: "complete",
      httpStatus: 200,
    };
  }
  if (existing.status === "deleting") {
    throw new HttpError(409, "This meal is being deleted");
  }
  if (existing.processing_attempts >= 3) {
    throw new HttpError(
      409,
      "This meal could not be recovered. Delete it and log it again.",
    );
  }
  if (
    existing.status === "transcribing" || existing.status === "analyzing"
  ) {
    // The processor's database claim decides whether the lease is stale. This
    // avoids making that decision with a potentially skewed Edge clock.
    dispatchEntry(existing.id);
    return {
      kind: "existing",
      entryId: existing.id,
      status: existing.status,
      httpStatus: 202,
    };
  }
  const { data: claimedToken, error: claimError } = await admin.rpc(
    "claim_entry_upload",
    { p_entry_id: existing.id, p_user_id: userId },
  );
  if (claimError) throw claimError;
  if (typeof claimedToken !== "string" || !claimedToken) {
    const current = await fetchEntry(admin, userId, clientRequestId);
    return {
      kind: "existing",
      entryId: current?.id ?? existing.id,
      status: current?.status ?? existing.status,
      httpStatus: 202,
    };
  }

  return { kind: "prepared", entry: existing, uploadToken: claimedToken };
}

export async function publishEntryUpload(
  admin: SupabaseClient,
  args: {
    entryId: string;
    userId: string;
    uploadToken: string;
    localDay: string;
    timezone: string;
    text: string | null;
    imagePath: string | null;
    audioPath: string | null;
  },
): Promise<void> {
  const { data: published, error: publishError } = await admin.rpc(
    "publish_entry_upload",
    {
      p_entry_id: args.entryId,
      p_user_id: args.userId,
      p_upload_token: args.uploadToken,
      p_local_day: args.localDay,
      p_timezone_snapshot: args.timezone,
      p_input_text: args.text,
      p_image_path: args.imagePath,
      p_audio_path: args.audioPath,
    },
  );
  if (publishError) throw publishError;
  if (published !== true) throw new Error("Meal upload lease expired");
}

export async function failEntryUpload(
  admin: SupabaseClient,
  args: { entryId: string; userId: string; uploadToken: string; message: string },
): Promise<void> {
  const { error } = await admin.rpc("fail_entry_upload", {
    p_entry_id: args.entryId,
    p_user_id: args.userId,
    p_upload_token: args.uploadToken,
    p_error_message: args.message.slice(0, 500),
  });
  if (error) {
    console.error("entry_upload_state_failed", {
      entryId: args.entryId,
      message: error.message,
    });
  }
}

/// Records which on-device engine wrote dictated text; must precede publish
/// because the processor preserves this column.
export async function recordSpeechEngine(
  admin: SupabaseClient,
  entryId: string,
  userId: string,
  speechEngine: string,
): Promise<void> {
  const { error } = await admin.from("entries")
    .update({ transcription_model: speechEngine })
    .eq("id", entryId)
    .eq("user_id", userId);
  if (error) throw error;
}

export type TextEntryInput = {
  clientRequestId: string;
  localDay: string;
  timezone: string;
  text: string;
  speechEngine?: string | null;
  occurredAt?: string | null;
};

export type TextEntryResult = {
  entryId: string;
  status: string;
  duplicate: boolean;
};

/**
 * Creates a text-only meal entry through the same durable path as the app's
 * composer and hands it to process_entry. Idempotent per clientRequestId.
 */
export async function createTextEntry(
  admin: SupabaseClient,
  userId: string,
  input: TextEntryInput,
  dispatchEntry: (entryId: string) => void,
): Promise<TextEntryResult> {
  const text = input.text.trim();
  if (!text) throw new HttpError(400, "Describe the meal to log it");
  if (text.length > 12_000) throw new HttpError(413, "Meal description is too long");
  const prepared = await prepareEntry(
    admin,
    userId,
    input.clientRequestId,
    input.localDay,
    input.timezone,
    text,
    false,
    false,
    dispatchEntry,
    input.occurredAt ?? null,
  );
  if (prepared.kind === "existing") {
    return { entryId: prepared.entryId, status: prepared.status, duplicate: true };
  }
  const entryId = prepared.entry.id;
  try {
    if (input.speechEngine) {
      await recordSpeechEngine(admin, entryId, userId, input.speechEngine);
    }
    await publishEntryUpload(admin, {
      entryId,
      userId,
      uploadToken: prepared.uploadToken,
      localDay: input.localDay,
      timezone: input.timezone,
      text,
      imagePath: prepared.entry.image_path,
      audioPath: prepared.entry.audio_path,
    });
  } catch (error) {
    await failEntryUpload(admin, {
      entryId,
      userId,
      uploadToken: prepared.uploadToken,
      message: error instanceof Error ? error.message : "Upload failed",
    });
    throw error;
  }
  dispatchEntry(entryId);
  return { entryId, status: "queued", duplicate: false };
}
