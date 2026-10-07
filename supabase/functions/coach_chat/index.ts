import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import {
  type CoachChatDependencies,
  parseCoachChatBody,
  runCardAction,
  startCoachSend,
} from "../_shared/coach_chat.ts";
import { scheduleCoachJob } from "../_shared/coach_dispatch.ts";
import { isValidTimezone, localClock } from "../_shared/coach_policy.ts";
import { deterministicUuid } from "../_shared/coach_tools.ts";
import { scheduleStoredEntryDispatch } from "../_shared/dispatch.ts";
import { createTextEntry } from "../_shared/entry_capture.ts";
import {
  authenticate,
  CORS_HEADERS,
  HttpError,
  json,
  runInBackground,
  withTimeout,
} from "../_shared/http.ts";

async function profileTimezone(
  admin: SupabaseClient,
  userId: string,
): Promise<string> {
  const { data } = await admin.from("profiles").select("timezone").eq(
    "user_id",
    userId,
  ).maybeSingle();
  const timezone = (data as { timezone?: string } | null)?.timezone;
  return timezone && isValidTimezone(timezone) ? timezone : "UTC";
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const authentication = authenticate(req);
    authentication.catch(() => undefined);
    const raw = await req.json().catch(() => {
      throw new HttpError(400, "Expected a JSON body");
    });
    const { admin, userId } = await authentication;
    const body = parseCoachChatBody(raw);

    const dependencies: CoachChatDependencies = {
      observe: runInBackground,
      // Meals logged from chat are processed by process_entry with the
      // user's own credentials, exactly like the composer.
      dispatchEntry: (entryId) => scheduleStoredEntryDispatch(req, entryId),
      schedulePlan: (job) => scheduleCoachJob(job),
      signedPhotoUrl: async (path) => {
        const { data, error } = await withTimeout(
          admin.storage.from("coach-media").createSignedUrl(path, 600),
          10_000,
          "Photo signing",
        );
        return error || !data ? null : data.signedUrl;
      },
      logMealText: async (client, owner, description, seed, timezone) => {
        const result = await createTextEntry(client, owner, {
          clientRequestId: await deterministicUuid(`snack:${seed}`),
          localDay: localClock(new Date(), timezone).calendarDay,
          timezone,
          text: description,
        }, (entryId) => scheduleStoredEntryDispatch(req, entryId));
        return result.entryId;
      },
    };

    if (body.kind === "send") {
      return await startCoachSend(admin, userId, body.request, dependencies);
    }
    const timezone = await profileTimezone(admin, userId);
    const messages = await runCardAction(
      admin,
      userId,
      body,
      dependencies,
      timezone,
    );
    return json({ messages });
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    if (status >= 500) {
      console.error("coach_chat_failed", {
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
