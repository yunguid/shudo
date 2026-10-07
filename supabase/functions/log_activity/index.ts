import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import {
  activityImagePath,
  type ActivitySource,
  analyzeStoredActivity,
  insertProcessingActivity,
  isJpegBytes,
  MAX_ACTIVITY_TEXT_LENGTH,
  parseActivityOccurredAt,
  parsePlanSessionId,
} from "../_shared/activity_analysis.ts";
import {
  formFile,
  formString,
  MAX_IMAGE_BYTES,
  parseSpeechEngine,
  requireMultipartContentType,
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

const COACH_MEDIA_BUCKET = "coach-media";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  let activityId: string | null = null;
  try {
    requireMultipartContentType(req.headers.get("content-type"));
    // Auth overlaps body parsing; the parked catch keeps an early auth
    // rejection from becoming an unhandled rejection (see create_entry).
    const authentication = authenticate(req);
    authentication.catch(() => undefined);
    const form = await req.formData().catch(() => {
      throw new HttpError(400, "Could not read the workout");
    });
    const { admin, userId } = await authentication;

    const timezone = validateTimezone(formString(form, "timezone"));
    const localDay = validateLocalDay(formString(form, "local_day"));
    const clientRequestId = formString(form, "client_request_id").toLowerCase();
    if (!isUuid(clientRequestId)) {
      throw new HttpError(400, "client_request_id must be a UUID");
    }
    const text = formString(form, "text").replaceAll("\u0000", "");
    if (text.length > MAX_ACTIVITY_TEXT_LENGTH) {
      throw new HttpError(413, "Workout description is too long");
    }
    const speechEngine = parseSpeechEngine(form);
    const occurredAt = parseActivityOccurredAt(formString(form, "occurred_at"));
    const planSessionId = parsePlanSessionId(
      formString(form, "plan_session_id"),
    );
    const image = formFile(form, "image");
    let imageBytes: Uint8Array | null = null;
    if (image) {
      if (image.size > MAX_IMAGE_BYTES) {
        throw new HttpError(413, "Image is too large");
      }
      imageBytes = new Uint8Array(await image.arrayBuffer());
      if (!isJpegBytes(imageBytes)) {
        throw new HttpError(415, "Workout photos must be JPEG");
      }
    }
    if (!text && !imageBytes) {
      throw new HttpError(400, "Describe the workout or add a photo");
    }

    const source: ActivitySource = imageBytes
      ? "photo"
      : speechEngine
      ? "voice"
      : "text";
    const imagePath = imageBytes
      ? activityImagePath(userId, localDay, clientRequestId)
      : null;

    // A resend of an already-recorded request never re-uploads.
    const { data: existing, error: existingError } = await admin.from(
      "activities",
    )
      .select("id")
      .eq("user_id", userId)
      .eq("client_request_id", clientRequestId)
      .maybeSingle();
    if (existingError) throw existingError;

    let uploaded = false;
    if (!existing && imageBytes && imagePath) {
      const { error: uploadError } = await withTimeout(
        admin.storage.from(COACH_MEDIA_BUCKET).upload(imagePath, imageBytes, {
          contentType: "image/jpeg",
          cacheControl: "3600",
          upsert: true,
        }),
        60_000,
        "Workout photo upload",
      );
      if (uploadError) throw uploadError;
      uploaded = true;
    }

    let prepared;
    try {
      prepared = await insertProcessingActivity(admin, userId, {
        clientRequestId,
        localDay,
        timezone,
        text: text || null,
        source,
        occurredAt,
        imagePath,
        planSessionId,
        speechEngine,
      });
    } catch (insertError) {
      if (uploaded && imagePath) {
        // Nothing references the object if the row never landed.
        const { data: raced } = await admin.from("activities")
          .select("id")
          .eq("user_id", userId)
          .eq("client_request_id", clientRequestId)
          .maybeSingle();
        if (!raced) {
          await admin.storage.from(COACH_MEDIA_BUCKET).remove([imagePath])
            .catch(() => undefined);
        }
      }
      throw insertError;
    }
    activityId = prepared.activityId;
    if (prepared.analyze) {
      runInBackground(
        analyzeStoredActivity(admin, userId, prepared.activityId),
      );
    }
    return json({
      activity_id: prepared.activityId,
      status: prepared.status,
      duplicate: prepared.duplicate,
    }, prepared.status === "processing" ? 202 : 200);
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    const message = error instanceof HttpError
      ? error.message
      : "Could not save this workout. Please try again.";
    if (status >= 500) {
      console.error("log_activity_failed", {
        activityId,
        message: error instanceof Error
          ? error.message.slice(0, 200)
          : "unknown",
      });
    }
    return json({ error: message }, status);
  }
});
