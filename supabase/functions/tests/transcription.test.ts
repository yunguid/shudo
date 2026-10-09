import { HttpError } from "../_shared/errors.ts";
import {
  isLikelySilenceTranscript,
  OPENAI_TRANSCRIPTION_MODEL,
  parseTranscriptionPurpose,
  transcribeAudio,
  TRANSCRIPTION_PROMPTS,
} from "../_shared/transcription.ts";
import { assert, assertEquals } from "./assertions.ts";

function recording(bytes = 64, type = "audio/mp4"): File {
  return new File([new Uint8Array(bytes)], "voice.m4a", { type });
}

Deno.test("transcription sends the purpose prompt and returns trimmed text", async () => {
  let sent: FormData | null = null;
  const text = await transcribeAudio(recording(), "coach", {
    apiKey: "test-key-not-a-secret",
    fetch: ((_url: string | URL | Request, init?: RequestInit) => {
      sent = init?.body as FormData;
      return Promise.resolve(
        new Response(JSON.stringify({ text: "  bench went up today  " }), {
          status: 200,
        }),
      );
    }) as typeof fetch,
  });
  assertEquals(text, "bench went up today");
  const form = sent as unknown as FormData;
  assertEquals(form.get("model"), OPENAI_TRANSCRIPTION_MODEL);
  assertEquals(form.get("prompt"), TRANSCRIPTION_PROMPTS.coach);
  assert(form.get("file") instanceof File);
});

Deno.test("transcription maps provider failures to user-facing errors", async () => {
  const cases: Array<[number, number]> = [[429, 429], [500, 502]];
  for (const [providerStatus, expected] of cases) {
    let caught: unknown = null;
    try {
      await transcribeAudio(recording(), "meal", {
        apiKey: "test-key-not-a-secret",
        fetch: (() =>
          Promise.resolve(
            new Response("{}", { status: providerStatus }),
          )) as typeof fetch,
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
      await transcribeAudio(file, "meal", { apiKey: "x", fetch: fetch });
    } catch (error) {
      caught = error;
    }
    assertEquals((caught as HttpError).status, status);
  }
  let purposeError: unknown = null;
  try {
    parseTranscriptionPurpose("diary");
  } catch (error) {
    purposeError = error;
  }
  assertEquals((purposeError as HttpError).status, 400);
  assertEquals(parseTranscriptionPurpose(" Coach "), "coach");
});

Deno.test("silence transcripts (stock phrases, the prompt echoed) never reach Luke's thread", () => {
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
  assertEquals(
    isLikelySilenceTranscript("Blasting two IR addys", prompt),
    false,
  );
});
