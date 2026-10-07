import {
  AI_OPERATIONS,
  CLAUDE_PRICES,
  claudeCostMicros,
  claudePriceFor,
  MAX_CALL_COST_MICROS,
  normalizeWorkload,
  PRICING_VERSION,
  recordClaudeUsage,
  WEB_SEARCH_MICROS_PER_REQUEST,
} from "../_shared/ai_usage.ts";
import { CLAUDE_MODELS, type ClaudeUsage } from "../_shared/claude.ts";
import { assert, assertEquals } from "./assertions.ts";

function usage(overrides: Partial<ClaudeUsage> = {}): ClaudeUsage {
  return {
    workload: "coach_plan",
    model: CLAUDE_MODELS.sonnet,
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    webSearches: 0,
    ...overrides,
  };
}

type RpcCall = { name: string; args: Record<string, unknown> };

function ledgerAdmin(
  respond: () => unknown = () => ({ data: "call-id", error: null }),
) {
  const calls: RpcCall[] = [];
  const admin = {
    rpc(name: string, args: Record<string, unknown>) {
      calls.push({ name, args });
      return respond();
    },
  };
  return { admin, calls };
}

async function quietly<T>(action: () => Promise<T>): Promise<T> {
  const originalError = console.error;
  const originalWarn = console.warn;
  console.error = () => {};
  console.warn = () => {};
  try {
    return await action();
  } finally {
    console.error = originalError;
    console.warn = originalWarn;
  }
}

Deno.test("every backend Claude model has a pinned price", () => {
  for (const model of Object.values(CLAUDE_MODELS)) {
    assert(claudePriceFor(model).known, `${model} is unpriced`);
  }
  assertEquals(Object.keys(CLAUDE_PRICES).sort(), [
    "claude-fable-5-1",
    "claude-haiku-4-5",
    "claude-opus-5-5",
    "claude-sonnet-5-5",
  ]);
});

Deno.test("price table matches published per-MTok rates", () => {
  const dollars = (cents: number) => cents / 100;
  const rates = Object.fromEntries(
    Object.entries(CLAUDE_PRICES).map(([model, price]) => [model, [
      dollars(price.inputCentsPerMTok),
      dollars(price.outputCentsPerMTok),
      dollars(price.cacheReadCentsPerMTok),
      dollars(price.cacheWriteCentsPerMTok),
    ]]),
  );
  assertEquals(rates, {
    "claude-sonnet-5-5": [2, 10, 0.2, 2.5],
    "claude-opus-5-5": [4, 20, 0.2, 5],
    "claude-fable-5-1": [10, 50, 0.25, 12.5],
    "claude-haiku-4-5": [1, 5, 0.1, 1.25],
  });
  assertEquals(WEB_SEARCH_MICROS_PER_REQUEST, 10_000);
});

Deno.test("cost is computed in micro-USD per component", () => {
  const million = 1_000_000;
  assertEquals(claudeCostMicros(usage({ inputTokens: million })), 2_000_000);
  assertEquals(claudeCostMicros(usage({ outputTokens: million })), 10_000_000);
  assertEquals(claudeCostMicros(usage({ cacheReadTokens: million })), 200_000);
  assertEquals(
    claudeCostMicros(usage({ cacheWriteTokens: million })),
    2_500_000,
  );
  assertEquals(claudeCostMicros(usage({ webSearches: 3 })), 30_000);
  assertEquals(
    claudeCostMicros(usage({
      model: CLAUDE_MODELS.opus,
      inputTokens: 12_000,
      outputTokens: 3_000,
      cacheReadTokens: 40_000,
    })),
    // 12k × $4 + 3k × $20 + 40k × $0.20 per MTok = 48,000 + 60,000 + 8,000.
    116_000,
  );
  assertEquals(
    claudeCostMicros(usage({
      model: CLAUDE_MODELS.fable,
      inputTokens: 50_000,
      outputTokens: 6_000,
      cacheReadTokens: 100_000,
    })),
    // 500,000 + 300,000 + 25,000.
    825_000,
  );
  assertEquals(
    claudeCostMicros(usage({
      model: CLAUDE_MODELS.haiku,
      inputTokens: 2_000,
      outputTokens: 400,
    })),
    4_000,
  );
});

Deno.test("fractional cost rounds up and bad counts never go negative", () => {
  assertEquals(claudeCostMicros(usage({ cacheReadTokens: 1 })), 1);
  assertEquals(claudeCostMicros(usage({ inputTokens: 1 })), 2);
  assertEquals(
    claudeCostMicros(usage({
      inputTokens: -50,
      outputTokens: Number.NaN,
      cacheReadTokens: 2.9,
    })),
    1,
  );
  assertEquals(
    claudeCostMicros(usage({ outputTokens: 1_000_000_000 })),
    MAX_CALL_COST_MICROS,
  );
});

Deno.test("an unknown model is priced at the most expensive known rates", () => {
  const unknown = claudePriceFor("claude-opus-5");
  assert(!unknown.known);
  assertEquals(unknown.price.inputCentsPerMTok, 1_000);
  assertEquals(unknown.price.outputCentsPerMTok, 5_000);
  assertEquals(
    claudeCostMicros(usage({ model: "claude-opus-5", inputTokens: 1_000_000 })),
    10_000_000,
  );
});

