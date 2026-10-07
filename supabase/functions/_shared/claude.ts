import Anthropic from "npm:@anthropic-ai/sdk@0.131.0";
import { requiredEnv } from "./http.ts";

export { Anthropic };

/// Every Shudo AI workload runs on Anthropic. Model choice per workload lives
/// next to the workload; these are the only IDs the backend may use.
export const CLAUDE_MODELS = {
  /// Everyday work: meal/workout analysis, chat replies, nearby-food research.
  sonnet: "claude-sonnet-5-5",
  /// Judgment-heavy work: weekly review, physique feedback, training plans.
  opus: "claude-opus-5-5",
  /// Orchestration: nightly day compression, memory upkeep, tomorrow's plan.
  fable: "claude-fable-5-1",
  /// Cheap, fast text: checkpoint nudges when nothing needs reasoning.
  haiku: "claude-haiku-4-5",
} as const;

export type ClaudeModel = typeof CLAUDE_MODELS[keyof typeof CLAUDE_MODELS];
export type ClaudeEffort = "low" | "medium" | "high" | "xhigh" | "max";

/// Server-side refusal fallback: a safety decline is re-run on a suitable
/// model inside the same request instead of failing the user's capture.
const FALLBACK_BETA = "server-side-fallback-2026-07-01";
const MAX_STRUCTURED_OUTPUT_CHARACTERS = 60_000;
const MAX_LOOP_TURNS = 5;

export type BetaMessage = Anthropic.Beta.BetaMessage;
export type BetaMessageParam = Anthropic.Beta.BetaMessageParam;
export type BetaContentBlockParam = Anthropic.Beta.BetaContentBlockParam;
export type BetaToolUnion = Anthropic.Beta.BetaToolUnion;
export type BetaTextBlockParam = Anthropic.Beta.BetaTextBlockParam;

let sharedClient: Anthropic | null = null;

export function claudeClient(): Anthropic {
  sharedClient ??= new Anthropic({
    apiKey: requiredEnv("ANTHROPIC_API_KEY"),
    // Callers own their deadlines and durable retries (leases, claims), so a
    // single SDK retry covers transient 429/5xx without blowing the budget.
    maxRetries: 1,
  });
  return sharedClient;
}

export class ClaudeRefusalError extends Error {
  constructor(readonly category: string | null) {
    super("Claude declined to complete this request");
  }
}

export class ClaudeOutputError extends Error {}

/// Shown verbatim to Luke when the Anthropic account can't pay for a call.
export const CLAUDE_BILLING_MESSAGE =
  "Claude is out of API credits. Add credits at console.anthropic.com (Settings → Billing), then try again.";

/** True when the API refused because the account has no usable credit. */
export function isClaudeBillingError(error: unknown): boolean {
  if (!(error instanceof Anthropic.APIError)) {
    return error instanceof Error && error.message === CLAUDE_BILLING_MESSAGE;
  }
  if (error.status === 402) return true;
  const body = error.error as { error?: { message?: unknown } } | undefined;
  const message = typeof body?.error?.message === "string"
    ? body.error.message
    : error.message;
  return /credit balance|purchase credits|billing/i.test(message);
}

/** Turns SDK failures into short, log-safe messages (status codes only). */
export function describeClaudeError(error: unknown, label: string): Error {
  if (
    error instanceof ClaudeRefusalError || error instanceof ClaudeOutputError
  ) {
    return error;
  }
  if (isClaudeBillingError(error)) return new Error(CLAUDE_BILLING_MESSAGE);
  if (error instanceof Anthropic.RateLimitError) {
    return new Error(`${label} is rate limited (429)`);
  }
  if (error instanceof Anthropic.APIError) {
    return new Error(`${label} failed (${error.status ?? "network"})`);
  }
  if (error instanceof DOMException && error.name === "TimeoutError") {
    return new Error(`${label} timed out`);
  }
  return error instanceof Error ? error : new Error(`${label} failed`);
}

const UNSUPPORTED_SCHEMA_KEYS = new Set([
  "minLength",
  "maxLength",
  "minimum",
  "maximum",
  "exclusiveMinimum",
  "exclusiveMaximum",
  "multipleOf",
  "maxItems",
  "uniqueItems",
  "pattern",
]);

