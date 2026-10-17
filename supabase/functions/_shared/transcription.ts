import { HttpError } from "./errors.ts";
import { requiredEnv } from "./http.ts";

/// Voice is the one workload Luke keeps on OpenAI: he prefers its
/// transcription to on-device speech. Everything else runs on Claude.
///
/// `gpt-transcribe` is OpenAI's file-transcription model since July 2026.
/// `gpt-4o-transcribe`, used before, is deprecated (gone February 26, 2027)
/// and, sent a recording as one block, is known to drop whole sentences
/// after a pause or at the end — Luke's "it cuts off what I'm saying".
export const OPENAI_TRANSCRIPTION_MODEL = "gpt-transcribe";
/// The second opinion when the first transcript is missing or far too short
/// for how long Luke spoke: a different model (OpenAI's own pick over
/// gpt-4o-transcribe), so one model's blind spot can't eat a take.
export const OPENAI_FALLBACK_TRANSCRIPTION_MODEL = "gpt-4o-mini-transcribe";
/// Wire id for "Shudo's OpenAI transcription" (the capture_validation
/// allowlist, the app's SpeechEngineID). Stable across model changes; the
/// response's `model` names the one that ran.
export const OPENAI_TRANSCRIPTION_ENGINE = "openai.gpt-4o-transcribe";
export const MAX_TRANSCRIPTION_AUDIO_BYTES = 25 * 1024 * 1024;
/// First pass plus any second opinion answer inside the app's 45 s wait.
export const TRANSCRIPTION_BUDGET_MS = 40_000;
const PRIMARY_TIMEOUT_MS = 25_000;
/// A second opinion needs at least this much of the budget left.
const MINIMUM_FALLBACK_MS = 5_000;

/// People say two to three words a second; a transcript under this rate for
/// the voice the phone measured is missing speech (a sentence dropped after
/// a pause, only the first one kept), not slow talking.
export const MINIMUM_WORDS_PER_VOICED_SECOND = 1.2;
/// Below this much voice the rate says nothing (a "two eggs" take).
const GUARD_MINIMUM_VOICED_SECONDS = 4;
/// With at least this much voice measured, an empty or stock-phrase reply is
/// the model missing Luke, not Luke saying nothing.
const SPEECH_PRESENT_VOICED_SECONDS = 1;
/// Builds that don't measure voice yet: about six seconds of the app's
/// 64 kbps AAC.
const SPEECH_PRESENT_UNMEASURED_BYTES = 48_000;

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
const SHARED_VOCABULARY = [
  "Shudo",
  "Chipotle",
  "pollo asado",
  "guac",
  "Chobani",
  "Core Power",
  "Greek yogurt",
  "whey",
  "creatine",
  "oatmeal",
  "PB",
  "RDL",
  "PR",
  "reps",
  "sets",
  "macros",
];

const WORKOUT_VOCABULARY = [
  ...SHARED_VOCABULARY,
  "bench",
  "squat",
  "deadlift",
  "incline",
  "pull-up",
];

/// `keywords[]` for gpt-transcribe: literal terms Luke says.
export const TRANSCRIPTION_KEYWORDS: Record<TranscriptionPurpose, string[]> = {
  meal: SHARED_VOCABULARY,
  correction: SHARED_VOCABULARY,
  onboarding: SHARED_VOCABULARY,
  coach: SHARED_VOCABULARY,
  workout: WORKOUT_VOCABULARY,
};

/// The same terms as a `prompt` for the gpt-4o family (no `keywords`).
export const TRANSCRIPTION_PROMPTS: Record<TranscriptionPurpose, string> = {
  meal: SHARED_VOCABULARY.join(", "),
  correction: SHARED_VOCABULARY.join(", "),
  onboarding: SHARED_VOCABULARY.join(", "),
  coach: SHARED_VOCABULARY.join(", "),
  workout: WORKOUT_VOCABULARY.join(", "),
};

/// Things a model says over silence: stock phrases, or the vocabulary
/// echoed back. Neither is Luke talking.
const SILENCE_PHRASES =
  /^(?:thank you(?: for watching)?|thanks for watching|you|bye|okay|subtitles? by .*|transcribed by .*|\.+)[.!]?$/iu;

/// An echo is the term list itself. Real speech carries words between the
/// terms ("creatine and whey"), so a sentence that merely mentions several
/// of them is never mistaken for one.
const ECHO_VOCABULARY_SHARE = 0.85;

