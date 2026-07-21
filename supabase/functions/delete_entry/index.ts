import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import { drainStorageCleanup } from "../_shared/storage_cleanup.ts";
import {
  authenticate,
  CORS_HEADERS,
  HttpError,
  isUuid,
  json,
  runInBackground,
} from "../_shared/http.ts";

type DeletableEntry = {
  id: string;
  status: string;
};

async function currentEntry(
  admin: SupabaseClient,
  entryId: string,
  userId: string,
): Promise<DeletableEntry | null> {
  const { data, error } = await admin.from("entries")
    .select("id,status")
    .eq("id", entryId)
    .eq("user_id", userId)
    .maybeSingle();
  if (error) throw error;
  return data as DeletableEntry | null;
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

    const entry = await currentEntry(admin, entryId, userId);
    if (!entry) return json({ deleted: false, entry_id: entryId });
    if (!["complete", "failed", "deleting"].includes(entry.status)) {
      throw new HttpError(
        409,
        "This meal is still processing. Try deleting it when it finishes.",
      );
    }

    const { data: deleted, error: deleteError } = await admin.rpc(
      "delete_entry_with_cleanup",
      { p_entry_id: entryId, p_user_id: userId },
    );
    if (deleteError) throw deleteError;
    if (deleted !== true) {
      const current = await currentEntry(admin, entryId, userId);
      if (current) {
        throw new HttpError(
          409,
          "This meal changed while it was being deleted. Please try again.",
        );
      }
      return json({ deleted: false, entry_id: entryId });
    }

    runInBackground(
      drainStorageCleanup(admin, 10).catch((cleanupError) => {
        console.error("opportunistic_storage_cleanup_failed", {
          entryId,
          message: String(cleanupError),
        });
      }),
    );
    return json({ deleted: true, entry_id: entryId });
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    const message = error instanceof HttpError
      ? error.message
      : "Could not delete meal entry";
    if (status >= 500) {
      console.error("delete_entry_failed", { entryId, message: String(error) });
    }
    return json({ error: message }, status);
  }
});