/**
 * Anthropic structured outputs accept a JSON Schema subset: no numeric or
 * string-length constraints, no maxItems, minItems only 0/1. Shudo's schemas
 * keep those bounds for its own validators (which run on every result), so
 * the copy sent to the API simply drops them. Union `type` arrays become
 * `anyOf` for the strictest compatibility.
 */
export function toClaudeSchema(schema: unknown): Record<string, unknown> {
  const convert = (node: unknown): unknown => {
    if (Array.isArray(node)) return node.map(convert);
    if (!node || typeof node !== "object") return node;
    const result: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(node)) {
      if (UNSUPPORTED_SCHEMA_KEYS.has(key)) continue;
      if (key === "minItems") {
        if (typeof value === "number" && value >= 1) result.minItems = 1;
        continue;
      }
      if (key === "properties" && value && typeof value === "object") {
        result.properties = Object.fromEntries(
          Object.entries(value).map(([name, child]) => [name, convert(child)]),
        );
        continue;
      }
      result[key] = convert(value);
    }
    if (Array.isArray(result.type)) {
      const types = result.type as string[];
      delete result.type;
      return { ...result, anyOf: types.map((type) => ({ type })) };
    }
    return result;
  };
  return convert(schema) as Record<string, unknown>;
}

export type ClaudeUserLocation = {
  city?: string;
  region?: string;
  country?: string;
  timezone?: string;
};

export function webSearchTool(
  maxUses: number,
  userLocation?: ClaudeUserLocation | null,
): BetaToolUnion {
  const location = userLocation &&
      (userLocation.city || userLocation.region || userLocation.country ||
        userLocation.timezone)
    ? { user_location: { type: "approximate" as const, ...userLocation } }
    : {};
  return {
    type: "web_search_20260209",
    name: "web_search",
    max_uses: maxUses,
    // Direct calls keep lookups fast and observable; dynamic filtering would
    // provision code execution that these short nutrition lookups don't need.
    allowed_callers: ["direct"],
    ...location,
  } as BetaToolUnion;
}

export function imageFromUrl(url: string): BetaContentBlockParam {
  return { type: "image", source: { type: "url", url } };
}

export function imageFromBase64(
  data: string,
  mediaType: "image/jpeg" | "image/png" | "image/webp" = "image/jpeg",
): BetaContentBlockParam {
  return {
    type: "image",
    source: { type: "base64", media_type: mediaType, data },
  };
}

/// Stable instructions go in cached system blocks; volatile state goes later.
export function systemBlocks(
  blocks: Array<{ text: string; cache?: boolean }>,
): BetaTextBlockParam[] {
  return blocks.filter((block) => block.text.trim()).map((block) => ({
    type: "text",
    text: block.text,
    ...(block.cache ? { cache_control: { type: "ephemeral" as const } } : {}),
  }));
}

function supportsEffort(model: ClaudeModel): boolean {
  return model !== CLAUDE_MODELS.haiku;
}

function supportsFallback(model: ClaudeModel): boolean {
  return model !== CLAUDE_MODELS.haiku;
}

/** Shared request envelope: model, effort, refusal fallback. */
export function baseParams(model: ClaudeModel, effort: ClaudeEffort) {
  return {
    model,
    ...(supportsFallback(model)
      ? { betas: [FALLBACK_BETA], fallbacks: "default" as const }
      : {}),
    ...(supportsEffort(model) ? { output_config: { effort } } : {}),
  };
}

export type ClaudePhase =
  | "web_search_started"
  | "web_search_completed"
  | "output_started";

export type ClaudeUsage = {
  workload: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  webSearches: number;
};

export function usageOf(workload: string, message: BetaMessage): ClaudeUsage {
  const usage = message.usage;
  return {
    workload,
    model: message.model,
    inputTokens: usage.input_tokens ?? 0,
    outputTokens: usage.output_tokens ?? 0,
    cacheReadTokens: usage.cache_read_input_tokens ?? 0,
    cacheWriteTokens: usage.cache_creation_input_tokens ?? 0,
    webSearches: usage.server_tool_use?.web_search_requests ?? 0,
  };
}

/// Bounded operational telemetry: token counts only, never content.
export function logClaudeUsage(usage: ClaudeUsage): void {
  console.info("claude_usage", usage);
}

