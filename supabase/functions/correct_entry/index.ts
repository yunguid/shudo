import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import {
  MAX_ANALYSIS_CONTEXT_LENGTH,
  parseAnalysis,
  type ParsedAnalysis,
  responseOutputText,
  RESULT_SCHEMA,
} from "../_shared/analysis.ts";
import {
  combineEntryCorrectionText,
  CORRECTION_ANALYSIS_TIMEOUT_MS,
  CORRECTION_TRANSCRIPTION_TIMEOUT_MS,
  correctionAudioFilename,
  correctionAudioType,
  correctionEvidencePaths,
  parseEntryCorrectionForm,
  validateCorrectionContentLength,
} from "../_shared/entry_correction.ts";
import { NEUTRAL_PRODUCT_COPY_INSTRUCTION } from "../_shared/generated_copy.ts";
import {
  authenticate,
  CORS_HEADERS,
  HttpError,
  json,
  requiredEnv,
  runInBackground,
  withTimeout,
} from "../_shared/http.ts";
import { refreshWeeklySummaryForDay } from "../_shared/weekly_summary.ts";
import {
  IMAGE_TYPES,
  imageExtension,
  MAX_IMAGE_BYTES,
  requireMultipartContentType,
  validateFile,
} from "../_shared/capture_validation.ts";
import { modelQuotaHttpError } from "../_shared/quotas.ts";
import { safetyIdentifier } from "../_shared/safety.ts";
import {
  type CorrectionReservationStatus,
  parseCorrectionReservation,
} from "./reservation.ts";

const ANALYSIS_MODEL = "gpt-5.6-sol";
const TRANSCRIPTION_MODEL = "gpt-4o-transcribe";
const MAX_BASE_DESCRIPTION_CHARACTERS = 30_000;

type CorrectionEntry = {
  id: string;
  status: string;
  local_day: string | null;
  raw_text: string | null;
  input_text: string | null;
  transcript: string | null;
  analysis_context: string | null;
  image_path: string | null;
};

async function transcribeCorrection(audio: File): Promise<string> {
  const form = new FormData();
  form.append("model", TRANSCRIPTION_MODEL);
  form.append("response_format", "json");
  form.append(
    "prompt",
    "A correction to a personal meal log. Preserve foods, brands, quantities, portions, units, sauces, drinks, additions, and removals accurately.",
  );
  form.append(
    "file",
    new File([await audio.arrayBuffer()], correctionAudioFilename(audio), {
      type: correctionAudioType(audio),
    }),
  );

  const response = await fetch(
    "https://api.openai.com/v1/audio/transcriptions",
    {
      method: "POST",
      headers: { authorization: `Bearer ${requiredEnv("OPENAI_API_KEY")}` },
      body: form,
      signal: AbortSignal.timeout(CORRECTION_TRANSCRIPTION_TIMEOUT_MS),
    },
  );
  if (!response.ok) {
    throw new Error(`Correction transcription failed (${response.status})`);
  }
  const payload = await response.json();
  const text = typeof payload?.text === "string" ? payload.text.trim() : "";
  if (!text) throw new Error("Correction transcription was empty");
  return text;
}

