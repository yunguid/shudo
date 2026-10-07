import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";

/// Every service-role RPC the coach brain calls, in one place so the names
/// and parameter shapes can be reconciled with the migration (lane B1).

export type CoachRunOperation =
  | "coach_checkpoint"
  | "coach_reply"
  | "day_digest"
  | "activity_analysis"
  | "body_review"
  | "nearby_research"
  | "training_plan";

export type CoachRunClaimStatus =
  | "claimed"
  | "reclaimed"
  | "running"
  | "complete"
  | "skipped"
  | "exhausted"
  | "disabled"
  | "capacity"
  | "conflict";

export type CoachRunClaim = {
  status: CoachRunClaimStatus;
  run_id: string | null;
  claim_token: string | null;
  generation_attempt: number | null;
};

export type ClaimedCoachRun = CoachRunClaim & {
  status: "claimed" | "reclaimed";
  run_id: string;
  claim_token: string;
};

export function isClaimed(claim: CoachRunClaim): claim is ClaimedCoachRun {
  return (claim.status === "claimed" || claim.status === "reclaimed") &&
    typeof claim.run_id === "string" && typeof claim.claim_token === "string";
}

function objectOf(value: unknown): Record<string, unknown> {
  const single = Array.isArray(value) ? value[0] : value;
  return single && typeof single === "object" && !Array.isArray(single)
    ? single as Record<string, unknown>
    : {};
}

function stringOrNull(value: unknown): string | null {
  return typeof value === "string" && value ? value : null;
}

export async function claimCoachRun(
  admin: SupabaseClient,
  args: {
    userId: string;
    operation: CoachRunOperation;
    localDay: string;
    checkpointKey: string;
    triggerSource: "schedule" | "event" | "user" | "manual";
    scheduledFor: Date;
    fingerprint?: string | null;
    leaseSeconds?: number;
  },
): Promise<CoachRunClaim> {
  const { data, error } = await admin.rpc("claim_coach_run", {
    p_user_id: args.userId,
    p_operation: args.operation,
    p_local_day: args.localDay,
    p_checkpoint_key: args.checkpointKey,
    p_trigger_source: args.triggerSource,
    p_scheduled_for: args.scheduledFor.toISOString(),
    p_input_fingerprint: args.fingerprint ?? null,
    p_lease_seconds: args.leaseSeconds ?? 150,
  });
  if (error) throw error;
  const result = objectOf(data);
  const attempt = Number(result.generation_attempt);
  return {
    status: (stringOrNull(result.status) ?? "conflict") as CoachRunClaimStatus,
    run_id: stringOrNull(result.run_id),
    claim_token: stringOrNull(result.claim_token),
    generation_attempt: Number.isInteger(attempt) ? attempt : null,
  };
}

/// One message for complete_coach_run (persisted as role 'coach').
export type CoachMessageInput = {
  kind: string;
  body: string;
  payload?: Record<string, unknown>;
  deliver_at?: string;
  local_day?: string;
  slot_key?: string | null;
  notify?: boolean;
  reply_to_id?: string | null;
  entry_id?: string | null;
  activity_id?: string | null;
};

export type CoachRunCompletion = {
  status: "complete" | "skipped" | "stale" | "not_found";
  message_ids: string[];
  superseded: number;
};

export async function completeCoachRun(
  admin: SupabaseClient,
  args: {
    runId: string;
    claimToken: string;
    status: "complete" | "skipped";
    result: Record<string, unknown>;
    messages: CoachMessageInput[];
    supersedeSlotKeys: string[];
    model: string | null;
    providerResponseId: string | null;
  },
): Promise<CoachRunCompletion> {
  const { data, error } = await admin.rpc("complete_coach_run", {
    p_run_id: args.runId,
    p_claim_token: args.claimToken,
    p_status: args.status,
    p_result: args.result,
    p_messages: args.messages,
    p_supersede_slot_keys: args.supersedeSlotKeys,
    p_model: args.model,
    p_provider_response_id: args.providerResponseId,
  });
  if (error) throw error;
  const result = objectOf(data);
  return {
    status: (stringOrNull(result.status) ?? "stale") as CoachRunCompletion[
      "status"
    ],
    message_ids: Array.isArray(result.message_ids)
      ? result.message_ids.filter((id): id is string => typeof id === "string")
      : [],
    superseded: Number(result.superseded) || 0,
  };
}

export async function failCoachRun(
  admin: SupabaseClient,
  runId: string,
  claimToken: string,
  message: string,
): Promise<boolean> {
  const { data, error } = await admin.rpc("fail_coach_run", {
    p_run_id: runId,
    p_claim_token: claimToken,
    p_error_message: message.slice(0, 500),
  });
  if (error) throw error;
  return data === true;
}

export type UserMessagePost = {
  status: "created" | "existing" | "conflict" | "quota";
  message_id: string | null;
};

