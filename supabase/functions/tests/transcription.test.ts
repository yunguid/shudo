import { HttpError } from "../_shared/errors.ts";
import {
  isLikelySilenceTranscript,
  OPENAI_FALLBACK_TRANSCRIPTION_MODEL,
  OPENAI_TRANSCRIPTION_MODEL,
  parseTranscriptionPurpose,
  transcribeAudio,
  TRANSCRIPTION_KEYWORDS,
  TRANSCRIPTION_PROMPTS,
} from "../_shared/transcription.ts";
import { assert, assertEquals } from "./assertions.ts";

function recording(bytes = 64, type = "audio/mp4"): File {
  return new File([new Uint8Array(bytes)], "voice.m4a", { type });
}

/// A fake OpenAI that answers per model and records every request's form.
function provider(
  answers: Record<string, () => Response>,
): { fetch: typeof fetch; forms: FormData[] } {
  const forms: FormData[] = [];
  const fetcher = ((_url: string | URL | Request, init?: RequestInit) => {
    const form = init?.body as FormData;
    forms.push(form);
    return Promise.resolve(answers[String(form.get("model"))]());
  }) as typeof fetch;
  return { fetch: fetcher, forms };
}

function text(value: string): () => Response {
  return () => new Response(JSON.stringify({ text: value }), { status: 200 });
}

function status(code: number): () => Response {
  return () => new Response("{}", { status: code });
}

Deno.test("transcription asks gpt-transcribe with the purpose keywords, chunked at pauses", async () => {
  const openai = provider({
    [OPENAI_TRANSCRIPTION_MODEL]: text("  bench went up today  "),
  });
  const result = await transcribeAudio(recording(), "workout", {}, {
    apiKey: "test-key-not-a-secret",
    fetch: openai.fetch,
  });
  assertEquals(result.text, "bench went up today");
  assertEquals(result.model, OPENAI_TRANSCRIPTION_MODEL);
  assertEquals(openai.forms.length, 1);
  const form = openai.forms[0];
  assertEquals(form.get("chunking_strategy"), "auto");
  assertEquals(form.getAll("keywords[]"), TRANSCRIPTION_KEYWORDS.workout);
  assertEquals(form.getAll("languages[]"), ["en"]);
  // gpt-transcribe rejects `language` alongside `languages`.
  assertEquals(form.get("language"), null);
  assert(form.get("file") instanceof File);
});

Deno.test("transcription maps provider failures to user-facing errors", async () => {
  const cases: Array<[number, number]> = [[429, 429], [500, 502]];
  for (const [providerStatus, expected] of cases) {
    let caught: unknown = null;
    try {
      await transcribeAudio(recording(), "meal", {}, {
        apiKey: "test-key-not-a-secret",
        fetch: provider({
          [OPENAI_TRANSCRIPTION_MODEL]: status(providerStatus),
          [OPENAI_FALLBACK_TRANSCRIPTION_MODEL]: status(providerStatus),
        }).fetch,
      });
    } catch (error) {
      caught = error;
    }
    assert(caught instanceof HttpError);
    assertEquals((caught as HttpError).status, expected);
  }
});

Deno.test("transcription rejects empty, oversized and unknown inputs", async () => {
  for (
    const [file, status] of [[recording(0), 400], [
      recording(64, "video/mp4"),
      415,
    ]] as const
  ) {
    let caught: unknown = null;
    try {
      await transcribeAudio(file, "meal", {}, { apiKey: "x", fetch: fetch });
    } catch (error) {
      caught = error;
    }
    assertEquals((caught as HttpError).status, status);
  }
  let purposeError: unknown = null;
  try {
    parseTranscriptionPurpose("constructor");
  } catch (error) {
    purposeError = error;
  }
  assertEquals((purposeError as HttpError).status, 400);
  assertEquals(parseTranscriptionPurpose(" Coach "), "coach");
});

