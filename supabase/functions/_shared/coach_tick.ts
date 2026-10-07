import {
  createClient,
  type SupabaseClient,
} from "jsr:@supabase/supabase-js@2.110.7";
import { coachCardCopyGuard } from "./coach_copy.ts";
import { runDayDigest } from "./coach_digest.ts";
import {
  type CoachJob,
  type CoachJobName,
  dispatchCoachJob,
} from "./coach_dispatch.ts";
import { type CoachPlanTrigger, runCoachPlan } from "./coach_plan.ts";
import {
  addDays,
  coachLocalDay,
  isValidTimezone,
  weekdayOf,
} from "./coach_policy.ts";
import { runCoachHousekeeping } from "./coach_rpc.ts";
import { CORS_HEADERS, isUuid, json, runInBackground } from "./http.ts";
import { reviewPhysique } from "./physique_review.ts";
import { secretMatches } from "./secrets.ts";
import { draftTrainingPlan } from "./training_plan.ts";

/// coach_tick: the coach's maintenance entry point (verify_jwt=false,
/// x-shudo-weekly-secret). `daily` fans out one job per coach-enabled user;
/// `job` runs one job in this fresh worker.

const PLAN_TRIGGERS: readonly CoachPlanTrigger[] = [
  "foreground",
  "meal_complete",
  "meal_corrected",
  "activity_complete",
  "checkin",
  "settings",
  "bg_refresh",
  "chat",
  "daily",
];
const JOB_NAMES: readonly CoachJobName[] = [
  "day_digest",
  "training_plan",
  "body_review",
  "plan",
];

export type CoachJobRunners = {
  runCoachPlan: typeof runCoachPlan;
  runDayDigest: typeof runDayDigest;
  draftTrainingPlan: typeof draftTrainingPlan;
  reviewPhysique: typeof reviewPhysique;
};

export type CoachTickDependencies = {
  env: (name: string) => string | undefined;
  createAdmin: () => SupabaseClient;
  observe: (promise: Promise<unknown>) => void;
  now: () => Date;
  dispatch: (job: CoachJob) => Promise<boolean | void>;
  runners: CoachJobRunners;
};

export function defaultCoachTickDependencies(): CoachTickDependencies {
  const env = (name: string) => Deno.env.get(name)?.trim() || undefined;
  return {
    env,
    createAdmin: () =>
      createClient(
        env("SUPABASE_URL") ?? "",
        env("SUPABASE_SERVICE_ROLE_KEY") ?? "",
        {
          auth: { persistSession: false, autoRefreshToken: false },
        },
      ),
    observe: runInBackground,
    now: () => new Date(),
    dispatch: (job) => dispatchCoachJob(job),
    runners: { runCoachPlan, runDayDigest, draftTrainingPlan, reviewPhysique },
  };
}

type CoachProfileRow = {
  user_id: string;
  timezone: string | null;
  physique_ai_review_enabled: boolean | null;
};

/**
 * One job per coach-enabled user: yesterday's digest when it is missing
 * (the digest job then plans the morning), otherwise the morning plan. On
 * the user's Monday, a weekly physique review when they opted in.
 */
export async function planDailyCoachJobs(
  admin: SupabaseClient,
  now: Date,
): Promise<CoachJob[]> {
  const jobs: CoachJob[] = [];
  for (let offset = 0;; offset += 100) {
    const { data, error } = await admin.from("profiles")
      .select("user_id,timezone,physique_ai_review_enabled")
      .eq("coach_enabled", true)
      .order("user_id")
      .range(offset, offset + 99);
    if (error) throw error;
    const profiles = (data ?? []) as CoachProfileRow[];
    for (const profile of profiles) {
      const timezone = profile.timezone && isValidTimezone(profile.timezone)
        ? profile.timezone
        : "UTC";
      const today = coachLocalDay(now, timezone);
      const yesterday = addDays(today, -1);
      const { data: digest, error: digestError } = await admin.from(
        "day_digests",
      )
        .select("local_day")
        .eq("user_id", profile.user_id)
        .eq("local_day", yesterday)
        .maybeSingle();
      if (digestError) throw digestError;
      jobs.push(
        digest
          ? {
            job: "plan",
            user_id: profile.user_id,
            payload: { trigger: "daily" },
          }
          : {
            job: "day_digest",
            user_id: profile.user_id,
            payload: { digest_day: yesterday },
          },
      );
      if (weekdayOf(today) === "mon" && profile.physique_ai_review_enabled) {
        jobs.push({
          job: "body_review",
          user_id: profile.user_id,
          payload: { anchor_day: today, kind: "weekly" },
        });
      }
    }
    if (profiles.length < 100) break;
  }
  return jobs;
}

function text(value: unknown, max: number): string | null {
  return typeof value === "string" && value.trim()
    ? value.trim().slice(0, max)
    : null;
}

function localDay(value: unknown): string | null {
  return typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/u.test(value)
    ? value
    : null;
}

