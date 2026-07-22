import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import { scheduleStoredEntryDispatch } from "../_shared/dispatch.ts";
import { drainStorageCleanup } from "../_shared/storage_cleanup.ts";
import {
  incompleteMediaMessage,
  missingIntendedMedia,
} from "../_shared/media_intent.ts";
import {
  authenticate,
  CORS_HEADERS,
  HttpError,
  isUuid,
  json,
  runInBackground,
} from "../_shared/http.ts";

type ProcessingEntry = {
  id: string;
  status: string;
  processing_attempts: number;
  lease_expires_at: string | null;
  upload_token: string | null;
  intended_image: boolean;
  intended_audio: boolean;
  image_path: string | null;
  audio_path: string | null;
  transcript: string | null;
};

const ENTRY_FIELDS =
  "id,status,processing_attempts,lease_expires_at,upload_token,intended_image,intended_audio,image_path,audio_path,transcript";

async function fetchEntry(
  admin: SupabaseClient,
  entryId: string,
  userId: string,
): Promise<ProcessingEntry | null> {
  const { data, error } = await admin.from("entries")
    .select(ENTRY_FIELDS)
    .eq("id", entryId)
    .eq("user_id", userId)
    .maybeSingle();
  if (error) throw error;
  return data as ProcessingEntry | null;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  let entryId = "";
  try {
    const { admin, userId } = await authenticate(req);
    const payload = await req.json().catch(() => null) as
      | { entry_id?: unknown }
      | null;
    entryId = typeof payload?.entry_id === "string"
      ? payload.entry_id.trim().toLowerCase()
      : "";
    if (!isUuid(entryId)) throw new HttpError(400, "entry_id must be a UUID");

    let entry = await fetchEntry(admin, entryId, userId);
    if (!entry) throw new HttpError(404, "Meal entry not found");

    if (entry.status === "complete") {
      return json({ entry_id: entry.id, status: "complete", resumed: false });
    }
    if (entry.status === "deleting") {
      throw new HttpError(409, "This meal is being deleted");
    }
    if (entry.upload_token) {
      const uploadingEntryId = entry.id;
      const { data: repaired, error: repairError } = await admin.rpc(
        "fail_stale_entry_upload",
        {
          p_entry_id: uploadingEntryId,
          p_user_id: userId,
          p_upload_token: entry.upload_token,
        },
      );
      if (repairError) throw repairError;
      if (repaired !== true) {
        return json({
          entry_id: uploadingEntryId,
          status: entry.status,
          resumed: false,
        }, 202);
      }
      runInBackground(
        drainStorageCleanup(admin, 10).catch((cleanupError) => {
          console.error("opportunistic_storage_cleanup_failed", {
            entryId: uploadingEntryId,
            message: String(cleanupError),
          });
        }),
      );
      throw new HttpError(
        409,
        "The upload was interrupted. Send the capture again.",
      );
    }
    const missingMedia = missingIntendedMedia(entry);
    if (missingMedia.length > 0) {
      if (entry.status === "queued") {
        const { data: failed, error: failError } = await admin.rpc(
          "fail_stale_incomplete_entry",
          { p_entry_id: entry.id, p_user_id: userId },
        );
        if (failError) throw failError;
        if (failed !== true) {
          return json({
            entry_id: entry.id,
            status: entry.status,
            resumed: false,
          }, 202);
        }
      }
      throw new HttpError(409, incompleteMediaMessage(missingMedia));
    }
    if (entry.processing_attempts >= 3) {
      if (["queued", "transcribing", "analyzing"].includes(entry.status)) {
        const { data: repaired, error: repairError } = await admin.rpc(
          "fail_exhausted_entry_processing",
          {
            p_entry_id: entry.id,
            p_user_id: userId,
            p_processing_attempt: entry.processing_attempts,
          },
        );
        if (repairError) throw repairError;
        if (repaired !== true) {
          return json({
            entry_id: entry.id,
            status: entry.status,
            resumed: false,
          }, 202);
        }
      }
      throw new HttpError(
        409,
        "This meal could not be recovered. Delete it and log it again.",
      );
    }
    if (
      !["queued", "failed", "transcribing", "analyzing"].includes(entry.status)
    ) {
      throw new HttpError(409, "This meal cannot be resumed");
    }

    if (entry.status === "failed") {
      const { data: prepared, error: prepareError } = await admin.rpc(
        "prepare_entry_resume",
        { p_entry_id: entry.id, p_user_id: userId },
      );
      if (prepareError) throw prepareError;
      if (prepared === true) {
        entry = {
          ...entry,
          status: "queued",
          lease_expires_at: null,
        };
      } else {
        // A concurrent upload, retry, completion, or delete won the row lock.
        // Re-read instead of returning the stale failed state that would make
        // the iPhone stop polling a retry that is already underway.
        const current = await fetchEntry(admin, entry.id, userId);
        if (!current) throw new HttpError(404, "Meal entry not found");
        if (current.status === "complete") {
          return json({
            entry_id: current.id,
            status: "complete",
            resumed: false,
          });
        }
        if (current.status === "deleting") {
          throw new HttpError(409, "This meal is being deleted");
        }
        if (current.upload_token) {
          return json({
            entry_id: current.id,
            status: current.status,
            resumed: false,
          }, 202);
        }
        if (current.status === "failed") {
          throw new HttpError(
            409,
            current.processing_attempts >= 3
              ? "This meal could not be recovered. Delete it and log it again."
              : "This meal is already being recovered. Pull to refresh.",
          );
        }
        if (
          !["queued", "transcribing", "analyzing"].includes(current.status)
        ) {
          throw new HttpError(409, "This meal cannot be resumed");
        }
        entry = current;
      }
    }

    const resumedEntryId = entry.id;
    const resumedStatus = entry.status;
    // The queued transition is already durable. A transient nested-function
    // failure must not make the phone keep showing the old terminal state;
    // polling can request another dispatch if this one did not land.
    scheduleStoredEntryDispatch(req, resumedEntryId);
    runInBackground(
      drainStorageCleanup(admin, 10).catch((cleanupError) => {
        console.error("opportunistic_storage_cleanup_failed", {
          entryId: resumedEntryId,
          message: String(cleanupError),
        });
      }),
    );
    return json(
      { entry_id: resumedEntryId, status: resumedStatus, resumed: true },
      202,
    );
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    const message = error instanceof HttpError
      ? error.message
      : "Could not resume this meal. Please try again.";
    if (status >= 500) {
      console.error("resume_entry_failed", { entryId, message: String(error) });
    }
    return json({ error: message }, status);
  }
});
