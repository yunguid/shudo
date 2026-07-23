import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import {
  createClient,
  type SupabaseClient,
} from "jsr:@supabase/supabase-js@2.110.7";
import { json, requiredEnv } from "../_shared/http.ts";
import { secretMatches } from "../_shared/secrets.ts";
import {
  addCalendarDays,
  aggregateWeeklyEntries,
  safePriorCompletedWeekStart,
  WEEKLY_SUMMARY_MODEL,
  type WeeklyEntry,
  type WeeklyTarget,
  writeWeeklyNarrative,
} from "../_shared/weekly_summary.ts";

type Profile = {
  user_id: string;
  timezone: string;
  daily_macro_target: Record<string, unknown>;
};

type Claim = {
  summary_id: string;
  input_fingerprint: string;
  generation_attempt: number;
};

async function generateOne(
  admin: SupabaseClient,
  profile: Profile,
  weekStart: string,
  claim: Claim,
): Promise<boolean> {
  try {
    const weekEnd = addCalendarDays(weekStart, 6);
    const [entriesResult, targetsResult] = await Promise.all([
      admin.from("entries")
        .select(
          "local_day,title,items,calories_kcal,protein_g,carbs_g,fat_g",
        )
        .eq("user_id", profile.user_id)
        .eq("status", "complete")
        .gte("local_day", weekStart)
        .lt("local_day", addCalendarDays(weekStart, 7)),
      // At most seven changes can occur inside a seven-day week because the
      // ledger has one row per day; the eighth row is the preceding target.
      admin.from("daily_targets")
        .select("target_day,calories_kcal,protein_g,carbs_g,fat_g")
        .eq("user_id", profile.user_id)
        .lte("target_day", weekEnd)
        .order("target_day", { ascending: false })
        .limit(8),
    ]);
    if (entriesResult.error) throw entriesResult.error;
    if (targetsResult.error) throw targetsResult.error;
    const { adherence, repeatedFoods, foodCandidates } = aggregateWeeklyEntries(
      (entriesResult.data ?? []) as WeeklyEntry[],
      (targetsResult.data ?? []) as WeeklyTarget[],
      profile.daily_macro_target ?? {},
    );
    const narrative = await writeWeeklyNarrative(
      profile.user_id,
      weekStart,
      adherence,
      repeatedFoods,
      foodCandidates,
    );
    const { data: updated, error: updateError } = await admin
      .from("weekly_summaries")
      .update({
        status: "complete",
        headline: narrative.headline,
        narrative: narrative.narrative,
        repeated_foods: repeatedFoods,
        patterns: narrative.patterns,
        adherence,
        suggestions: narrative.suggestions,
        analysis_model: WEEKLY_SUMMARY_MODEL,
        provider_response_id: narrative.responseId,
        generated_at: new Date().toISOString(),
        lease_expires_at: null,
        error_message: null,
      })
      .eq("id", claim.summary_id)
      .eq("user_id", profile.user_id)
      .eq("input_fingerprint", claim.input_fingerprint)
      .eq("generation_attempt", claim.generation_attempt)
      .eq("status", "generating")
      .select("id")
      .maybeSingle();
    if (updateError) throw updateError;
    return updated !== null;
  } catch (error) {
    await admin.from("weekly_summaries").update({
      status: "failed",
      lease_expires_at: null,
      error_message: String(error).slice(0, 500),
    })
      .eq("id", claim.summary_id)
      .eq("user_id", profile.user_id)
      .eq("input_fingerprint", claim.input_fingerprint)
      .eq("generation_attempt", claim.generation_attempt)
      .eq("status", "generating");
    console.error("weekly_summary_user_failed", {
      userId: profile.user_id,
      weekStart,
      message: String(error),
    });
    return false;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
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
        generateOne(admin, job.profile, job.weekStart, job.claim)
      ),
    );
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
    return json({ error: "Could not generate weekly summaries" }, 500);
  }
});