export async function postUserCoachMessage(
  admin: SupabaseClient,
  args: {
    userId: string;
    clientRequestId: string;
    localDay: string;
    kind: "text" | "photo";
    body: string;
    payload: Record<string, unknown>;
    attachmentPath: string | null;
  },
): Promise<UserMessagePost> {
  const { data, error } = await admin.rpc("post_user_coach_message", {
    p_user_id: args.userId,
    p_client_request_id: args.clientRequestId,
    p_local_day: args.localDay,
    p_kind: args.kind,
    p_body: args.body,
    p_payload: args.payload,
    p_attachment_path: args.attachmentPath,
  });
  if (error) throw error;
  const result = objectOf(data);
  return {
    status: (stringOrNull(result.status) ?? "conflict") as UserMessagePost[
      "status"
    ],
    message_id: stringOrNull(result.message_id),
  };
}

/// Creates or updates the streaming coach reply under the run fence. Returns
/// false when the fence was lost (another worker owns the run now).
export async function upsertStreamingCoachMessage(
  admin: SupabaseClient,
  args: {
    runId: string;
    claimToken: string;
    messageId: string;
    body: string;
    payload: Record<string, unknown>;
    done: boolean;
  },
): Promise<boolean> {
  const { data, error } = await admin.rpc("upsert_streaming_coach_message", {
    p_run_id: args.runId,
    p_claim_token: args.claimToken,
    p_message_id: args.messageId,
    p_body: args.body,
    p_payload: args.payload,
    p_done: args.done,
  });
  if (error) throw error;
  if (data === false || data === null) return false;
  const status = objectOf(data).status;
  return !(status === "stale" || status === "not_found");
}

export type MemorySaveResult = {
  status: "saved" | "conflict" | "stale";
  version: number | null;
};

export async function saveCoachMemoryRpc(
  admin: SupabaseClient,
  args: {
    userId: string;
    expectedVersion: number;
    document: string;
    sections: Record<string, unknown>;
    source: "onboarding" | "coach_reply" | "day_digest" | "weekly" | "manual";
    changeSummary: string | null;
    runId?: string | null;
    messageId?: string | null;
  },
): Promise<MemorySaveResult> {
  const { data, error } = await admin.rpc("save_coach_memory", {
    p_user_id: args.userId,
    p_expected_version: args.expectedVersion,
    p_document: args.document,
    p_sections: args.sections,
    p_source: args.source,
    p_change_summary: args.changeSummary,
    p_run_id: args.runId ?? null,
    p_message_id: args.messageId ?? null,
  });
  if (error) throw error;
  const result = objectOf(data);
  const version = Number(result.version);
  return {
    status: (stringOrNull(result.status) ?? "stale") as MemorySaveResult[
      "status"
    ],
    version: Number.isInteger(version) ? version : null,
  };
}

export async function saveDayDigestRpc(
  admin: SupabaseClient,
  runId: string,
  claimToken: string,
  digest: Record<string, unknown>,
): Promise<string> {
  const { data, error } = await admin.rpc("save_day_digest", {
    p_run_id: runId,
    p_claim_token: claimToken,
    p_digest: digest,
  });
  if (error) throw error;
  return typeof data === "string" ? data : String(objectOf(data).status ?? "");
}

export async function activateTrainingPlanRpc(
  admin: SupabaseClient,
  userId: string,
  planId: string,
): Promise<unknown> {
  const { data, error } = await admin.rpc("activate_training_plan", {
    p_user_id: userId,
    p_plan_id: planId,
  });
  if (error) throw error;
  return data;
}

/// Columns returned to the client for a coach message (CoachMessageRow).
export const COACH_MESSAGE_COLUMNS =
  "id,role,kind,body,payload,local_day,deliver_at,status,notify,slot_key,entry_id,activity_id,attachment_path,read_at,created_at,updated_at";

export type CoachMessageRow = {
  id: string;
  role: "coach" | "user" | "system_event";
  kind: string;
  body: string;
  payload: Record<string, unknown>;
  local_day: string;
  deliver_at: string;
  status: "scheduled" | "delivered" | "superseded";
  notify: boolean;
  slot_key: string | null;
  entry_id: string | null;
  activity_id: string | null;
  attachment_path: string | null;
  read_at: string | null;
  created_at: string;
  updated_at: string;
};

export async function fetchCoachMessages(
  admin: SupabaseClient,
  userId: string,
  ids: string[],
): Promise<CoachMessageRow[]> {
  if (ids.length === 0) return [];
  const { data, error } = await admin.from("coach_messages")
    .select(COACH_MESSAGE_COLUMNS)
    .eq("user_id", userId)
    .in("id", ids);
  if (error) throw error;
  const rows = (data ?? []) as CoachMessageRow[];
  const order = new Map(ids.map((id, index) => [id, index]));
  return rows.sort((left, right) =>
    (order.get(left.id) ?? 0) - (order.get(right.id) ?? 0)
  );
}
