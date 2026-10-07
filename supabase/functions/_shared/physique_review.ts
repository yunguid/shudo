// PLACEHOLDER: replaced by lane B3. Only the SPEC §4 signature exists here so
// the coach brain (lane B2) compiles; reviews fail until B3 merges.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";

export function reviewPhysique(
  _admin: SupabaseClient,
  _userId: string,
  _input: { anchorDay: string; kind: "weekly" | "on_demand" },
): Promise<void> {
  return Promise.reject(new Error("Physique review is not available yet"));
}
