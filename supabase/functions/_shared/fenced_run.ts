import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import { ClaudeOutputError, ClaudeRefusalError } from "./claude.ts";

/// Thin typed wrappers over the coach-run ledger RPCs (`claim_coach_run`,
/// `complete_coach_run`, `fail_coach_run`) used by the Train / Body / Nearby
/// workloads. Every output write is fenced on (run_id, claim_token); a worker
/// that lost its lease gets `LostRunLeaseError` and must stop writing.

export type CoachRunOperation =
  | "activity_analysis"
  | "body_review"
  | "nearby_research"
  | "training_plan";

export type CoachRunTrigger = "schedule" | "event" | "user" | "manual";

export type ClaimedRun = {
  runId: string;
  claimToken: string;
  attempt: number;
};

export type ClaimResult =
  | { claimed: true; run: ClaimedRun }
  | { claimed: false; status: string; runId: string | null };

export class LostRunLeaseError extends Error {
  constructor(label: string) {
    super(`${label}: run lease was replaced`);
  }
}

export type CoachRunMessage = {
  kind: string;
  body: string;
  payload?: Record<string, unknown>;
  deliver_at?: string | null;
  local_day?: string | null;
  slot_key?: string | null;
  notify?: boolean;
  activity_id?: string | null;
  entry_id?: string | null;
  reply_to_id?: string | null;
};

function asObject(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

export async function claimCoachRun(
  admin: SupabaseClient,
  options: {
    userId: string;
    operation: CoachRunOperation;
    localDay: string;
    checkpointKey: string;
    triggerSource: CoachRunTrigger;
    inputFingerprint?: string | null;
    leaseSeconds?: number;
    now?: () => number;
  },
): Promise<ClaimResult> {
  const now = options.now ?? Date.now;
  const { data, error } = await admin.rpc("claim_coach_run", {
    p_user_id: options.userId,
    p_operation: options.operation,
    p_local_day: options.localDay,
    p_checkpoint_key: options.checkpointKey,
    p_trigger_source: options.triggerSource,
    p_scheduled_for: new Date(now()).toISOString(),
    p_input_fingerprint: options.inputFingerprint ?? null,
    p_lease_seconds: options.leaseSeconds ?? 150,
  });
  if (error) throw error;
  const result = asObject(data);
  const status = typeof result.status === "string" ? result.status : "unknown";
  const runId = typeof result.run_id === "string" ? result.run_id : null;
  if (
    (status === "claimed" || status === "reclaimed") && runId &&
    typeof result.claim_token === "string"
  ) {
    return {
      claimed: true,
      run: {
        runId,
        claimToken: result.claim_token,
        attempt: Number(result.generation_attempt ?? 1) || 1,
      },
    };
  }
  return { claimed: false, status, runId };
}

export async function completeCoachRun(
  admin: SupabaseClient,
  run: ClaimedRun,
  options: {
    result: Record<string, unknown>;
    messages?: CoachRunMessage[];
    supersedeSlotKeys?: string[];
    model: string | null;
    providerResponseId: string | null;
    label: string;
  },
): Promise<{ messageIds: string[] }> {
  const { data, error } = await admin.rpc("complete_coach_run", {
    p_run_id: run.runId,
    p_claim_token: run.claimToken,
    p_status: "complete",
    p_result: options.result,
    p_messages: options.messages ?? [],
    p_supersede_slot_keys: options.supersedeSlotKeys ?? [],
    p_model: options.model,
    p_provider_response_id: options.providerResponseId,
  });
  if (error) throw error;
  const result = asObject(data);
  if (result.status !== "complete") {
    throw new LostRunLeaseError(options.label);
  }
  const ids = Array.isArray(result.message_ids)
    ? result.message_ids.filter((id): id is string => typeof id === "string")
    : [];
  return { messageIds: ids };
}

/**
 * Best effort: a failure to record failure is logged, never thrown.
 * `retryable: false` marks the run terminal (the next claim is `exhausted`);
 * for activity_analysis the ledger then also marks the activity failed.
 */
export async function failCoachRun(
  admin: SupabaseClient,
  run: ClaimedRun,
  message: string,
  retryable = true,
): Promise<void> {
  try {
    const { error } = await admin.rpc("fail_coach_run", {
      p_run_id: run.runId,
      p_claim_token: run.claimToken,
      p_error_message: message.slice(0, 500),
      p_retryable: retryable,
    });
    if (error) throw error;
  } catch (error) {
    console.error("coach_run_fail_record_failed", {
      runId: run.runId,
      message: error instanceof Error ? error.message.slice(0, 200) : "unknown",
    });
  }
}

/// Refusals and malformed output repeat on retry; everything else (timeouts,
/// 429/5xx, network) may succeed on a later attempt.
export function isRetryableFailure(error: unknown): boolean {
  return !(error instanceof ClaudeRefusalError ||
    error instanceof ClaudeOutputError);
}

/** Short, log-safe text for a failure (no provider output, no user text). */
export function failureMessage(error: unknown, fallback: string): string {
  if (error instanceof Error && error.message) {
    return error.message.slice(0, 300);
  }
  if (error && typeof error === "object" && "message" in error) {
    return String((error as { message: unknown }).message).slice(0, 300);
  }
  return fallback;
}

export function isValidTimezone(value: string | null | undefined): boolean {
  if (!value) return false;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: value }).format();
    return true;
  } catch {
    return false;
  }
}

/** The calendar day (YYYY-MM-DD) at `at` in `timezone` (UTC if invalid). */
export function localDayIn(
  timezone: string | null | undefined,
  at = new Date(),
): string {
  const zone = isValidTimezone(timezone) ? timezone! : "UTC";
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: zone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(at);
  const values = Object.fromEntries(
    parts.map((part) => [part.type, part.value]),
  );
  return `${values.year}-${values.month}-${values.day}`;
}

export function isLocalDay(value: unknown): value is string {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return false;
  }
  const parsed = new Date(`${value}T00:00:00.000Z`);
  return !Number.isNaN(parsed.valueOf()) &&
    parsed.toISOString().slice(0, 10) === value;
}

export function addDays(day: string, days: number): string {
  const parsed = new Date(`${day}T00:00:00.000Z`);
  parsed.setUTCDate(parsed.getUTCDate() + days);
  return parsed.toISOString().slice(0, 10);
}

export function daysBetween(from: string, to: string): number {
  return Math.round(
    (Date.parse(`${to}T00:00:00.000Z`) - Date.parse(`${from}T00:00:00.000Z`)) /
      86_400_000,
  );
}

export const POUNDS_PER_KG = 2.2046226218;

export function roundTo(value: number, step: number): number {
  return Math.round(value / step) * step;
}
