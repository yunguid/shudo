import { responseOutputText } from "./analysis.ts";
import {
  responseWebSearchMetadata,
  type WebSearchSource,
} from "./meal_research.ts";

export const MAX_STREAMED_OUTPUT_CHARACTERS = 40_000;

export type ResponsesStreamResult = {
  outputText: string;
  responseId: string | null;
  webSearchUsed: boolean;
  webSearchSources: WebSearchSource[];
};

type OutputObserver = (outputText: string) => Promise<void>;

/**
 * Coarse, user-meaningful moments observed in the provider stream. Each is
 * reported at most once, in stream order, so callers can surface honest
 * progress without inventing states the stream never confirmed.
 */
export type ResponsesStreamPhase =
  | "web_search_started"
  | "web_search_completed"
  | "output_started";

type PhaseObserver = (phase: ResponsesStreamPhase) => Promise<void>;

type SSEMessage = {
  event: string | null;
  data: string;
};

function parseSSEMessage(block: string): SSEMessage | null {
  let event: string | null = null;
  const data: string[] = [];
  for (const line of block.split(/\r\n|\r|\n/)) {
    if (!line || line.startsWith(":")) continue;
    const separator = line.indexOf(":");
    const field = separator < 0 ? line : line.slice(0, separator);
    let value = separator < 0 ? "" : line.slice(separator + 1);
    if (value.startsWith(" ")) value = value.slice(1);
    if (field === "event") event = value;
    if (field === "data") data.push(value);
  }
  return data.length > 0 ? { event, data: data.join("\n") } : null;
}

function responseFromEvent(
  payload: Record<string, unknown>,
): Record<string, unknown> | null {
  const response = payload.response;
  return response && typeof response === "object" && !Array.isArray(response)
    ? response as Record<string, unknown>
    : null;
}

function checkedOutput(value: string): string {
  if (Array.from(value).length > MAX_STREAMED_OUTPUT_CHARACTERS) {
    throw new Error("Meal analysis output exceeded its safe limit");
  }
  return value;
}

/** Reads the Responses API SSE protocol and requires a terminal completed event. */
export async function readResponsesEventStream(
  stream: ReadableStream<Uint8Array>,
  observeOutput: OutputObserver = () => Promise.resolve(),
  observePhase: PhaseObserver = () => Promise.resolve(),
): Promise<ResponsesStreamResult> {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let buffered = "";
  let outputText = "";
  let responseId: string | null = null;
  let webSearchUsed = false;
  const webSearchSourceUrls = new Set<string>();
  let completed = false;
  const reportedPhases = new Set<ResponsesStreamPhase>();

  const reportPhase = async (phase: ResponsesStreamPhase): Promise<void> => {
    if (reportedPhases.has(phase)) return;
    reportedPhases.add(phase);
    await observePhase(phase);
  };

  const observeWebSearchMetadata = (candidate: Record<string, unknown>) => {
    const metadata = responseWebSearchMetadata(candidate);
    webSearchUsed ||= metadata.used;
    for (const source of metadata.sources) webSearchSourceUrls.add(source.url);
  };

  const handleMessage = async (block: string): Promise<void> => {
    const message = parseSSEMessage(block);
    if (!message || message.data === "[DONE]") return;

    let payload: Record<string, unknown>;
    try {
      const decoded = JSON.parse(message.data) as unknown;
      if (!decoded || typeof decoded !== "object" || Array.isArray(decoded)) {
        throw new Error("Unexpected SSE payload");
      }
      payload = decoded as Record<string, unknown>;
    } catch {
      throw new Error("Meal analysis stream was malformed");
    }

    const eventType = typeof payload.type === "string"
      ? payload.type
      : message.event;
    const response = responseFromEvent(payload);
    if (response && typeof response.id === "string") {
      responseId = response.id;
    }
    if (response) observeWebSearchMetadata(response);
    if (eventType?.startsWith("response.web_search_call.")) {
      webSearchUsed = true;
      await reportPhase("web_search_started");
      if (eventType === "response.web_search_call.completed") {
        await reportPhase("web_search_completed");
      }
    }
    if (
      (eventType === "response.output_item.added" ||
        eventType === "response.output_item.done") &&
      payload.item && typeof payload.item === "object" &&
      !Array.isArray(payload.item)
    ) {
      observeWebSearchMetadata({ output: [payload.item] });
      if (
        (payload.item as Record<string, unknown>).type === "web_search_call"
      ) {
        await reportPhase("web_search_started");
        if (eventType === "response.output_item.done") {
          await reportPhase("web_search_completed");
        }
      }
    }

    if (eventType === "response.output_text.delta") {
      if (typeof payload.delta !== "string") {
        throw new Error("Meal analysis stream was malformed");
      }
      outputText = checkedOutput(outputText + payload.delta);
      await reportPhase("output_started");
      await observeOutput(outputText);
      return;
    }

    if (eventType === "response.output_text.done") {
      if (typeof payload.text === "string" && payload.text) {
        outputText = checkedOutput(payload.text);
        await observeOutput(outputText);
      }
      return;
    }

    if (eventType === "response.completed") {
      if (
        response && typeof response.status === "string" &&
        response.status !== "completed"
      ) {
        throw new Error("Meal analysis failed while streaming");
      }
      const canonicalOutput = response ? responseOutputText(response) : "";
      if (canonicalOutput) outputText = checkedOutput(canonicalOutput);
      if (!outputText) throw new Error("Meal analysis returned no output");
      completed = true;
      return;
    }

    if (
      eventType === "error" || eventType === "response.failed" ||
      eventType === "response.incomplete" ||
      eventType === "response.cancelled"
    ) {
      throw new Error("Meal analysis failed while streaming");
    }
    if (
      eventType === "response.refusal.delta" ||
      eventType === "response.refusal.done"
    ) {
      throw new Error("Meal analysis could not analyze this capture");
    }
  };

  const drainCompleteMessages = async (atEOF = false): Promise<void> => {
    while (true) {
      const separator = /\r?\n\r?\n|\r\r/.exec(buffered);
      if (!separator || separator.index === undefined) break;
      const block = buffered.slice(0, separator.index);
      buffered = buffered.slice(separator.index + separator[0].length);
      await handleMessage(block);
    }
    if (atEOF && buffered.trim()) {
      const block = buffered;
      buffered = "";
      await handleMessage(block);
    }
  };

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffered += decoder.decode(value, { stream: true });
      await drainCompleteMessages();
    }
    buffered += decoder.decode();
    await drainCompleteMessages(true);
  } catch (error) {
    await reader.cancel().catch(() => undefined);
    throw error;
  } finally {
    reader.releaseLock();
  }

  if (!completed) {
    throw new Error("Meal analysis stream ended before completion");
  }
  return {
    outputText,
    responseId,
    webSearchUsed,
    webSearchSources: Array.from(webSearchSourceUrls).slice(0, 5).map((
      url,
    ) => ({
      url,
    })),
  };
}
