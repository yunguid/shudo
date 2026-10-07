import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import {
  formFile,
  formString,
  requireMultipartContentType,
} from "../_shared/capture_validation.ts";
import {
  authenticate,
  CORS_HEADERS,
  HttpError,
  isUuid,
  json,
} from "../_shared/http.ts";
import {
  OPENAI_TRANSCRIPTION_ENGINE,
  OPENAI_TRANSCRIPTION_MODEL,
  parseTranscriptionPurpose,
  transcribeAudio,
} from "../_shared/transcription.ts";

/// Record-then-send voice: the phone uploads one recording, gets text back,
/// and submits that text through the normal meal / coach / correction paths.
/// Audio is never stored.
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    requireMultipartContentType(req.headers.get("content-type"));
    const authentication = authenticate(req);
    authentication.catch(() => undefined);
    const form = await req.formData().catch(() => {
      throw new HttpError(400, "Could not read the recording");
    });
    await authentication;
    const purpose = parseTranscriptionPurpose(formString(form, "purpose"));
    const requestId = formString(form, "client_request_id").toLowerCase();
    if (requestId && !isUuid(requestId)) {
      throw new HttpError(400, "client_request_id must be a UUID");
    }
    const audio = formFile(form, "audio");
    if (!audio) throw new HttpError(400, "Attach a recording");
    const text = await transcribeAudio(audio, purpose);
    return json({
      text,
      model: OPENAI_TRANSCRIPTION_MODEL,
      speech_engine: OPENAI_TRANSCRIPTION_ENGINE,
    });
  } catch (error) {
    const status = error instanceof HttpError ? error.status : 500;
    const message = error instanceof HttpError
      ? error.message
      : "Transcription failed. Try again.";
    if (status >= 500) {
      console.error("transcribe_failed", {
        message: String(error).slice(0, 300),
      });
    }
    return json({ error: message }, status);
  }
});
