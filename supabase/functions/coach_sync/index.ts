import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import {
  handleCoachSync,
  parseCoachSyncRequest,
} from "../_shared/coach_sync.ts";
import {
  authenticate,
  CORS_HEADERS,
  HttpError,
  json,
  runInBackground,
} from "../_shared/http.ts";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const authentication = authenticate(req);
    authentication.catch(() => undefined);
    const body = await req.json().catch(() => {
      throw new HttpError(400, "Expected a JSON body");
    });
    const { admin, userId } = await authentication;
    const request = parseCoachSyncRequest(body);
    const result = await handleCoachSync(admin, userId, request, {
      observe: runInBackground,
    });
    return json(result);
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    if (status >= 500) {
      console.error("coach_sync_failed", {
        message: String(error).slice(0, 300),
      });
    }
    return json({
      error: error instanceof HttpError
        ? error.message
        : "Couldn't reach the coach. Try again.",
    }, status);
  }
});
