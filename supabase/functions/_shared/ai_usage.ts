import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import { CLAUDE_MODELS, type ClaudeUsage } from "./claude.ts";
import { withTimeout } from "./http.ts";

/// Bumped whenever a price below changes; stored on every ledger row so old
/// rows keep their original basis.
export const PRICING_VERSION = "2026-10-06";

/// Mirrors private.ai_job_usage / private.ai_provider_calls operation checks.
export const AI_OPERATIONS = [
  "meal_analysis",
  "onboarding",
  "entry_correction",
  "weekly_summary",
  "coach_checkpoint",
  "coach_reply",
  "day_digest",
  "activity_analysis",
  "body_review",
  "nearby_research",
  "training_plan",
] as const;

export type AiOperation = typeof AI_OPERATIONS[number];

/// Cents per million tokens, kept integral so cost math never drifts.
/// Cache writes are priced at the 5-minute TTL rate (1.25x input).
export type ClaudePrice = {
  inputCentsPerMTok: number;
  outputCentsPerMTok: number;
  cacheReadCentsPerMTok: number;
  cacheWriteCentsPerMTok: number;
};

export const CLAUDE_PRICES: Readonly<Record<string, ClaudePrice>> = {
  // $2 / $10 per MTok, cache reads $0.20.
  [CLAUDE_MODELS.sonnet]: {
    inputCentsPerMTok: 200,
    outputCentsPerMTok: 1_000,
    cacheReadCentsPerMTok: 20,
    cacheWriteCentsPerMTok: 250,
  },
  // $4 / $20 per MTok, cache reads $0.20.
  [CLAUDE_MODELS.opus]: {
    inputCentsPerMTok: 400,
    outputCentsPerMTok: 2_000,
    cacheReadCentsPerMTok: 20,
    cacheWriteCentsPerMTok: 500,
  },
  // $10 / $50 per MTok, cache reads $0.25.
  [CLAUDE_MODELS.fable]: {
    inputCentsPerMTok: 1_000,
    outputCentsPerMTok: 5_000,
    cacheReadCentsPerMTok: 25,
    cacheWriteCentsPerMTok: 1_250,
  },
  // $1 / $5 per MTok, cache reads $0.10.
  [CLAUDE_MODELS.haiku]: {
    inputCentsPerMTok: 100,
    outputCentsPerMTok: 500,
    cacheReadCentsPerMTok: 10,
    cacheWriteCentsPerMTok: 125,
  },
};

/// Server web search: $10 per 1,000 searches = 10,000 micro-USD each.
export const WEB_SEARCH_MICROS_PER_REQUEST = 10_000;

/// Upper bound accepted by private.ai_provider_calls ($100 per call).
export const MAX_CALL_COST_MICROS = 100_000_000;

const RECORD_TIMEOUT_MS = 5_000;

/// An unrecognized model (for example a refusal fallback) is priced at the
/// most expensive known rates so the spend breaker errs toward stopping.
const CONSERVATIVE_PRICE: ClaudePrice = Object.values(CLAUDE_PRICES).reduce(
  (worst, price) => ({
    inputCentsPerMTok: Math.max(
      worst.inputCentsPerMTok,
      price.inputCentsPerMTok,
    ),
    outputCentsPerMTok: Math.max(
      worst.outputCentsPerMTok,
      price.outputCentsPerMTok,
    ),
    cacheReadCentsPerMTok: Math.max(
      worst.cacheReadCentsPerMTok,
      price.cacheReadCentsPerMTok,
    ),
    cacheWriteCentsPerMTok: Math.max(
      worst.cacheWriteCentsPerMTok,
      price.cacheWriteCentsPerMTok,
    ),
  }),
);

export function claudePriceFor(
  model: string,
): { price: ClaudePrice; known: boolean } {
  const price = CLAUDE_PRICES[model];
  return price
    ? { price, known: true }
    : { price: CONSERVATIVE_PRICE, known: false };
}

function tokenCount(value: unknown, maximum = Number.MAX_SAFE_INTEGER): number {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.min(maximum, Math.max(0, Math.trunc(value)))
    : 0;
}