function safeSourceUrl(value: unknown): string | null {
  if (typeof value !== "string" || value.length > 2_000) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" && url.protocol !== "http:") return null;
    if (!url.hostname || url.username || url.password) return null;
    url.hash = "";
    return url.toString();
  } catch {
    return null;
  }
}

/** URLs Claude actually consulted (search results and cited locations). */
export function webSourcesOf(
  content: Anthropic.Beta.BetaContentBlock[],
): { used: boolean; urls: string[] } {
  let used = false;
  const cited = new Set<string>();
  const consulted = new Set<string>();
  for (const block of content) {
    if (block.type === "web_search_tool_result") {
      if (!Array.isArray(block.content)) continue;
      used = true;
      for (const result of block.content) {
        const url = safeSourceUrl((result as { url?: unknown }).url);
        if (url) consulted.add(url);
      }
    } else if (block.type === "text" && Array.isArray(block.citations)) {
      for (const citation of block.citations) {
        const url = safeSourceUrl((citation as { url?: unknown }).url);
        if (url) cited.add(url);
      }
    }
  }
  // Cited sources first: they are the pages the answer actually leaned on.
  return { used, urls: [...new Set([...cited, ...consulted])] };
}

export type StructuredCallOptions = {
  workload: string;
  model: ClaudeModel;
  effort: ClaudeEffort;
  system: BetaTextBlockParam[];
  /// The conversation so far. The last message must be from the user.
  messages: BetaMessageParam[];
  schema: Record<string, unknown>;
  /// Name of the submission tool used when web search is enabled.
  schemaName: string;
  schemaDescription?: string;
  maxTokens?: number;
  timeoutMs: number;
  webSearch?: { maxUses: number; userLocation?: ClaudeUserLocation | null };
  onPartialJSON?: (partial: string) => Promise<void>;
  onPhase?: (phase: ClaudePhase) => Promise<void>;
  client?: Anthropic;
};

export type StructuredCallResult = {
  output: unknown;
  messageId: string | null;
  model: string;
  webSearchUsed: boolean;
  webSearchSources: Array<{ url: string }>;
  usage: ClaudeUsage;
};

/**
 * One structured Claude call with streaming progress.
 *
 * Without web search the response is constrained by `output_config.format`
 * and streams as JSON text. Web search always attaches citations, which the
 * API does not allow alongside a JSON response format, so search-enabled
 * calls instead finish by calling a strict submission tool whose input
 * streams as partial JSON. Either way `onPartialJSON` sees the growing JSON
 * object and the caller validates the final `output` itself.
 */
