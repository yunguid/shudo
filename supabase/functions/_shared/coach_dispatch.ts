import { requiredEnv, runInBackground } from "./http.ts";

/// Fire-and-forget hand-off to the coach_tick maintenance function, which
/// runs each job in a fresh worker with its own wall clock. Authenticated by
/// the existing weekly maintenance secret; no user credentials travel.

export type CoachJobName =
  | "day_digest"
  | "training_plan"
  | "body_review"
  | "plan";

export type CoachJob =
  | { mode: "daily" }
  | {
    mode?: "job";
    job: CoachJobName;
    user_id: string;
    payload?: Record<string, unknown>;
  };

/// Alias kept for readability at call sites that build requests.
export type CoachJobRequest = CoachJob;

export type NormalizedCoachJob =
  | { mode: "daily" }
  | {
    mode: "job";
    job: CoachJobName;
    user_id: string;
    payload: Record<string, unknown>;
  };

export function normalizeCoachJob(request: CoachJob): NormalizedCoachJob {
  if ("job" in request) {
    return {
      mode: "job",
      job: request.job,
      user_id: request.user_id,
      payload: request.payload ?? {},
    };
  }
  return { mode: "daily" };
}

const DISPATCH_TIMEOUT_MS = 10_000;

export type CoachDispatchDependencies = {
  fetch?: typeof fetch;
  env?: (name: string) => string | undefined;
};

function jobLabel(request: CoachJob): string {
  return "job" in request ? request.job : "daily";
}

/**
 * POSTs one job to coach_tick and waits only for the 202. Never throws:
 * callers have already made their own work durable, so a failed dispatch is
 * logged (job name and status only) and the next trigger recovers it.
 * Resolves true when coach_tick accepted the job.
 */
export async function dispatchCoachJob(
  request: CoachJob,
  dependencies: CoachDispatchDependencies = {},
): Promise<boolean> {
  const env = dependencies.env ??
    ((name: string) => Deno.env.get(name)?.trim());
  const send = dependencies.fetch ?? fetch;
  try {
    const supabaseUrl = (env("SUPABASE_URL") ?? requiredEnv("SUPABASE_URL"))
      .replace(/\/+$/u, "");
    const secret = env("SHUDO_WEEKLY_SECRET") ??
      requiredEnv("SHUDO_WEEKLY_SECRET");
    const anonKey = env("SUPABASE_ANON_KEY");
    const response = await send(`${supabaseUrl}/functions/v1/coach_tick`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-shudo-weekly-secret": secret,
        // coach_tick runs with verify_jwt off; the anon key only keeps the
        // request routable through the gateway like every other call.
        ...(anonKey ? { apikey: anonKey } : {}),
      },
      body: JSON.stringify(normalizeCoachJob(request)),
      signal: AbortSignal.timeout(DISPATCH_TIMEOUT_MS),
    });
    await response.body?.cancel().catch(() => undefined);
    if (!response.ok) {
      console.error("coach_job_dispatch_failed", {
        job: jobLabel(request),
        status: response.status,
      });
      return false;
    }
    return true;
  } catch (error) {
    console.error("coach_job_dispatch_failed", {
      job: jobLabel(request),
      message: error instanceof Error ? error.name : "unknown",
    });
    return false;
  }
}

/** Registers the dispatch as background work and returns immediately. */
export function scheduleCoachJob(
  request: CoachJob,
  dependencies: CoachDispatchDependencies & {
    observe?: (promise: Promise<unknown>) => void;
  } = {},
): void {
  const task = dispatchCoachJob(request, dependencies);
  try {
    (dependencies.observe ?? runInBackground)(task);
  } catch {
    // Outside the Edge runtime (tests, scripts) there is no waitUntil; the
    // promise still settles on its own and never rejects.
  }
}
