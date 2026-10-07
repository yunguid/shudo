import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import { scheduleStoredEntryDispatch } from "../_shared/dispatch.ts";
import {
  failEntryUpload,
  prepareEntry,
  publishEntryUpload,
  recordSpeechEngine,
} from "../_shared/entry_capture.ts";
import { drainStorageCleanup } from "../_shared/storage_cleanup.ts";
import {
  formFile,
  formString,
  IMAGE_TYPES,
  imageExtension,
  MAX_IMAGE_BYTES,
  parseSpeechEngine,
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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  let entryId: string | null = null;
  try {
    requireMultipartContentType(req.headers.get("content-type"));

    // Session validation is a network round trip that does not depend on the
    // body, so it overlaps reading and parsing the multipart payload. The
    // parked no-op handler is mandatory: without it, an auth rejection that
    // settles before the body finishes parsing is an unhandled rejection and
    // kills the whole worker. Awaiting the original promise below still
    // surfaces the real error.
    const authentication = authenticate(req);
    authentication.catch(() => undefined);
    const form = await req.formData().catch(() => {
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
    if (formFile(form, "audio")) {
      // Voice is transcribed on the phone; only an outdated build uploads it.
      throw new HttpError(
        415,
        "Voice is transcribed on your iPhone now. Update Shudo and try again.",
      );
    }
    const audio = null;
    const speechEngine = parseSpeechEngine(form);
    validateFile(image, IMAGE_TYPES, MAX_IMAGE_BYTES, "Image");
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
    if (prepared.kind === "existing") {
      return json({
        entry_id: prepared.entryId,
        status: prepared.status,
        duplicate: true,
      }, prepared.httpStatus);
    }

    entryId = prepared.entry.id;
    const priorImagePath = prepared.entry.image_path;
    const priorAudioPath = prepared.entry.audio_path;
    const imagePath = image
      ? `${userId}/${entryId}/${prepared.uploadToken}/photo.${
        imageExtension(image.type.toLowerCase())
      }`
      : priorImagePath;
    const audioPath = priorAudioPath;

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
      if (uploads.length > 0) {
        const results = await Promise.allSettled(uploads);
        const failure = results.find(
          (result): result is PromiseRejectedResult =>
            result.status === "rejected",
        );
        if (failure) throw failure.reason;
      }

      if (speechEngine) {
        // Provenance for dictated text; written before publish so the
        // processor (which preserves this column) always sees it.
        await recordSpeechEngine(admin, entryId, userId, speechEngine);
      }

      await publishEntryUpload(admin, {
        entryId,
        userId,
        uploadToken: prepared.uploadToken,
        localDay,
        timezone,
        text,
        imagePath,
        audioPath,
      });

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
      await failEntryUpload(admin, {
        entryId,
        userId,
        uploadToken: prepared.uploadToken,
        message,
      });
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
