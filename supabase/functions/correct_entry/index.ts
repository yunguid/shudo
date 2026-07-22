import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import {
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
  parseEntryCorrectionForm,
  validateCorrectionContentLength,
} from "../_shared/entry_correction.ts";
import {
  authenticate,
  CORS_HEADERS,
  HttpError,
  json,
  requiredEnv,
} from "../_shared/http.ts";
import { requireMultipartContentType } from "../_shared/capture_validation.ts";
import { modelQuotaHttpError } from "../_shared/quotas.ts";
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
  raw_text: string | null;
  input_text: string | null;
  transcript: string | null;
  analysis_context: string | null;
  image_path: string | null;
};

async function safetyIdentifier(userId: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(userId),
  );
  return `shudo_${
    Array.from(new Uint8Array(digest)).slice(0, 16).map((byte) =>
      byte.toString(16).padStart(2, "0")
    ).join("")
  }`;
}

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
  imageUrl: string | null,
): Promise<{ analysis: ParsedAnalysis; responseId: string | null }> {
  const content: Array<Record<string, unknown>> = [{
    type: "input_text",
    text: [
      "Re-estimate the entire meal after applying the user's latest correction.",
      "The latest correction is authoritative when it conflicts with the original description or earlier corrections.",
      "Preserve every original fact that the correction does not change. Do not invent new ingredients, quantities, or preparation details.",
      "Use realistic portion assumptions only when a necessary quantity is still unavailable.",
      "Write analysis_preview first as one short natural-language sentence describing what changed.",
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
  if (imageUrl) {
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
      "id,status,raw_text,input_text,transcript,analysis_context,image_path",
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

    let transcript: string | null = null;
    if (capture.audio) {
      transcript = await transcribeCorrection(capture.audio);
    }
    const correctionText = combineEntryCorrectionText(
      capture.text,
      transcript,
    );

    let signedImageUrl: string | null = null;
    if (entry.image_path) {
      const { data: signed, error: signedError } = await admin.storage
        .from("entry-images")
        .createSignedUrl(entry.image_path, 300);
      if (signedError) throw signedError;
      signedImageUrl = signed.signedUrl;
    }

    const { analysis, responseId } = await analyzeCorrection(
      userId,
      baseDescription,
      entry.analysis_context?.trim() || null,
      correctionText,
      signedImageUrl,
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
