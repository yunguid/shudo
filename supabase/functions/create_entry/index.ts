import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import { scheduleStoredEntryDispatch } from "../_shared/dispatch.ts";
import { drainStorageCleanup } from "../_shared/storage_cleanup.ts";
import {
  AUDIO_TYPES,
  audioExtension,
  formFile,
  formString,
  IMAGE_TYPES,
  imageExtension,
  MAX_AUDIO_BYTES,
  MAX_IMAGE_BYTES,
  occurredAt,
  requireCaptureContent,
  requireMultipartContentType,
  validateCaptureText,
  validateCombinedAttachmentSize,
  validateFile,
  validateLocalDay,
  validateTimezone,
} from "../_shared/capture_validation.ts";
import {
  authenticate,
  CORS_HEADERS,
  HttpError,
  isUuid,
  json,
  runInBackground,
  withTimeout,
} from "../_shared/http.ts";
import { modelQuotaHttpError } from "../_shared/quotas.ts";

const ENTRY_FIELDS =
  "id,status,status_message,processing_attempts,lease_expires_at,upload_token,image_path,audio_path";

type EntryRecord = {
  id: string;
  status: string;
  status_message: string | null;
  processing_attempts: number;
  lease_expires_at: string | null;
  upload_token: string | null;
  image_path: string | null;
  audio_path: string | null;
};

type PreparedEntry = {
  entry: EntryRecord;
  uploadToken: string;
};

async function fetchEntry(
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

async function prepareEntry(
  admin: SupabaseClient,
  userId: string,
  clientRequestId: string,
  localDay: string,
  timezone: string,
  text: string | null,
  intendedImage: boolean,
  intendedAudio: boolean,
  dispatchEntry: (entryId: string) => void,
): Promise<PreparedEntry | { response: Response }> {
  const { data: inserted, error: insertError } = await admin.from("entries")
    .insert({
      user_id: userId,
      client_request_id: clientRequestId,
      local_day: localDay,
      occurred_at: occurredAt(localDay, timezone),
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
      response: json({
        entry_id: existing.id,
        status: "complete",
        duplicate: true,
      }),
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
      response: json({
        entry_id: existing.id,
        status: existing.status,
        duplicate: true,
      }, 202),
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
      response: json({
        entry_id: current?.id ?? existing.id,
        status: current?.status ?? existing.status,
        duplicate: true,
      }, 202),
    };
  }

  return { entry: existing, uploadToken: claimedToken };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  let entryId: string | null = null;
  try {
    requireMultipartContentType(req.headers.get("content-type"));

    // Session validation is a network round trip that does not depend on the
    // body, so it overlaps reading and parsing the multipart payload.
    const authentication = authenticate(req);
    const form = await req.formData().catch(() => {
      // The abandoned validation must not surface as an unhandled rejection.
      authentication.catch(() => undefined);
      throw new HttpError(400, "Could not read the meal capture");
    });
    const { admin, userId } = await authentication;
    const timezone = validateTimezone(formString(form, "timezone"));
    const localDay = validateLocalDay(formString(form, "local_day"));
    const clientRequestId = formString(form, "client_request_id").toLowerCase();
    if (!isUuid(clientRequestId)) {
      throw new HttpError(400, "client_request_id must be a UUID");
    }

    const text = validateCaptureText(formString(form, "text"));
    const image = formFile(form, "image");
    const audio = formFile(form, "audio");
    validateFile(image, IMAGE_TYPES, MAX_IMAGE_BYTES, "Image");
    validateFile(audio, AUDIO_TYPES, MAX_AUDIO_BYTES, "Voice note");
    validateCombinedAttachmentSize(image, audio);
    requireCaptureContent(text, image, audio);

    const dispatchEntry = (id: string): void =>
      scheduleStoredEntryDispatch(req, id);

    const prepared = await prepareEntry(
      admin,
      userId,
      clientRequestId,
      localDay,
      timezone,
      text,
      image !== null,
      audio !== null,
      dispatchEntry,
    );
    if ("response" in prepared) return prepared.response;

    entryId = prepared.entry.id;
    const priorImagePath = prepared.entry.image_path;
    const priorAudioPath = prepared.entry.audio_path;
    const imagePath = image
      ? `${userId}/${entryId}/${prepared.uploadToken}/photo.${
        imageExtension(image.type.toLowerCase())
      }`
      : priorImagePath;
    const audioPath = audio
      ? `${userId}/${entryId}/${prepared.uploadToken}/voice.${
        audioExtension(audio.type.toLowerCase())
      }`
      : priorAudioPath;

    try {
      // The photo and voice note are independent objects; uploading them
      // together removes the smaller upload's full duration from the time to
      // durable acceptance. Failure of either fails the capture as before.
      const uploads: Promise<void>[] = [];
      if (image && imagePath) {
        uploads.push(withTimeout(
          admin.storage.from("entry-images").upload(
            imagePath,
            image,
            { contentType: image.type, cacheControl: "3600", upsert: true },
          ).then(({ error }) => {
            if (error) throw error;
          }),
          60_000,
          "Photo upload",
        ));
      }
      if (audio && audioPath) {
        uploads.push(withTimeout(
          admin.storage.from("entry-audio").upload(
            audioPath,
            audio,
            { contentType: audio.type, cacheControl: "3600", upsert: true },
          ).then(({ error }) => {
            if (error) throw error;
          }),
          90_000,
          "Voice note upload",
        ));
      }
      if (uploads.length > 0) {
        const results = await Promise.allSettled(uploads);
        const failure = results.find(
          (result): result is PromiseRejectedResult =>
            result.status === "rejected",
        );
        if (failure) throw failure.reason;
      }

      const { data: published, error: publishError } = await admin.rpc(
        "publish_entry_upload",
        {
          p_entry_id: entryId,
          p_user_id: userId,
          p_upload_token: prepared.uploadToken,
          p_local_day: localDay,
          p_timezone_snapshot: timezone,
          p_input_text: text,
          p_image_path: imagePath,
          p_audio_path: audioPath,
        },
      );
      if (publishError) throw publishError;
      if (published !== true) throw new Error("Meal upload lease expired");

      runInBackground(
        drainStorageCleanup(admin, 10).catch((error) => {
          console.error("opportunistic_storage_cleanup_failed", {
            entryId,
            message: String(error),
          });
        }),
      );

      // The capture is durable at this point. A dispatch failure must not roll
      // back Storage objects or the queued row; the client can safely resume it.
      scheduleStoredEntryDispatch(req, entryId);
      return json({ entry_id: entryId, status: "queued" }, 202);
    } catch (error) {
      const message = error instanceof Error
        ? error.message.slice(0, 500)
        : "Upload failed";
      const { error: stateError } = await admin.rpc("fail_entry_upload", {
        p_entry_id: entryId,
        p_user_id: userId,
        p_upload_token: prepared.uploadToken,
        p_error_message: message,
      });
      if (stateError) {
        console.error("entry_upload_state_failed", {
          entryId,
          message: stateError.message,
        });
      }
      runInBackground(
        drainStorageCleanup(admin, 10).catch((cleanupError) => {
          console.error("opportunistic_storage_cleanup_failed", {
            entryId,
            message: String(cleanupError),
          });
        }),
      );
      throw error;
    }
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    const message = error instanceof HttpError
      ? error.message
      : "Could not save this meal. Please try again.";
    if (status >= 500) {
      console.error("create_entry_failed", { entryId, message: String(error) });
    }
    return json({ error: message }, status);
  }
});