async function analyzeCorrection(
  userId: string,
  baseDescription: string,
  previousCorrections: string | null,
  latestCorrection: string,
  imageUrls: string[],
): Promise<{ analysis: ParsedAnalysis; responseId: string | null }> {
  const content: Array<Record<string, unknown>> = [{
    type: "input_text",
    text: [
      "Re-estimate the entire meal after applying the user's latest correction.",
      "The latest correction is authoritative when it conflicts with the original description or earlier corrections.",
      "Preserve every original fact that the correction does not change. Do not invent new ingredients, quantities, or preparation details.",
      "Use realistic portion assumptions only when a necessary quantity is still unavailable.",
      "Write analysis_preview first as one short natural-language sentence describing what changed.",
      `${NEUTRAL_PRODUCT_COPY_INSTRUCTION} Describe only the corrected meal, what changed, and any clearly labeled estimate assumptions.`,
      "Keep the title short and make item totals internally consistent with meal totals.",
      `Original meal description and transcript:\n${
        baseDescription ||
        "No written description was retained. Use the photo and corrections."
      }`,
      previousCorrections
        ? `Earlier accepted corrections, newest first:\n${previousCorrections}`
        : "",
      `Latest correction:\n${latestCorrection}`,
    ].filter(Boolean).join("\n\n"),
  }];
  for (const imageUrl of imageUrls.slice(0, 5)) {
    content.push({ type: "input_image", image_url: imageUrl, detail: "high" });
  }

  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      authorization: `Bearer ${requiredEnv("OPENAI_API_KEY")}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: ANALYSIS_MODEL,
      reasoning: { effort: "low" },
      input: [{ role: "user", content }],
      text: {
        verbosity: "low",
        format: {
          type: "json_schema",
          name: "shudo_corrected_meal_analysis",
          strict: true,
          schema: RESULT_SCHEMA,
        },
      },
      max_output_tokens: 2_500,
      safety_identifier: await safetyIdentifier(userId),
      store: false,
    }),
    signal: AbortSignal.timeout(CORRECTION_ANALYSIS_TIMEOUT_MS),
  });
  if (!response.ok) {
    throw new Error(`Correction analysis failed (${response.status})`);
  }
  const payload = await response.json() as Record<string, unknown>;
  const outputText = responseOutputText(payload);
  if (!outputText) throw new Error("Correction analysis returned no output");
  return {
    analysis: parseAnalysis(JSON.parse(outputText)),
    responseId: typeof payload.id === "string" ? payload.id : null,
  };
}

async function fetchCorrectionEntry(
  admin: SupabaseClient,
  entryId: string,
  userId: string,
): Promise<CorrectionEntry> {
  const { data, error } = await admin.from("entries")
    .select(
      "id,status,local_day,raw_text,input_text,transcript,analysis_context,image_path",
    )
    .eq("id", entryId)
    .eq("user_id", userId)
    .maybeSingle();
  if (error) throw error;
  if (!data) throw new HttpError(404, "Meal entry not found");
  if (data.status !== "complete") {
    throw new HttpError(
      409,
      "Wait for this meal to finish before correcting it.",
    );
  }
  return data as CorrectionEntry;
}

async function signedEvidenceImageUrls(
  admin: SupabaseClient,
  entry: CorrectionEntry,
  newPhotoPath: string | null,
): Promise<string[]> {
  const { data: photos, error } = await admin.from("entry_photos")
    .select("storage_path,purpose")
    .eq("entry_id", entry.id)
    .order("created_at", { ascending: true })
    .limit(20);
  if (error) throw error;
  const paths = correctionEvidencePaths(
    entry.image_path,
    (photos ?? []).filter((photo) =>
      typeof photo.storage_path === "string" &&
      typeof photo.purpose === "string"
    ),
    newPhotoPath,
  );

  return await Promise.all(
    paths.map(async (path) => {
      const { data, error: signedError } = await admin.storage
        .from("entry-images")
        .createSignedUrl(path, 300);
      if (signedError) throw signedError;
      return data.signedUrl;
    }),
  );
}

async function requirePhotoCapacity(
  admin: SupabaseClient,
  entryId: string,
  userId: string,
  clientRequestId: string,
): Promise<void> {
  const { data: replay, error: replayError } = await admin.from("entry_photos")
    .select("entry_id")
    .eq("user_id", userId)
    .eq("client_request_id", clientRequestId)
    .maybeSingle();
  if (replayError) throw replayError;
  if (replay) {
    if (replay.entry_id === entryId) return;
    throw new HttpError(
      409,
      "That photo update conflicts with an earlier request.",
    );
  }
  const { count, error } = await admin.from("entry_photos")
    .select("id", { count: "exact", head: true })
    .eq("entry_id", entryId)
    .eq("user_id", userId);
  if (error) throw error;
  if ((count ?? 0) >= 20) {
    throw new HttpError(
      409,
      "This meal already has the maximum number of photo attachments.",
    );
  }
}

function reservationError(status: CorrectionReservationStatus): HttpError {
  switch (status) {
    case "not_found":
      return new HttpError(404, "Meal entry not found");
    case "busy":
    case "capacity":
    case "processing":
      return new HttpError(
        409,
        "A correction is already being applied. Wait a moment and try again.",
      );
    case "quota":
      return new HttpError(
        429,
        "You’ve reached today’s correction limit. Try again tomorrow.",
      );
    case "failed":
      return new HttpError(
        409,
        "That correction couldn’t be completed. Discard it and record a new one.",
      );
    case "conflict":
      return new HttpError(409, "That correction request is no longer valid.");
    default:
      return new HttpError(
        409,
        "This meal needs a completed analysis before it can be corrected.",
      );
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  let admin: SupabaseClient | null = null;
  let userId = "";
  let entryId = "";
  let clientRequestId = "";
  let claimToken = "";
  let ownsReservation = false;
  try {
    requireMultipartContentType(req.headers.get("content-type"));
    validateCorrectionContentLength(req.headers.get("content-length"));
    ({ admin, userId } = await authenticate(req));

    const form = await req.formData().catch(() => {
      throw new HttpError(400, "Correction form data could not be read");
    });
    const capture = parseEntryCorrectionForm(form);
    entryId = capture.entryId;
    clientRequestId = capture.clientRequestId;

    // A photo-only update is a memory by default. It never reserves model
    // quota and never changes the completed nutrition estimate.
    if (capture.image && capture.photoIntent === "memory") {
      await fetchCorrectionEntry(admin, entryId, userId);
      await requirePhotoCapacity(admin, entryId, userId, clientRequestId);
      const photoPath =
        `${userId}/${entryId}/updates/${clientRequestId}/photo.${
          imageExtension(capture.image.type.toLowerCase())
        }`;
      await withTimeout(
        admin.storage.from("entry-images").upload(photoPath, capture.image, {
          contentType: capture.image.type,
          cacheControl: "3600",
          upsert: true,
        }).then(({ error }) => {
          if (error) throw error;
        }),
        30_000,
        "Photo upload",
      );
      const { data: attached, error: attachError } = await admin.rpc(
        "attach_entry_photo",
        {
          p_entry_id: entryId,
          p_user_id: userId,
          p_client_request_id: clientRequestId,
          p_storage_path: photoPath,
          p_purpose: "memory",
        },
      );
      if (attachError) throw attachError;
      if (attached !== "complete") {
        throw new HttpError(
          attached === "not_found" ? 404 : 409,
          attached === "busy"
            ? "Wait for this meal to finish before adding a photo."
            : attached === "not_found"
            ? "Meal entry not found"
            : attached === "capacity"
            ? "This meal already has the maximum number of photo attachments."
            : "That photo update conflicts with an earlier request.",
        );
      }
      return json({
        entry_id: entryId,
        client_request_id: clientRequestId,
        status: "complete",
        nutrition_changed: false,
      });
    }
    if (capture.image) {
      await requirePhotoCapacity(admin, entryId, userId, clientRequestId);
    }

    const { data: reservation, error: reservationFailure } = await admin.rpc(
      "reserve_entry_correction",
      {
        p_entry_id: entryId,
        p_user_id: userId,
        p_client_request_id: clientRequestId,
      },
    );
    if (reservationFailure) {
      throw modelQuotaHttpError(reservationFailure) ?? reservationFailure;
    }
    const parsedReservation = parseCorrectionReservation(reservation);
    if (parsedReservation.status === "complete") {
      return json({
        entry_id: entryId,
        client_request_id: clientRequestId,
        status: "complete",
        replayed: true,
      });
    }
    if (
      parsedReservation.status !== "reserved" &&
      parsedReservation.status !== "reclaimed"
    ) {
      throw reservationError(parsedReservation.status);
    }
    claimToken = parsedReservation.claimToken;
    ownsReservation = true;

    const entry = await fetchCorrectionEntry(admin, entryId, userId);
    const baseDescription = (
      entry.raw_text?.trim() ||
      [entry.input_text, entry.transcript].filter(Boolean).join("\n").trim()
    ).slice(0, MAX_BASE_DESCRIPTION_CHARACTERS);

    const correctionPhotoUpload: Promise<string | null> = capture.image
      ? (() => {
        validateFile(capture.image, IMAGE_TYPES, MAX_IMAGE_BYTES, "Image");
        const path = `${userId}/${entryId}/updates/${clientRequestId}/photo.${
          imageExtension(capture.image.type.toLowerCase())
        }`;
        return withTimeout(
          admin.storage.from("entry-images").upload(
            path,
            capture.image,
            {
              contentType: capture.image.type,
              cacheControl: "3600",
              upsert: true,
            },
          ).then(({ error }) => {
            if (error) throw error;
            return path;
          }),
          30_000,
          "Photo upload",
        );
      })()
      : Promise.resolve(null);
    // Park a rejection while transcription runs so upload and speech work can
    // overlap without producing an unhandled promise rejection.
    correctionPhotoUpload.catch(() => undefined);

    let transcript: string | null = null;
    if (capture.audio) {
      transcript = await transcribeCorrection(capture.audio);
    }
    const correctionPhotoPath = await correctionPhotoUpload;
    const correctionText = combineEntryCorrectionText(
      capture.text,
      transcript,
    );

    const signedImageUrls = await signedEvidenceImageUrls(
      admin,
      entry,
      correctionPhotoPath,
    );

    const { analysis, responseId } = await analyzeCorrection(
      userId,
      baseDescription,
      entry.analysis_context?.trim().slice(0, MAX_ANALYSIS_CONTEXT_LENGTH) ||
        null,
      correctionText,
      signedImageUrls,
    );

    const { data: finalized, error: finalizeFailure } = await admin.rpc(
      "finalize_entry_correction",
      {
        p_entry_id: entryId,
        p_user_id: userId,
        p_client_request_id: clientRequestId,
        p_claim_token: claimToken,
        p_correction_text: correctionText,
        p_analysis: analysis,
        p_analysis_model: ANALYSIS_MODEL,
        p_transcription_model: capture.audio ? TRANSCRIPTION_MODEL : null,
        p_provider_response_id: responseId,
        p_photo_path: correctionPhotoPath,
        p_photo_purpose: correctionPhotoPath ? "evidence" : null,
      },
    );
    if (finalizeFailure) throw finalizeFailure;
    if (finalized !== "complete") {
      throw new HttpError(
        409,
        "The meal changed while this correction was running. The previous estimate was kept.",
      );
    }
    ownsReservation = false;

    // A corrected meal in an already-summarized past week makes that week's
    // stored overview stale; re-run it after responding.
    const correctionAdmin = admin;
    const correctedUserId = userId;
    const correctedLocalDay = entry.local_day;
    runInBackground(
      refreshWeeklySummaryForDay(
        correctionAdmin,
        correctedUserId,
        correctedLocalDay,
      ).catch((refreshError) => {
        console.error("weekly_summary_refresh_failed", {
          entryId,
          message: String(refreshError),
        });
      }),
    );

    return json({
      entry_id: entryId,
      client_request_id: clientRequestId,
      status: "complete",
    });
  } catch (error) {
    const internalMessage = error instanceof Error
      ? error.message.slice(0, 500)
      : "Unknown correction error";
    if (
      ownsReservation && admin && entryId && userId && clientRequestId &&
      claimToken
    ) {
      const { error: failureWriteError } = await admin.rpc(
        "fail_entry_correction",
        {
          p_entry_id: entryId,
          p_user_id: userId,
          p_client_request_id: clientRequestId,
          p_claim_token: claimToken,
          p_error_message: internalMessage,
        },
      );
      if (failureWriteError) {
        console.error("entry_correction_failure_write_failed", {
          entryId,
          message: String(failureWriteError),
        });
      }
    }

    const status = error instanceof HttpError ? error.status : 502;
    const message = error instanceof HttpError
      ? error.message
      : "The correction couldn’t be applied. The previous estimate was kept; try again.";
    if (!(error instanceof HttpError) || status >= 500) {
      console.error("entry_correction_failed", {
        entryId,
        message: internalMessage,
      });
    }
    return json({ error: message }, status);
  }
});
