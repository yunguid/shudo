import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2.110.7";
import { dispatchCoachJob } from "../_shared/coach_dispatch.ts";
import { json, requiredEnv, runInBackground } from "../_shared/http.ts";
import { secretMatches } from "../_shared/secrets.ts";
import {
  generateClaimedSummary,
  safePriorCompletedWeekStart,
  type WeeklySummaryClaim,
} from "../_shared/weekly_summary.ts";

type Profile = {
  user_id: string;
  timezone: string;
  daily_macro_target: Record<string, unknown>;
};

type Claim = WeeklySummaryClaim;

/// The daily cron also drives the coach: once this run is authenticated,
/// coach_tick's daily mode is dispatched after the weekly work, whether or
/// not the summaries succeeded (fire-and-forget, never blocks the response).
function dispatchDailyCoach(): void {
  runInBackground(dispatchCoachJob({ mode: "daily" }));
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  let authenticated = false;
  try {
    const expected = requiredEnv("SHUDO_WEEKLY_SECRET");
    if (expected.length < 32) {
      throw new Error(
        "SHUDO_WEEKLY_SECRET must contain at least 32 characters",
      );
    }
    const supplied = req.headers.get("x-shudo-weekly-secret")?.trim() ?? "";
    if (!supplied || !await secretMatches(supplied, expected)) {
      return json({ error: "Authentication required" }, 401);
    }
    authenticated = true;
    const payload = await req.json().catch(() => null) as
      | { limit?: unknown }
      | null;
    const requested = typeof payload?.limit === "number"
      ? Math.trunc(payload.limit)
      : 5;
    const generationLimit = Math.max(1, Math.min(5, requested));
    const admin = createClient(
      requiredEnv("SUPABASE_URL"),
      requiredEnv("SUPABASE_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false, autoRefreshToken: false } },
    );

    const jobs: Array<{ profile: Profile; weekStart: string; claim: Claim }> =
      [];
    let skipped = 0;
    let offset = 0;
    while (jobs.length < generationLimit) {
      const { data, error } = await admin.from("profiles")
        .select("user_id,timezone,daily_macro_target")
        .eq("weekly_summary_enabled", true)
        .order("user_id")
        .range(offset, offset + 99);
      if (error) throw error;
      const profiles = (data ?? []) as Profile[];
      for (const profile of profiles) {
        const weekStart = safePriorCompletedWeekStart(
          new Date(),
          profile.timezone,
        );
        if (!weekStart) {
          skipped += 1;
          console.error("weekly_summary_profile_skipped", {
            userId: profile.user_id,
            reason: "invalid_timezone",
          });
          continue;
        }
        try {
          const { data: claimData, error: claimError } = await admin.rpc(
            "claim_weekly_summary",
            { p_user_id: profile.user_id, p_week_start: weekStart },
          );
          if (claimError) throw claimError;
          const claim = Array.isArray(claimData)
            ? claimData[0] as Claim | undefined
            : undefined;
          if (claim) jobs.push({ profile, weekStart, claim });
        } catch (error) {
          skipped += 1;
          console.error("weekly_summary_profile_skipped", {
            userId: profile.user_id,
            reason: "claim_failed",
            message: String(error),
          });
        }
        if (jobs.length >= generationLimit) break;
      }
      if (profiles.length < 100) break;
      offset += profiles.length;
    }

    const outcomes = await Promise.all(
      jobs.map((job) =>
        generateClaimedSummary(admin, job.profile, job.weekStart, job.claim)
      ),
    );
    dispatchDailyCoach();
    return json({
      claimed: jobs.length,
      completed: outcomes.filter(Boolean).length,
      failed: outcomes.filter((value) => !value).length,
      skipped,
    });
  } catch (error) {
    console.error("scheduled_weekly_summaries_failed", {
      message: String(error),
    });
    if (authenticated) dispatchDailyCoach();
    return json({ error: "Could not generate weekly summaries" }, 500);
  }
});
