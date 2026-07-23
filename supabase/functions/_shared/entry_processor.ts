import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import {
  MAX_ANALYSIS_CONTEXT_LENGTH,
  parseAnalysis,
  type ParsedAnalysis,
  RESULT_SCHEMA,
} from "./analysis.ts";
import { AnalysisPreviewPublisher } from "./analysis_preview.ts";
import {
  assertNeutralGeneratedCopy,
  NEUTRAL_PRODUCT_COPY_INSTRUCTION,
} from "./generated_copy.ts";
import { requiredEnv, withTimeout } from "./http.ts";
import { readResponsesEventStream } from "./responses_stream.ts";
import { safetyIdentifier } from "./safety.ts";
import { drainStorageCleanup } from "./storage_cleanup.ts";

export const ANALYSIS_MODEL = "gpt-5.6-sol";
export const TRANSCRIPTION_MODEL = "gpt-4o-transcribe";
export const PROCESSING_BUDGET_MS = 150_000;
export const TRANSCRIPTION_TIMEOUT_MS = 60_000;
export const ANALYSIS_TIMEOUT_MS = 65_000;
export const PROCESSING_OVERHEAD_RESERVE_MS = 25_000;
export const MEAL_COPY_INSTRUCTION =
  `${NEUTRAL_PRODUCT_COPY_INSTRUCTION} Describe only the meal and any clearly labeled estimate assumptions.`;
const MAX_AUDIO_BYTES = 25 * 1024 * 1024;
const MAX_COMBINED_TEXT_LENGTH = 30_000;

type StoredEntry = {
  id: string;
  input_text: string | null;
  transcript: string | null;
  raw_text: string | null;
  analysis_context: string | null;
  image_path: string | null;
  audio_path: string | null;
  transcription_model: string | null;
};

class LostProcessingLeaseError extends Error {}

async function updateEntry(
  admin: SupabaseClient,
  entryId: string,
  userId: string,
  processingAttempt: number,
  values: Record<string, unknown>,
): Promise<void> {
  const { data, error } = await admin.from("entries").update(values)
    .eq("id", entryId)
    .eq("user_id", userId)
    .eq("processing_attempts", processingAttempt)
    .in("status", ["transcribing", "analyzing"])
    .select("id")
    .maybeSingle();
  if (error) throw error;
  if (!data) {
    throw new LostProcessingLeaseError("Processing lease was replaced");
  }
}

async function claimEntry(
  admin: SupabaseClient,
  entryId: string,
  userId: string,
): Promise<number | null> {
  const { data, error } = await admin.rpc("claim_entry_processing", {
    p_entry_id: entryId,
    p_user_id: userId,
  });
  if (error) throw error;
  const attempt = typeof data === "number" ? data : Number(data);
  return Number.isInteger(attempt) && attempt > 0 ? attempt : null;
}

function audioType(path: string, blob: Blob): string {
  if (blob.type) return blob.type;
  if (path.endsWith(".wav")) return "audio/wav";
  if (path.endsWith(".mp3")) return "audio/mpeg";
  return "audio/mp4";
}

function audioFilename(path: string): string {
  const extension = path.split(".").pop()?.toLowerCase();
  return `meal.${extension && extension.length <= 4 ? extension : "m4a"}`;
}

async function transcribe(audio: Blob, path: string): Promise<string> {
  if (audio.size <= 0 || audio.size > MAX_AUDIO_BYTES) {
    throw new Error("Stored voice note has an invalid size");
  }
  const form = new FormData();
  form.append("model", TRANSCRIPTION_MODEL);
  form.append("response_format", "json");
  form.append(
    "prompt",
    "A personal meal log. Preserve foods, brands, quantities, units, sauces, drinks, and corrections accurately.",
  );
  form.append(
    "file",
    new File([await audio.arrayBuffer()], audioFilename(path), {
      type: audioType(path, audio),
    }),
  );

  const response = await fetch(
    "https://api.openai.com/v1/audio/transcriptions",
    {
      method: "POST",
      headers: { authorization: `Bearer ${requiredEnv("OPENAI_API_KEY")}` },
      body: form,
      signal: AbortSignal.timeout(TRANSCRIPTION_TIMEOUT_MS),
    },
  );
  if (!response.ok) {
    throw new Error(`Transcription failed (${response.status})`);
  }
  const payload = await response.json();
  const text = typeof payload?.text === "string" ? payload.text.trim() : "";
  if (!text) throw new Error("Transcription was empty");
  return text;
}

