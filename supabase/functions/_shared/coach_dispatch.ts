import { requiredEnv, runInBackground } from "./http.ts";

/// Fire-and-forget hand-off to the coach_tick maintenance function, which
/// runs each job in a fresh worker with its own wall clock. Authenticated by
/// the existing weekly maintenance secret; no user credentials travel.

export type CoachJobName = "day_digest" | "training_plan" | "body_review" | "plan";

export type CoachJobRequest =
  | { mode: "daily" }
  | {
    mode?: "job";
    job: CoachJobName;
    user_id: string;
    payload?: Record<string, unknown>;
  };

export type NormalizedCoachJob =
  | { mode: "daily" }
  | {
    mode: "job";
    job: CoachJobName;
    user_id: string;
    payload: Record<string, unknown>;
  };

export function normalizeCoachJob(request: CoachJobRequest): NormalizedCoachJob {
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
  env?: (name: string) => string;
};

export async function dispatchCoachJob(
  request: CoachJobRequest,
  dependencies: CoachDispatchDependencies = {},
): Promise<void> {
  const env = dependencies.env ?? requiredEnv;
  const send = dependencies.fetch ?? fetch;
  const supabaseUrl = env("SUPABASE_URL").replace(/\/+$/u, "");
  const response = await send(`${supabaseUrl}/functions/v1/coach_tick`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      // The gateway's verify_jwt is off for coach_tick; the anon key keeps
      // the request routable like every other function call.
      apikey: env("SUPABASE_ANON_KEY"),
      "x-shudo-weekly-secret": env("SHUDO_WEEKLY_SECRET"),
    },
    body: JSON.stringify(normalizeCoachJob(request)),
    signal: AbortSignal.timeout(DISPATCH_TIMEOUT_MS),
  });
  // The body is never needed; release the connection.
  await response.body?.cancel().catch(() => undefined);
  if (!response.ok) {
    throw new Error(`Coach job dispatch failed (${response.status})`);
  }
}

/**
 * Registers the dispatch as background work and returns immediately. Never
 * throws: a missed coach refresh is recovered by the next trigger.
 */
export function scheduleCoachJob(
  request: CoachJobRequest,
  dependencies: CoachDispatchDependencies & {
    observe?: (promise: Promise<unknown>) => void;
  } = {},
): void {
  const label = "job" in request ? request.job : "daily";
  const task = dispatchCoachJob(request, dependencies).catch((error) => {
    console.error("coach_job_dispatch_failed", {
      job: label,
      message: String((error as Error)?.message ?? error),
    });
  });
  try {
    (dependencies.observe ?? runInBackground)(task);
  } catch {
    // Outside the Edge runtime (tests, scripts) there is no waitUntil; the
    // promise still settles on its own.
  }
}