/** Runs one job to completion; failures are logged, never thrown. */
export async function runCoachJob(
  admin: SupabaseClient,
  job: { job: CoachJobName; user_id: string; payload: Record<string, unknown> },
  dependencies: Pick<CoachTickDependencies, "now" | "runners">,
): Promise<void> {
  const { runners } = dependencies;
  const userId = job.user_id;
  const payload = job.payload;
  try {
    switch (job.job) {
      case "plan": {
        const trigger =
          PLAN_TRIGGERS.includes(payload.trigger as CoachPlanTrigger)
            ? payload.trigger as CoachPlanTrigger
            : "foreground";
        const entryId = text(payload.entry_id, 36);
        const activityId = text(payload.activity_id, 36);
        await runners.runCoachPlan(admin, {
          userId,
          trigger,
          entryId: entryId && isUuid(entryId) ? entryId.toLowerCase() : null,
          activityId: activityId && isUuid(activityId)
            ? activityId.toLowerCase()
            : null,
          foreground: payload.foreground === true,
        }, { now: dependencies.now });
        return;
      }
      case "day_digest": {
        const outcome = await runners.runDayDigest(admin, {
          userId,
          digestDay: localDay(payload.digest_day),
        }, { now: dependencies.now });
        if (outcome.status !== "disabled") {
          await runners.runCoachPlan(
            admin,
            { userId, trigger: "daily" },
            { now: dependencies.now },
          );
        }
        return;
      }
      case "training_plan": {
        const reason =
          payload.reason === "user_request" || payload.reason === "weekly"
            ? payload.reason
            : "first_plan";
        const requestId = text(payload.request_id, 36);
        await runners.draftTrainingPlan(admin, userId, {
          instructions: text(payload.instructions, 2_000),
          reason,
          ...(requestId && isUuid(requestId)
            ? { requestId: requestId.toLowerCase() }
            : {}),
        }, { copyGuard: coachCardCopyGuard });
        return;
      }
      case "body_review": {
        const anchorDay = localDay(payload.anchor_day) ??
          dependencies.now().toISOString().slice(0, 10);
        await runners.reviewPhysique(admin, userId, {
          anchorDay,
          kind: payload.kind === "weekly" ? "weekly" : "on_demand",
        }, { copyGuard: coachCardCopyGuard });
        return;
      }
    }
  } catch (error) {
    console.error("coach_job_failed", {
      job: job.job,
      userId,
      message: String((error as Error)?.message ?? error).slice(0, 300),
    });
  }
}

export async function handleCoachTick(
  req: Request,
  dependencies: CoachTickDependencies,
): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);
  try {
    const expected = dependencies.env("SHUDO_WEEKLY_SECRET") ?? "";
    if (expected.length < 32) {
      console.error("coach_tick_misconfigured", { reason: "weekly_secret" });
      return json({ error: "Coach maintenance is not configured" }, 500);
    }
    const supplied = req.headers.get("x-shudo-weekly-secret")?.trim() ?? "";
    if (!supplied || !await secretMatches(supplied, expected)) {
      return json({ error: "Authentication required" }, 401);
    }
    const body = await req.json().catch(() => null) as
      | Record<string, unknown>
      | null;
    if (!body || typeof body !== "object") {
      return json({ error: "Expected a JSON object" }, 400);
    }
    const admin = dependencies.createAdmin();

    if (body.mode === "daily") {
      const housekeeping = await runCoachHousekeeping(admin).catch((error) => {
        console.error("coach_housekeeping_failed", { message: String(error) });
        return null;
      });
      const jobs = await planDailyCoachJobs(admin, dependencies.now());
      const results = await Promise.all(
        jobs.map((job) => dependencies.dispatch(job)),
      );
      return json({
        mode: "daily",
        dispatched: results.filter((result) => result !== false).length,
        failed: results.filter((result) => result === false).length,
        housekeeping,
      }, 202);
    }

    if (body.mode === "job") {
      const name = body.job as CoachJobName;
      const userId = typeof body.user_id === "string"
        ? body.user_id.toLowerCase()
        : "";
      if (!JOB_NAMES.includes(name) || !isUuid(userId)) {
        return json({ error: "Unknown coach job" }, 400);
      }
      const payload = body.payload && typeof body.payload === "object" &&
          !Array.isArray(body.payload)
        ? body.payload as Record<string, unknown>
        : {};
      // Answer immediately; the job keeps this worker's wall clock.
      dependencies.observe(
        runCoachJob(
          admin,
          { job: name, user_id: userId, payload },
          dependencies,
        ),
      );
      return json({ accepted: true, job: name }, 202);
    }
    return json({ error: "Unknown coach tick mode" }, 400);
  } catch (error) {
    console.error("coach_tick_failed", {
      message: String((error as Error)?.message ?? error).slice(0, 300),
    });
    return json({ error: "Coach maintenance failed" }, 500);
  }
}
