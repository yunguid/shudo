import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import { scheduleStoredEntryDispatch } from "../_shared/dispatch.ts";
import {
  authenticate,
  CORS_HEADERS,
  HttpError,
  json,
} from "../_shared/http.ts";
import { parseReanalysisRequest } from "../_shared/reanalysis.ts";
import { modelQuotaHttpError } from "../_shared/quotas.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  let entryId = "";
  try {
    const { admin, userId } = await authenticate(req);
    const parsed = parseReanalysisRequest(await req.json().catch(() => null));
    entryId = parsed.entryId;

    const { data, error } = await admin.rpc("prepare_entry_reanalysis", {
      p_entry_id: entryId,
      p_user_id: userId,
      p_context: parsed.context,
    });
    if (error) throw modelQuotaHttpError(error) ?? error;

    if (data === "not_found") throw new HttpError(404, "Meal entry not found");
    if (data === "busy") {
      throw new HttpError(
        409,
        "This meal is already being updated. Wait a moment and try again.",
      );
    }
    if (data === "quota") {
      throw new HttpError(
        409,
        "You’ve reached today’s correction limit. Try again tomorrow.",
      );
    }
    if (data === "capacity") {
      throw new HttpError(
        409,
        "A few meals are still processing. Let one finish, then try again.",
      );
    }
    if (data !== "queued") {
      throw new HttpError(
        409,
        "This meal needs a completed analysis before it can be corrected.",
      );
    }

    scheduleStoredEntryDispatch(req, entryId);
    return json({ entry_id: entryId, status: "queued" }, 202);
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    const message = error instanceof HttpError
      ? error.message
      : "Could not apply that correction. Please try again.";
    if (status >= 500) {
      console.error("reanalyze_entry_failed", {
        entryId,
        message: String(error),
      });
    }
    return json({ error: message }, status);
  }
});