function wordsOf(text: string): string[] {
  return text.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);
}

export function countWords(text: string): number {
  return wordsOf(text).length;
}

export function isLikelySilenceTranscript(
  text: string,
  vocabulary: string,
): boolean {
  const trimmed = text.trim();
  if (SILENCE_PHRASES.test(trimmed)) return true;
  const terms = new Set(wordsOf(vocabulary));
  const words = wordsOf(trimmed);
  if (words.length === 0) return true;
  const echoed = words.filter((word) => terms.has(word)).length;
  return words.length >= 3 && echoed / words.length >= ECHO_VOCABULARY_SHARE;
}

export function parseTranscriptionPurpose(
  value: unknown,
): TranscriptionPurpose {
  const purpose = typeof value === "string" ? value.trim().toLowerCase() : "";
  if (Object.hasOwn(TRANSCRIPTION_PROMPTS, purpose)) {
    return purpose as TranscriptionPurpose;
  }
  throw new HttpError(400, "Unknown transcription purpose");
}

/// What the phone measured while recording (seconds). Optional: older builds
/// don't send it, and the guard simply stays off for them.
export type TakeMeasurements = {
  audioSeconds?: number;
  voicedSeconds?: number;
};

/// A form field of seconds, or undefined when absent or nonsense.
export function parseSeconds(value: string): number | undefined {
  if (!value) return undefined;
  const seconds = Number(value);
  return Number.isFinite(seconds) && seconds >= 0 && seconds <= 3_600
    ? seconds
    : undefined;
}

/// Why the second model ran, if it did.
export type TranscriptionFallback =
  | "none"
  | "failed"
  | "silent"
  | "sparse";

export type TranscriptionResult = {
  text: string;
  model: string;
  fallback: TranscriptionFallback;
};

/// Whether `text` holds as many words as `voicedSeconds` of speech should.
export function isPlausiblyComplete(
  text: string,
  voicedSeconds: number | undefined,
): boolean {
  if (voicedSeconds === undefined) return true;
  if (voicedSeconds < GUARD_MINIMUM_VOICED_SECONDS) return true;
  return countWords(text) >= voicedSeconds * MINIMUM_WORDS_PER_VOICED_SECOND;
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
  now?: () => number;
};

type Attempt =
  | { ok: true; text: string }
  | { ok: false; status: number };

/// One request to one model. Both cut the audio at pauses
/// (`chunking_strategy: auto`: loudness-normalized voice detection) instead
/// of transcribing it as one block, which is where speech after a pause
/// went missing.
async function attempt(
  model: string,
  file: File,
  purpose: TranscriptionPurpose,
  timeoutMs: number,
  apiKey: string,
  fetcher: typeof fetch,
): Promise<Attempt> {
  const form = new FormData();
  form.append("model", model);
  form.append("chunking_strategy", "auto");
  if (model === OPENAI_TRANSCRIPTION_MODEL) {
    // gpt-transcribe takes literal terms as keywords and a language list
    // (never alongside the singular `language`).
    for (const keyword of TRANSCRIPTION_KEYWORDS[purpose]) {
      form.append("keywords[]", keyword);
    }
    form.append("languages[]", "en");
  } else {
    form.append("response_format", "json");
    form.append("prompt", TRANSCRIPTION_PROMPTS[purpose]);
    // Luke speaks English; left open, near-silence came back in German.
    form.append("language", "en");
  }
  form.append("file", file);
  let response: Response;
  try {
    response = await fetcher("https://api.openai.com/v1/audio/transcriptions", {
      method: "POST",
      headers: { authorization: `Bearer ${apiKey}` },
      body: form,
      signal: AbortSignal.timeout(Math.max(1, timeoutMs)),
    });
  } catch (error) {
    const timedOut = error instanceof DOMException &&
      error.name === "TimeoutError";
    return { ok: false, status: timedOut ? 504 : 502 };
  }
  if (!response.ok) {
    await response.body?.cancel().catch(() => undefined);
    return { ok: false, status: response.status };
  }
  const payload = await response.json().catch(() => null);
  const text = typeof payload?.text === "string" ? payload.text.trim() : "";
  return { ok: true, text };
}

function failure(status: number): HttpError {
  if (status === 429) {
    return new HttpError(
      429,
      "Transcription is rate limited or out of OpenAI credit. Try again shortly.",
    );
  }
  if (status === 504) {
    return new HttpError(504, "Transcription timed out. Try again.");
  }
  return new HttpError(502, "Transcription failed. Try again.");
}

