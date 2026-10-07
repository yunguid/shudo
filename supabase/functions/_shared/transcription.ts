import { HttpError } from "./errors.ts";
import { requiredEnv } from "./http.ts";

/// Voice is the one workload Luke keeps on OpenAI: he prefers its
/// transcription to on-device speech. Everything else runs on Claude.
export const OPENAI_TRANSCRIPTION_MODEL = "gpt-4o-transcribe";
export const OPENAI_TRANSCRIPTION_ENGINE = "openai.gpt-4o-transcribe";
export const MAX_TRANSCRIPTION_AUDIO_BYTES = 25 * 1024 * 1024;
export const TRANSCRIPTION_TIMEOUT_MS = 45_000;

export const TRANSCRIPTION_AUDIO_TYPES = new Set([
  "audio/aac",
  "audio/m4a",
  "audio/mp4",
  "audio/mpeg",
  "audio/wav",
  "audio/x-m4a",
]);

export type TranscriptionPurpose =
  | "meal"
  | "coach"
  | "correction"
  | "onboarding"
  | "workout";

export const TRANSCRIPTION_PROMPTS: Record<TranscriptionPurpose, string> = {
  meal:
    "A personal meal log. Preserve every stated food, brand, preparation, quantity, unit, sauce, drink, and correction accurately. Preserve explicit lookup, search, or online-research intent so it remains available for routing.",
  correction:
    "A correction to a personal meal log. Preserve foods, brands, quantities, portions, units, sauces, drinks, additions, and removals accurately.",
  onboarding:
    "Personal nutrition onboarding. Preserve stated goals, routines, foods, quantities, height, weight, units, allergies, dietary restrictions, dietary preferences, and corrections accurately.",
  coach:
    "A personal voice message to a fitness and nutrition coach. Preserve foods, brands, quantities, units, exercises, sets, reps, weights, distances, times, places, and names accurately.",
  workout:
    "A spoken workout log. Preserve exercise names, sets, reps, weights and units, distances, durations, and times accurately.",
};

export function parseTranscriptionPurpose(
  value: unknown,
): TranscriptionPurpose {
  const purpose = typeof value === "string" ? value.trim().toLowerCase() : "";
  if (purpose in TRANSCRIPTION_PROMPTS) return purpose as TranscriptionPurpose;
  throw new HttpError(400, "Unknown transcription purpose");
}

function audioFilename(type: string): string {
  switch (type) {
    case "audio/wav":
      return "voice.wav";
    case "audio/mpeg":
      return "voice.mp3";
    case "audio/aac":
      return "voice.aac";
    default:
      return "voice.m4a";
  }
}

export type TranscriptionDependencies = {
  fetch?: typeof fetch;
  apiKey?: string;
};

/** Transcribes one recording with OpenAI; errors are user-facing HttpErrors. */
export async function transcribeAudio(
  audio: File,
  purpose: TranscriptionPurpose,
  dependencies: TranscriptionDependencies = {},
): Promise<string> {
  if (audio.size <= 0) throw new HttpError(400, "The recording was empty");
  if (audio.size > MAX_TRANSCRIPTION_AUDIO_BYTES) {
    throw new HttpError(413, "That recording is too long to transcribe");
  }
  const type = audio.type.toLowerCase() || "audio/mp4";
  if (!TRANSCRIPTION_AUDIO_TYPES.has(type)) {
    throw new HttpError(415, "Unsupported recording format");
  }
  const form = new FormData();
  form.append("model", OPENAI_TRANSCRIPTION_MODEL);
  form.append("response_format", "json");
  form.append("prompt", TRANSCRIPTION_PROMPTS[purpose]);
  form.append(
    "file",
    new File([await audio.arrayBuffer()], audioFilename(type), { type }),
  );
  const apiKey = dependencies.apiKey ?? requiredEnv("OPENAI_API_KEY");
  let response: Response;
  try {
    response = await (dependencies.fetch ?? fetch)(
      "https://api.openai.com/v1/audio/transcriptions",
      {
        method: "POST",
        headers: { authorization: `Bearer ${apiKey}` },
        body: form,
        signal: AbortSignal.timeout(TRANSCRIPTION_TIMEOUT_MS),
      },
    );
  } catch (error) {
    if (error instanceof DOMException && error.name === "TimeoutError") {
      throw new HttpError(504, "Transcription timed out. Try again.");
    }
    throw new HttpError(502, "Transcription couldn't be reached. Try again.");
  }
  if (response.status === 429) {
    throw new HttpError(
      429,
      "Transcription is rate limited or out of OpenAI credit. Try again shortly.",
    );
  }
  if (!response.ok) {
    console.warn("transcription_failed", { status: response.status });
    throw new HttpError(502, "Transcription failed. Try again.");
  }
  const payload = await response.json().catch(() => null);
  const text = typeof payload?.text === "string" ? payload.text.trim() : "";
  if (!text) throw new HttpError(422, "Didn't catch anything. Try again.");
  return text;
}