export async function callClaudeStructured(
  options: StructuredCallOptions,
): Promise<StructuredCallResult> {
  const client = options.client ?? claudeClient();
  const signal = AbortSignal.timeout(options.timeoutMs);
  const useSubmitTool = Boolean(options.webSearch);
  const schema = toClaudeSchema(options.schema);
  const base = baseParams(options.model, options.effort);
  const outputConfig = {
    ...(base.output_config ?? {}),
    ...(useSubmitTool
      ? {}
      : { format: { type: "json_schema" as const, schema } }),
  };
  const tools: BetaToolUnion[] | undefined = useSubmitTool
    ? [
      webSearchTool(
        options.webSearch!.maxUses,
        options.webSearch!.userLocation,
      ),
      {
        name: options.schemaName,
        description: options.schemaDescription ??
          "Submit the final result. Call this exactly once, after any research, as your final action.",
        strict: true,
        eager_input_streaming: true,
        input_schema: schema as Anthropic.Beta.BetaTool.InputSchema,
      },
    ]
    : undefined;

  const reported = new Set<ClaudePhase>();
  const report = async (phase: ClaudePhase) => {
    if (reported.has(phase)) return;
    reported.add(phase);
    await options.onPhase?.(phase);
  };

  const messages = [...options.messages];
  const sources = new Set<string>();
  let webSearchUsed = false;
  let nudged = false;
  const totals: ClaudeUsage = {
    workload: options.workload,
    model: options.model,
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    webSearches: 0,
  };

  for (let turn = 0; turn < MAX_LOOP_TURNS; turn += 1) {
    const stream = client.beta.messages.stream({
      ...base,
      ...(Object.keys(outputConfig).length
        ? { output_config: outputConfig }
        : {}),
      max_tokens: options.maxTokens ?? 16_000,
      system: options.system,
      messages,
      ...(tools ? { tools } : {}),
    }, { signal });

    let partial = "";
    let submitIndex = -1;
    try {
      for await (const event of stream) {
        if (event.type === "content_block_start") {
          const block = event.content_block;
          if (block.type === "server_tool_use" && block.name === "web_search") {
            await report("web_search_started");
          } else if (block.type === "web_search_tool_result") {
            await report("web_search_completed");
          } else if (
            block.type === "tool_use" && block.name === options.schemaName
          ) {
            submitIndex = event.index;
            await report("output_started");
          }
        } else if (event.type === "content_block_delta") {
          const delta = event.delta;
          const isOutputDelta = useSubmitTool
            ? delta.type === "input_json_delta" && event.index === submitIndex
            : delta.type === "text_delta";
          if (!isOutputDelta) continue;
          partial += delta.type === "text_delta"
            ? delta.text
            : (delta as { partial_json: string }).partial_json;
          if (partial.length > MAX_STRUCTURED_OUTPUT_CHARACTERS) {
            throw new ClaudeOutputError(
              `${options.workload} output exceeded its safe limit`,
            );
          }
          await report("output_started");
          await options.onPartialJSON?.(partial);
        }
      }
    } catch (error) {
      stream.abort();
      throw error;
    }

    const message = await stream.finalMessage();
    const usage = usageOf(options.workload, message);
    totals.model = usage.model;
    totals.inputTokens += usage.inputTokens;
    totals.outputTokens += usage.outputTokens;
    totals.cacheReadTokens += usage.cacheReadTokens;
    totals.cacheWriteTokens += usage.cacheWriteTokens;
    totals.webSearches += usage.webSearches;
    const web = webSourcesOf(message.content);
    webSearchUsed ||= web.used;
    for (const url of web.urls) sources.add(url);

    if (message.stop_reason === "refusal") {
      logClaudeUsage(totals);
      throw new ClaudeRefusalError(
        (message.stop_details as { category?: string } | null)?.category ??
          null,
      );
    }
    if (message.stop_reason === "pause_turn") {
      messages.push({ role: "assistant", content: message.content });
      continue;
    }
    if (message.stop_reason === "max_tokens") {
      logClaudeUsage(totals);
      throw new ClaudeOutputError(`${options.workload} output was truncated`);
    }

    let output: unknown = undefined;
    if (useSubmitTool) {
      const submission = message.content.find((block) =>
        block.type === "tool_use" && block.name === options.schemaName
      );
      if (!submission || submission.type !== "tool_use") {
        if (nudged) {
          logClaudeUsage(totals);
          throw new ClaudeOutputError(
            `${options.workload} finished without a result`,
          );
        }
        // auto tool choice does not guarantee the call; ask once, plainly.
        nudged = true;
        messages.push({ role: "assistant", content: message.content });
        messages.push({
          role: "user",
          content: `Now call ${options.schemaName} with your final result.`,
        });
        continue;
      }
      output = submission.input;
    } else {
      const text = message.content
        .filter((block) => block.type === "text")
        .map((block) => (block as { text: string }).text)
        .join("");
      try {
        output = JSON.parse(text);
      } catch {
        logClaudeUsage(totals);
        throw new ClaudeOutputError(
          `${options.workload} returned invalid JSON`,
        );
      }
    }

    logClaudeUsage(totals);
    return {
      output,
      messageId: message.id ?? null,
      model: message.model,
      webSearchUsed,
      webSearchSources: [...sources].slice(0, 5).map((url) => ({ url })),
      usage: totals,
    };
  }
  logClaudeUsage(totals);
  throw new ClaudeOutputError(`${options.workload} did not finish`);
}

/** Convenience wrapper for single-turn structured calls with no streaming. */
export async function generateStructured<T>(
  options: Omit<StructuredCallOptions, "messages"> & {
    content: string | BetaContentBlockParam[];
    parse: (value: unknown) => T;
  },
): Promise<{ value: T; messageId: string | null; model: string }> {
  try {
    const result = await callClaudeStructured({
      ...options,
      messages: [{ role: "user", content: options.content }],
    });
    return {
      value: options.parse(result.output),
      messageId: result.messageId,
      model: result.model,
    };
  } catch (error) {
    throw describeClaudeError(error, options.workload);
  }
}