Deno.test("workload labels are normalized to the ledger pattern", () => {
  const pattern = /^[a-z][a-z0-9_.:-]{0,63}$/;
  for (
    const [raw, expected] of [
      ["meal_analysis", "meal_analysis"],
      [
        "weekly_micronutrients:VitaminReport",
        "weekly_micronutrients:vitaminreport",
      ],
      ["Coach Chat (turn 3)", "coach_chat_turn_3_"],
      ["42-nearby", "nearby"],
      ["", "unknown"],
      ["x".repeat(90), "x".repeat(64)],
    ]
  ) {
    const normalized = normalizeWorkload(raw);
    assertEquals(normalized, expected);
    assert(pattern.test(normalized), `${normalized} breaks the ledger check`);
  }
});

Deno.test("the operation list mirrors the database operation checks", () => {
  assertEquals([...AI_OPERATIONS], [
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
  ]);
});

Deno.test("recordClaudeUsage writes one priced, run-linked ledger row", async () => {
  const { admin, calls } = ledgerAdmin();
  const recorded = await recordClaudeUsage(
    admin as never,
    "00000000-0000-4000-8000-0000000000c1",
    "coach_reply",
    usage({
      workload: "Coach Chat",
      inputTokens: 1_200,
      outputTokens: 300,
      cacheReadTokens: 8_000,
      cacheWriteTokens: 1_000,
      webSearches: 2,
    }),
    "11111111-2222-4333-8444-555555555555",
    { providerRequestId: " msg_01 ", latencyMs: 4_321.7 },
  );
  assertEquals(recorded, "call-id");
  assertEquals(calls, [{
    name: "record_ai_provider_call",
    args: {
      p_user_id: "00000000-0000-4000-8000-0000000000c1",
      p_operation: "coach_reply",
      p_workload: "coach_chat",
      p_model: "claude-sonnet-5-5",
      p_input_tokens: 1_200,
      p_output_tokens: 300,
      p_cache_read_tokens: 8_000,
      p_cache_write_tokens: 1_000,
      p_web_search_requests: 2,
      // 2,400 + 3,000 + 1,600 + 2,500 + 2 × 10,000.
      p_cost_usd_micros: 29_500,
      p_pricing_version: PRICING_VERSION,
      p_run_id: "11111111-2222-4333-8444-555555555555",
      p_request_key: null,
      p_attempt: null,
      p_provider_request_id: "msg_01",
      p_latency_ms: 4_321,
    },
  }]);
});

Deno.test("capture usage links by request key and attempt instead of a run", async () => {
  const { admin, calls } = ledgerAdmin();
  await recordClaudeUsage(
    admin as never,
    "00000000-0000-4000-8000-0000000000c1",
    "meal_analysis",
    usage({ workload: "meal_analysis", inputTokens: 10, outputTokens: 10 }),
    null,
    { requestKey: "10000000-0000-4000-8000-000000000001", attempt: 2 },
  );
  assertEquals(calls[0].args.p_run_id, null);
  assertEquals(
    calls[0].args.p_request_key,
    "10000000-0000-4000-8000-000000000001",
  );
  assertEquals(calls[0].args.p_attempt, 2);
});

Deno.test("recordClaudeUsage never throws and skips empty or invalid usage", async () => {
  const empty = ledgerAdmin();
  assertEquals(
    await recordClaudeUsage(empty.admin as never, null, "coach_reply", usage()),
    null,
  );
  assertEquals(empty.calls.length, 0);

  const invalid = ledgerAdmin();
  assertEquals(
    await quietly(() =>
      recordClaudeUsage(
        invalid.admin as never,
        null,
        "not_an_operation" as never,
        usage({ inputTokens: 5 }),
      )
    ),
    null,
  );
  assertEquals(invalid.calls.length, 0);

  const rejected = ledgerAdmin(() => ({
    data: null,
    error: { message: "permission denied" },
  }));
  assertEquals(
    await quietly(() =>
      recordClaudeUsage(
        rejected.admin as never,
        null,
        "day_digest",
        usage({ model: CLAUDE_MODELS.fable, inputTokens: 5 }),
      )
    ),
    null,
  );

  const thrown = ledgerAdmin(() => {
    throw new Error("network down");
  });
  assertEquals(
    await quietly(() =>
      recordClaudeUsage(
        thrown.admin as never,
        null,
        "training_plan",
        usage({ model: CLAUDE_MODELS.opus, outputTokens: 5 }),
      )
    ),
    null,
  );

  const hung = ledgerAdmin(() => new Promise(() => {}));
  const started = Date.now();
  assertEquals(
    await quietly(() =>
      recordClaudeUsage(
        hung.admin as never,
        null,
        "body_review",
        usage({ inputTokens: 5 }),
        null,
        { timeoutMs: 20 },
      )
    ),
    null,
  );
  assert(Date.now() - started < 2_000, "ledger write was not bounded");
});

Deno.test("an unpriced fallback model is still recorded conservatively", async () => {
  const { admin, calls } = ledgerAdmin();
  await quietly(() =>
    recordClaudeUsage(
      admin as never,
      null,
      "coach_checkpoint",
      usage({ model: "claude-opus-5", inputTokens: 1_000 }),
    )
  );
  assertEquals(calls[0].args.p_model, "claude-opus-5");
  assertEquals(calls[0].args.p_cost_usd_micros, 10_000);
});