async function analyze(
  userId: string,
  combinedText: string,
  analysisContext: string | null,
  imageUrl: string | null,
  publishPreview: (preview: string) => Promise<void>,
): Promise<{ analysis: ParsedAnalysis; responseId: string | null }> {
  const content: Array<Record<string, unknown>> = [{
    type: "input_text",
    text: [
      "Estimate the nutrition for this meal from the description and photo.",
      "Use realistic portion assumptions when exact amounts are unavailable.",
      "Write analysis_preview first as a short, warm, natural-language sentence summarizing the meal and its likely quantities. Never put JSON syntax in that sentence.",
      MEAL_COPY_INSTRUCTION,
      "Keep the title short and useful in a meal history.",
      "Make item totals internally consistent with the meal totals.",
      `Description and transcript:\n${
        combinedText || "No written description was provided."
      }`,
      analysisContext
        ? `User correction history, newest first. The first correction overrides conflicting details listed later:\n${analysisContext}`
        : "",
    ].join("\n"),
  }];
  if (imageUrl) {
    content.push({ type: "input_image", image_url: imageUrl, detail: "high" });
  }

  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      authorization: `Bearer ${requiredEnv("OPENAI_API_KEY")}`,
      accept: "text/event-stream",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      model: ANALYSIS_MODEL,
      stream: true,
      reasoning: { effort: "low" },
      input: [{ role: "user", content }],
      text: {
        verbosity: "low",
        format: {
          type: "json_schema",
          name: "shudo_meal_analysis",
          strict: true,
          schema: RESULT_SCHEMA,
        },
      },
      max_output_tokens: 2_500,
      safety_identifier: await safetyIdentifier(userId),
      store: false,
    }),
    signal: AbortSignal.timeout(ANALYSIS_TIMEOUT_MS),
  });
  if (!response.ok) {
    throw new Error(`Meal analysis failed (${response.status})`);
  }
  if (!response.body) throw new Error("Meal analysis returned no stream");

  const previewPublisher = new AnalysisPreviewPublisher(publishPreview);
  const { outputText, responseId } = await readResponsesEventStream(
    response.body,
    (partialOutput) => previewPublisher.observe(partialOutput),
  );
  return {
    analysis: parseAnalysis(JSON.parse(outputText)),
    responseId,
  };
}

