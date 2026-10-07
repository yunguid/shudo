import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import { type ClaudeUsage, logClaudeUsage } from "./claude.ts";
import type { CoachRunOperation } from "./coach_rpc.ts";

/// Single seam for coach cost accounting. Lane B1 owns the price table and
/// `recordClaudeUsage(admin, userId, operation, usage)` in `_shared/ai_usage.ts`
/// (record_ai_provider_call). Until that module is merged this logs token
/// counts only; at merge, delegate here so every coach call is recorded.
export function recordCoachUsage(
  _admin: SupabaseClient,
  _userId: string,
  operation: CoachRunOperation,
  usage: ClaudeUsage,
): Promise<void> {
  logClaudeUsage({ ...usage, workload: `${operation}.${usage.workload}` });
  return Promise.resolve();
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