/// Transcribes one recording with OpenAI; errors are user-facing HttpErrors.
///
/// Complete by construction: the first model's answer stands unless it
/// failed, came back empty or stock while the phone heard Luke talking, or
/// holds far fewer words than the voice the phone measured. Then a second
/// model hears the same audio once, and the fuller transcript wins.
export async function transcribeAudio(
  audio: File,
  purpose: TranscriptionPurpose,
  measurements: TakeMeasurements = {},
  dependencies: TranscriptionDependencies = {},
): Promise<TranscriptionResult> {
  if (audio.size <= 0) throw new HttpError(400, "The recording was empty");
  if (audio.size > MAX_TRANSCRIPTION_AUDIO_BYTES) {
    throw new HttpError(413, "That recording is too long to transcribe");
  }
  const type = audio.type.toLowerCase() || "audio/mp4";
  if (!TRANSCRIPTION_AUDIO_TYPES.has(type)) {
    throw new HttpError(415, "Unsupported recording format");
  }
  const file = new File([await audio.arrayBuffer()], audioFilename(type), {
    type,
  });
  const apiKey = dependencies.apiKey ?? requiredEnv("OPENAI_API_KEY");
  const fetcher = dependencies.fetch ?? fetch;
  const now = dependencies.now ?? Date.now;
  const vocabulary = TRANSCRIPTION_PROMPTS[purpose];
  const voiced = measurements.voicedSeconds;
  const heardSpeech = voiced === undefined
    ? audio.size >= SPEECH_PRESENT_UNMEASURED_BYTES
    : voiced >= SPEECH_PRESENT_VOICED_SECONDS;
  const startedAt = now();

  const usable = (result: Attempt): string | null =>
    result.ok && result.text &&
      !isLikelySilenceTranscript(result.text, vocabulary)
      ? result.text
      : null;

  const primary = await attempt(
    OPENAI_TRANSCRIPTION_MODEL,
    file,
    purpose,
    PRIMARY_TIMEOUT_MS,
    apiKey,
    fetcher,
  );
  const primaryText = usable(primary);
  let fallback: TranscriptionFallback = "none";
  if (!primary.ok) {
    // Out of credit or rate limited applies to every model.
    if (primary.status !== 429) fallback = "failed";
  } else if (primaryText === null) {
    if (heardSpeech) fallback = "silent";
  } else if (!isPlausiblyComplete(primaryText, voiced)) {
    fallback = "sparse";
  }
  const remainingMs = TRANSCRIPTION_BUDGET_MS - (now() - startedAt);
  if (fallback !== "none" && remainingMs < MINIMUM_FALLBACK_MS) {
    fallback = "none";
  }

  let secondText: string | null = null;
  let second: Attempt | null = null;
  if (fallback !== "none") {
    second = await attempt(
      OPENAI_FALLBACK_TRANSCRIPTION_MODEL,
      file,
      purpose,
      remainingMs,
      apiKey,
      fetcher,
    );
    secondText = usable(second);
  }

  // The fuller transcript wins; a tie keeps the first model's.
  let text = primaryText;
  let model = OPENAI_TRANSCRIPTION_MODEL;
  if (
    secondText !== null &&
    (text === null || countWords(secondText) > countWords(text))
  ) {
    text = secondText;
    model = OPENAI_FALLBACK_TRANSCRIPTION_MODEL;
  }

  // Privacy-safe: sizes, timings and counts — never the words.
  console.log("transcribe_done", {
    purpose,
    bytes: audio.size,
    audio_s: measurements.audioSeconds ?? null,
    voiced_s: voiced ?? null,
    model: text === null ? null : model,
    words: text === null ? 0 : countWords(text),
    primary: primary.ok
      ? (primaryText === null ? "silent" : countWords(primaryText))
      : primary.status,
    fallback,
    second: second === null
      ? null
      : second.ok
      ? (secondText === null ? "silent" : countWords(secondText))
      : second.status,
    ms: now() - startedAt,
  });

  if (text !== null) return { text, model, fallback };
  const failed = [primary, second].find(
    (result): result is Extract<Attempt, { ok: false }> =>
      result !== null && !result.ok,
  );
  // A model that answered, but with silence, outranks one that errored:
  // the audio was heard and held nothing.
  if (primary.ok || second?.ok) {
    throw new HttpError(422, "Didn't catch anything. Try again.");
  }
  throw failure(failed?.status ?? 502);
}