/// Cost of one call (or one summed multi-turn call) in micro-USD, rounded up.
export function claudeCostMicros(usage: ClaudeUsage): number {
  const { price } = claudePriceFor(usage.model);
  // tokens × cents-per-MTok / 100 = micro-USD.
  const centMicros = tokenCount(usage.inputTokens) * price.inputCentsPerMTok +
    tokenCount(usage.outputTokens) * price.outputCentsPerMTok +
    tokenCount(usage.cacheReadTokens) * price.cacheReadCentsPerMTok +
    tokenCount(usage.cacheWriteTokens) * price.cacheWriteCentsPerMTok;
  const micros = Math.ceil(centMicros / 100) +
    tokenCount(usage.webSearches, 1_000) * WEB_SEARCH_MICROS_PER_REQUEST;
  return Math.min(MAX_CALL_COST_MICROS, micros);
}

/// The ledger accepts `^[a-z][a-z0-9_.:-]{0,63}$`.
export function normalizeWorkload(workload: string): string {
  const cleaned = workload.trim().toLowerCase()
    .replace(/[^a-z0-9_.:-]+/g, "_")
    .replace(/^[^a-z]+/, "");
  return (cleaned || "unknown").slice(0, 64);
}

export type RecordUsageOptions = {
  /// Capture-pool linkage when there is no coach run (e.g. a meal's
  /// client_request_id and processing attempt).
  requestKey?: string | null;
  attempt?: number | null;
  providerRequestId?: string | null;
  latencyMs?: number | null;
  timeoutMs?: number;
};

function isAiOperation(value: string): value is AiOperation {
  return (AI_OPERATIONS as readonly string[]).includes(value);
}

/**
 * Records one Claude result in the private cost ledger through the
 * service-role `record_ai_provider_call` RPC. With `runId` the row is linked
 * to that coach run's exact AI reservation. Telemetry never breaks the user
 * flow: failures are logged (no content) and resolve to null.
 */
export async function recordClaudeUsage(
  admin: SupabaseClient,
  userId: string | null,
  operation: AiOperation,
  usage: ClaudeUsage,
  runId?: string | null,
  options: RecordUsageOptions = {},
): Promise<string | null> {
  if (!isAiOperation(operation)) {
    console.error("ai_usage_record_skipped", { reason: "unknown_operation" });
    return null;
  }
  const inputTokens = tokenCount(usage.inputTokens);
  const outputTokens = tokenCount(usage.outputTokens);
  const cacheReadTokens = tokenCount(usage.cacheReadTokens);
  const cacheWriteTokens = tokenCount(usage.cacheWriteTokens);
  const webSearches = tokenCount(usage.webSearches, 1_000);
  if (
    inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens +
        webSearches === 0
  ) {
    return null;
  }

  const model = (usage.model?.trim() || "unknown").slice(0, 100);
  const { known } = claudePriceFor(model);
  if (!known) {
    console.warn("ai_usage_unpriced_model", { model, operation });
  }
  const attempt = options.attempt == null
    ? null
    : tokenCount(options.attempt, 20) || null;
  const latencyMs = options.latencyMs == null
    ? null
    : tokenCount(options.latencyMs, 3_600_000);

  try {
    const { data, error } = await withTimeout(
      Promise.resolve(admin.rpc("record_ai_provider_call", {
        p_user_id: userId,
        p_operation: operation,
        p_workload: normalizeWorkload(usage.workload ?? ""),
        p_model: model,
        p_input_tokens: inputTokens,
        p_output_tokens: outputTokens,
        p_cache_read_tokens: cacheReadTokens,
        p_cache_write_tokens: cacheWriteTokens,
        p_web_search_requests: webSearches,
        p_cost_usd_micros: claudeCostMicros({ ...usage, model }),
        p_pricing_version: PRICING_VERSION,
        p_run_id: runId ?? null,
        p_request_key: options.requestKey?.trim().slice(0, 256) || null,
        p_attempt: attempt,
        p_provider_request_id:
          options.providerRequestId?.trim().slice(0, 200) ||
          null,
        p_latency_ms: latencyMs,
      })),
      options.timeoutMs ?? RECORD_TIMEOUT_MS,
      "AI usage ledger write",
    );
    if (error) throw error;
    return typeof data === "string" ? data : null;
  } catch (error) {
    console.error("ai_usage_record_failed", {
      operation,
      model,
      message: (error instanceof Error
        ? error.message
        : typeof error === "object" && error && "message" in error
        ? String((error as { message: unknown }).message)
        : String(error)).slice(0, 200),
    });
    return null;
  }
}
