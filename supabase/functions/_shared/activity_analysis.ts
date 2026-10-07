// PLACEHOLDER: replaced by lane B3. Only the SPEC §4 signatures exist here so
// the coach brain (lane B2) compiles; every call fails until B3 merges.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";

export function createActivityFromText(
  _admin: SupabaseClient,
  _userId: string,
  _input: {
    clientRequestId: string;
    localDay: string;
    timezone: string;
    text: string;
    source: "coach_chat" | "voice" | "text";
    sourceMessageId?: string | null;
  },
): Promise<{ activityId: string; duplicate: boolean }> {
  return Promise.reject(new Error("Activity logging is not available yet"));
}

export function analyzeStoredActivity(
  _admin: SupabaseClient,
  _userId: string,
  _activityId: string,
): Promise<void> {
  return Promise.reject(new Error("Activity analysis is not available yet"));
}