/// The invariant behind "it cuts off what I'm saying": a transcript that is
/// missing, stock, or far too short for the voice the phone measured gets
/// exactly one second opinion, and the fuller transcript is what Luke gets.
Deno.test("a transcript missing speech gets one second opinion and the fuller one wins", async () => {
  const dependencies = (openai: { fetch: typeof fetch }) => ({
    apiKey: "test-key-not-a-secret",
    fetch: openai.fetch,
  });
  const full =
    "Had two eggs and toast this morning, then a Chobani after the gym, and I think lunch was a Chipotle bowl with pollo asado, double chicken, no rice.";

  // Only the first sentence came back for twenty seconds of voice.
  let openai = provider({
    [OPENAI_TRANSCRIPTION_MODEL]: text("Had two eggs and toast this morning."),
    [OPENAI_FALLBACK_TRANSCRIPTION_MODEL]: text(full),
  });
  let result = await transcribeAudio(
    recording(),
    "meal",
    { audioSeconds: 24, voicedSeconds: 20 },
    dependencies(openai),
  );
  assertEquals(result.text, full);
  assertEquals(result.model, OPENAI_FALLBACK_TRANSCRIPTION_MODEL);
  assertEquals(result.fallback, "sparse");
  assertEquals(openai.forms.length, 2);
  assertEquals(openai.forms[1].get("chunking_strategy"), "auto");
  assertEquals(openai.forms[1].get("prompt"), TRANSCRIPTION_PROMPTS.meal);

  // A shorter second opinion never replaces the first.
  openai = provider({
    [OPENAI_TRANSCRIPTION_MODEL]: text(full),
    [OPENAI_FALLBACK_TRANSCRIPTION_MODEL]: text("Two eggs."),
  });
  result = await transcribeAudio(
    recording(),
    "meal",
    { audioSeconds: 60, voicedSeconds: 50 },
    dependencies(openai),
  );
  assertEquals(result.text, full);
  assertEquals(result.model, OPENAI_TRANSCRIPTION_MODEL);
  assertEquals(openai.forms.length, 2);

  // Silence back while the phone heard Luke, or a rejected request: the
  // second model answers.
  for (
    const [first, reason] of [[text("Thank you."), "silent"], [
      status(400),
      "failed",
    ]] as const
  ) {
    openai = provider({
      [OPENAI_TRANSCRIPTION_MODEL]: first,
      [OPENAI_FALLBACK_TRANSCRIPTION_MODEL]: text("Creatine and whey."),
    });
    result = await transcribeAudio(
      recording(),
      "coach",
      { audioSeconds: 3, voicedSeconds: 2 },
      dependencies(openai),
    );
    assertEquals(result.text, "Creatine and whey.");
    assertEquals(result.fallback, reason);
  }

  // A complete answer is one request.
  openai = provider({ [OPENAI_TRANSCRIPTION_MODEL]: text(full) });
  result = await transcribeAudio(
    recording(),
    "meal",
    { audioSeconds: 12, voicedSeconds: 10 },
    dependencies(openai),
  );
  assertEquals(result.fallback, "none");
  assertEquals(openai.forms.length, 1);
});

Deno.test("silence transcripts (stock phrases, the vocabulary echoed) never reach Luke's thread", () => {
  const prompt = TRANSCRIPTION_PROMPTS.coach;
  assertEquals(
    isLikelySilenceTranscript("Thank you for watching.", prompt),
    true,
  );
  assertEquals(
    isLikelySilenceTranscript("Shudo, Chipotle, guac, Core Power.", prompt),
    true,
  );
  assertEquals(
    isLikelySilenceTranscript(
      "I had a Chipotle bowl with pollo asado and guac.",
      prompt,
    ),
    false,
  );
  // Real speech that is mostly vocabulary still has words between terms.
  assertEquals(isLikelySilenceTranscript("Creatine and whey.", prompt), false);
  assertEquals(
    isLikelySilenceTranscript("Blasting two IR addys", prompt),
    false,
  );
});
