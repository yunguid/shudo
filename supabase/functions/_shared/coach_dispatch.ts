// PLACEHOLDER: lane B2 owns this file. This minimal version exists only so
// lane B3 (log_activity / activity_analysis) can dispatch a coach plan refresh
// on its branch; B2's implementation replaces it wholesale at merge time.
import { requiredEnv } from "./http.ts";

const DISPATCH_TIMEOUT_MS = 10_000;

export type CoachJobName =
  | "day_digest"
  | "training_plan"
  | "body_review"
  | "plan";

export type CoachJob =
  | { mode: "daily" }
  | {
    job: CoachJobName;
    user_id: string;
    payload?: Record<string, unknown>;
  };

/**
 * Fire-and-forget POST to the `coach_tick` maintenance function with the
 * weekly secret header. Never throws: callers have already made their own
 * work durable, so a failed dispatch is logged (ids only) and dropped.
 */
export async function dispatchCoachJob(job: CoachJob): Promise<void> {
  const label = "mode" in job ? job.mode : job.job;
  try {
    const supabaseUrl = requiredEnv("SUPABASE_URL").replace(/\/+$/, "");
    const secret = requiredEnv("SHUDO_WEEKLY_SECRET");
    const body = "mode" in job ? job : { mode: "job", ...job };
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")?.trim();
    const response = await fetch(`${supabaseUrl}/functions/v1/coach_tick`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-shudo-weekly-secret": secret,
        ...(anonKey ? { apikey: anonKey } : {}),
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(DISPATCH_TIMEOUT_MS),
    });
    await response.body?.cancel();
    if (!response.ok) {
      console.error("coach_dispatch_failed", {
        job: label,
        status: response.status,
      });
    }
  } catch (error) {
    console.error("coach_dispatch_failed", {
      job: label,
      message: error instanceof Error ? error.name : "unknown",
    });
  }
}
