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

/// Vocabulary only. A prompt that describes the situation ("a voice message
/// to a coach…") is what gpt-4o-transcribe writes when the audio is near
/// silent — that's how "Hey Coach Sarah, today I had…" got sent for a
/// tap-tap with nothing said. A word list only nudges spelling.
const SHARED_VOCABULARY =
  "Shudo, Chipotle, pollo asado, guac, Chobani, Core Power, Greek yogurt, whey, creatine, oatmeal, PB, RDL, PR, reps, sets, macros";

export const TRANSCRIPTION_PROMPTS: Record<TranscriptionPurpose, string> = {
  meal: SHARED_VOCABULARY,
  correction: SHARED_VOCABULARY,
  onboarding: SHARED_VOCABULARY,
  coach: SHARED_VOCABULARY,
  workout: `${SHARED_VOCABULARY}, bench, squat, deadlift, incline, pull-up`,
};

/// Things the model says over silence: stock phrases, or the prompt's own
/// words echoed back. Neither is Luke talking.
const SILENCE_PHRASES =
  /^(?:thank you(?: for watching)?|thanks for watching|you|bye|okay|subtitles? by .*|transcribed by .*|\.+)[.!]?$/iu;

export function isLikelySilenceTranscript(
  text: string,
  prompt: string,
): boolean {
  const trimmed = text.trim();
  if (SILENCE_PHRASES.test(trimmed)) return true;
  const vocabulary = new Set(
    prompt.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean),
  );
  const words = trimmed.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  if (words.length === 0) return true;
  const echoed = words.filter((word) => vocabulary.has(word)).length;
  return words.length >= 3 && echoed / words.length >= 0.6;
}

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
  // Luke speaks English; left open, near-silence came back in German.
  form.append("language", "en");
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
  if (
    !text || isLikelySilenceTranscript(text, TRANSCRIPTION_PROMPTS[purpose])
  ) {
    throw new HttpError(422, "Didn't catch anything. Try again.");
  }
  return text;
}