export async function processStoredEntry(
  admin: SupabaseClient,
  entryId: string,
  userId: string,
): Promise<void> {
  let audioPath: string | null = null;
  let processingAttempt: number | null = null;
  try {
    processingAttempt = await claimEntry(admin, entryId, userId);
    if (processingAttempt === null) return;
    const activeProcessingAttempt = processingAttempt;

    const { data, error } = await admin.from("entries")
      .select(
        "id,input_text,transcript,raw_text,analysis_context,image_path,audio_path,transcription_model",
      )
      .eq("id", entryId)
      .eq("user_id", userId)
      .eq("processing_attempts", processingAttempt)
      .in("status", ["transcribing", "analyzing"])
      .maybeSingle();
    if (error) throw error;
    if (!data) {
      throw new LostProcessingLeaseError("Processing lease was replaced");
    }
    const entry = data as StoredEntry;
    audioPath = entry.audio_path;
    let transcript = entry.transcript?.trim() ?? "";

    // Signing the photo URL is independent of transcription, so it starts
    // now and is awaited only when analysis needs it. The tagged result
    // keeps an abandoned failure from becoming an unhandled rejection.
    const pendingSignedImageUrl = entry.image_path
      ? withTimeout(
        admin.storage.from("entry-images")
          .createSignedUrl(entry.image_path, 600)
          .then(({ data: signed, error: signedError }) => {
            if (signedError || !signed) {
              throw signedError ?? new Error("Photo could not be signed");
            }
            return signed.signedUrl;
          }),
        15_000,
        "Photo signing",
      ).then(
        (url) => ({ ok: true as const, url }),
        (error) => ({ ok: false as const, error }),
      )
      : null;

    if (audioPath && !transcript) {
      const { data: audio, error: downloadError } = await withTimeout(
        admin.storage.from("entry-audio").download(audioPath),
        30_000,
        "Voice note download",
      );
      if (downloadError || !audio) {
        throw downloadError ?? new Error("Stored voice note is missing");
      }
      transcript = await transcribe(audio, audioPath);
      const combined = [entry.input_text, transcript].filter(Boolean).join("\n")
        .trim().slice(0, MAX_COMBINED_TEXT_LENGTH);
      await updateEntry(admin, entryId, userId, processingAttempt, {
        transcript,
        raw_text: combined,
        status: "analyzing",
        status_message: "Estimating your meal",
        analysis_preview: null,
        transcription_model: TRANSCRIPTION_MODEL,
        lease_expires_at: new Date(Date.now() + 135_000).toISOString(),
      });
    }

    // Once transcription is durable, detach the raw recording and enqueue its
    // deletion in the same database transaction. Storage cleanup is retried by
    // the durable queue even if this worker is stopped.
    if (audioPath && transcript) {
      const { data: detached, error: detachError } = await admin.rpc(
        "detach_entry_audio",
        {
          p_entry_id: entryId,
          p_user_id: userId,
          p_processing_attempt: processingAttempt,
          p_audio_path: audioPath,
        },
      );
      if (detachError) throw detachError;
      if (detached !== true) {
        throw new LostProcessingLeaseError("Processing lease was replaced");
      }
      audioPath = null;
    }

    const combinedText = (
      [entry.input_text, transcript].filter(Boolean).join("\n").trim() ||
      entry.raw_text?.trim() ||
      ""
    ).slice(0, MAX_COMBINED_TEXT_LENGTH);
    if (!combinedText && !entry.image_path) {
      throw new Error("Meal entry has no usable text, voice note, or image");
    }

    let signedImageUrl: string | null = null;
    if (pendingSignedImageUrl) {
      const signed = await pendingSignedImageUrl;
      if (!signed.ok) throw signed.error;
      signedImageUrl = signed.url;
    }

    const { analysis, responseId } = await analyze(
      userId,
      combinedText,
      entry.analysis_context?.trim().slice(0, MAX_ANALYSIS_CONTEXT_LENGTH) ||
        null,
      signedImageUrl,
      async (preview) => {
        // Streaming output is visible before the complete JSON object reaches
        // parseAnalysis, so enforce the same copy policy at this boundary too.
        assertNeutralGeneratedCopy(preview, "analysis preview");
        try {
          await updateEntry(
            admin,
            entryId,
            userId,
            activeProcessingAttempt,
            { analysis_preview: preview },
          );
        } catch (previewError) {
          if (previewError instanceof LostProcessingLeaseError) {
            throw previewError;
          }
          // A transient preview write must not discard an otherwise valid meal
          // analysis. The final fenced update remains mandatory and atomic.
          console.warn("entry_analysis_preview_update_failed", {
            entryId,
            message: String(previewError),
          });
        }
      },
    );
    await updateEntry(admin, entryId, userId, processingAttempt, {
      status: "complete",
      status_message: "Ready",
      analysis_preview: null,
      title: analysis.title,
      raw_text: combinedText,
      transcript: transcript || null,
      audio_path: audioPath,
      protein_g: analysis.totals.protein_g,
      carbs_g: analysis.totals.carbs_g,
      fat_g: analysis.totals.fat_g,
      calories_kcal: analysis.totals.calories_kcal,
      confidence: analysis.confidence,
      items: analysis.items,
      analysis_notes: analysis.notes,
      error_message: null,
      provider_response_id: responseId,
      analysis_model: ANALYSIS_MODEL,
      transcription_model: transcript
        ? entry.transcription_model ?? TRANSCRIPTION_MODEL
        : null,
      processed_at: new Date().toISOString(),
      lease_expires_at: null,
    });
    // Analysis is already durable and visible before best-effort cleanup does
    // any remote Storage work. The outbox + scheduled drainer remain the retry
    // guarantee if this worker is stopped here.
    await drainStorageCleanup(admin, 5).catch((cleanupError) => {
      console.error("opportunistic_storage_cleanup_failed", {
        entryId,
        message: String(cleanupError),
      });
    });
  } catch (error) {
    if (error instanceof LostProcessingLeaseError) {
      console.info("entry_processing_lease_replaced", { entryId });
      return;
    }
    const message = error instanceof Error
      ? error.message.slice(0, 500)
      : "Unknown processing error";
    console.error("entry_processing_failed", { entryId, message });
    try {
      if (processingAttempt === null) return;
      await updateEntry(admin, entryId, userId, processingAttempt, {
        status: "failed",
        status_message: "Could not finish this meal",
        analysis_preview: null,
        error_message: message,
        lease_expires_at: null,
      });
    } catch (updateError) {
      console.error("entry_failure_state_update_failed", {
        entryId,
        message: String(updateError),
      });
    }
  }
}
