import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import { recordClaudeUsage } from "./ai_usage.ts";
import type { ClaudeUsage } from "./claude.ts";
import type { CoachRunOperation } from "./coach_rpc.ts";

/// Every coach Claude call lands in the cost ledger (lane B1's
/// recordClaudeUsage never throws; a failed write only logs).
export async function recordCoachUsage(
  admin: SupabaseClient,
  userId: string,
  operation: CoachRunOperation,
  usage: ClaudeUsage,
  runId?: string | null,
): Promise<void> {
  await recordClaudeUsage(admin, userId, operation, usage, runId ?? null);
}

export function emptyUsage(workload: string, model: string): ClaudeUsage {
  return {
    workload,
    model,
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    webSearches: 0,
  };
}

export function addUsage(total: ClaudeUsage, next: ClaudeUsage): ClaudeUsage {
  return {
    workload: total.workload,
    model: next.model || total.model,
    inputTokens: total.inputTokens + next.inputTokens,
    outputTokens: total.outputTokens + next.outputTokens,
    cacheReadTokens: total.cacheReadTokens + next.cacheReadTokens,
    cacheWriteTokens: total.cacheWriteTokens + next.cacheWriteTokens,
    webSearches: total.webSearches + next.webSearches,
  };
}
