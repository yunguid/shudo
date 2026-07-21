import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import { processStoredEntry } from "../_shared/entry_processor.ts";
import {
  authenticate,
  CORS_HEADERS,
  HttpError,
  isUuid,
  json,
  runInBackground,
} from "../_shared/http.ts";

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

    runInBackground(processStoredEntry(admin, entryId, userId));
    return json({ entry_id: entryId, accepted: true }, 202);
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    const message = error instanceof HttpError
      ? error.message
      : "Could not start meal processing. Please try again.";
    if (status >= 500) {
      console.error("process_entry_failed", {
        entryId,
        message: String(error),
      });
    }
    return json({ error: message }, status);
  }
});
