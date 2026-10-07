import { coachCardCopyGuard } from "../_shared/coach_copy.ts";
import type { CoachJob } from "../_shared/coach_dispatch.ts";
import {
  type CoachJobRunners,
  type CoachTickDependencies,
  handleCoachTick,
  planDailyCoachJobs,
} from "../_shared/coach_tick.ts";
import { assert, assertEquals } from "./assertions.ts";
import { coachFakeAdmin, type Row } from "./coach_fake_admin.ts";

const SECRET = "s".repeat(40);
const A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const C = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
// The daily Vercel cron fires at 09:17 UTC: Monday 05:17 in New York.
const NOW = new Date("2026-10-05T09:17:00Z");

function profiles(): Row[] {
  return [
    {
      user_id: A,
      timezone: "America/New_York",
      coach_enabled: true,
      physique_ai_review_enabled: true,
    },
    {
      user_id: B,
      timezone: "Asia/Tokyo",
      coach_enabled: true,
      physique_ai_review_enabled: false,
    },
    {
      user_id: C,
      timezone: "America/New_York",
      coach_enabled: false,
      physique_ai_review_enabled: true,
    },
  ];
}

function harness() {
  const fake = coachFakeAdmin({
    tables: {
      profiles: profiles(),
      day_digests: [{
        user_id: B,
        local_day: "2026-10-04",
        headline: "Solid day",
      }],
    },
    rpc: { run_coach_housekeeping: () => ({ delivered: 2, failed_runs: 0 }) },
  });
  const dispatched: CoachJob[] = [];
  const observed: Promise<unknown>[] = [];
  const calls: Array<{ runner: string; args: unknown[] }> = [];
  const runners: CoachJobRunners = {
    runCoachPlan: (...args) => {
      calls.push({ runner: "plan", args });
      return Promise.resolve({
        status: "complete",
        runId: null,
        generated: true,
        messageIds: [],
      });
    },
    runDayDigest: (...args) => {
      calls.push({ runner: "digest", args });
      return Promise.resolve({
        status: "complete",
        runId: null,
        digestDay: "2026-10-04",
        gamePlan: null,
      });
    },
    draftTrainingPlan: (...args) => {
      calls.push({ runner: "training_plan", args });
      return Promise.resolve({ planId: "p", plan: {} as never, summary: "" });
    },
    reviewPhysique: (...args) => {
      calls.push({ runner: "body_review", args });
      return Promise.resolve();
    },
  };
  const dependencies: CoachTickDependencies = {
    env: (name) => name === "SHUDO_WEEKLY_SECRET" ? SECRET : undefined,
    createAdmin: () => fake.admin as never,
    observe: (promise) => observed.push(promise),
    now: () => NOW,
    dispatch: (job) => {
      dispatched.push(job);
      return Promise.resolve(true);
    },
    runners,
  };
  return { fake, dispatched, observed, calls, dependencies };
}

function post(body: unknown, secret = SECRET): Request {
  return new Request("https://example.test/functions/v1/coach_tick", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-shudo-weekly-secret": secret,
    },
    body: JSON.stringify(body),
  });
}

Deno.test("coach_tick rejects calls without the weekly secret", async () => {
  const { dependencies } = harness();
  assertEquals(
    (await handleCoachTick(post({ mode: "daily" }, "wrong"), dependencies))
      .status,
    401,
  );
  const misconfigured = { ...dependencies, env: () => "short" };
  assertEquals(
    (await handleCoachTick(post({ mode: "daily" }), misconfigured)).status,
    500,
  );
});

Deno.test("daily mode digests yesterday where missing, otherwise plans the morning", async () => {
  const { dispatched, fake, dependencies } = harness();
  const response = await handleCoachTick(post({ mode: "daily" }), dependencies);
  assertEquals(response.status, 202);
  const body = await response.json();
  assertEquals(body.dispatched, 3);
  assertEquals(body.housekeeping, { delivered: 2, failed_runs: 0 });
  assert(fake.rpcCalls.some((call) => call.name === "run_coach_housekeeping"));
  assertEquals(dispatched, [
    { job: "day_digest", user_id: A, payload: { digest_day: "2026-10-04" } },
    {
      job: "body_review",
      user_id: A,
      payload: { anchor_day: "2026-10-05", kind: "weekly" },
    },
    { job: "plan", user_id: B, payload: { trigger: "daily" } },
  ]);
});

Deno.test("the daily digest day follows the 04:00 local boundary", async () => {
  const { fake } = harness();
  // 03:30 in New York is still Sunday's coach day: digest Saturday.
  const jobs = await planDailyCoachJobs(
    fake.admin as never,
    new Date("2026-10-05T07:30:00Z"),
  );
  assertEquals(jobs[0], {
    job: "day_digest",
    user_id: A,
    payload: { digest_day: "2026-10-03" },
  });
  // Sunday has no weekly physique review.
  assertEquals(
    jobs.some((job) => "job" in job && job.job === "body_review"),
    false,
  );
});

Deno.test("job mode answers 202 at once and runs the job in the background", async () => {
  const { observed, calls, dependencies } = harness();
  const response = await handleCoachTick(
    post({
      mode: "job",
      job: "plan",
      user_id: A.toUpperCase(),
      payload: {
        trigger: "activity_complete",
        activity_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      },
    }),
    dependencies,
  );
  assertEquals(response.status, 202);
  assertEquals(observed.length, 1);
  await observed[0];
  assertEquals(calls[0].runner, "plan");
  const planRequest = calls[0].args[1] as Row;
  assertEquals(planRequest.userId, A);
  assertEquals(planRequest.trigger, "activity_complete");
  assertEquals(planRequest.activityId, "dddddddd-dddd-4ddd-8ddd-dddddddddddd");
});

Deno.test("each job name routes to its runner with the coach voice guard", async () => {
  const { observed, calls, dependencies } = harness();
  for (
    const job of [
      { job: "day_digest", payload: { digest_day: "2026-10-04" } },
      {
        job: "training_plan",
        payload: {
          instructions: "Four days, before work",
          reason: "user_request",
        },
      },
      {
        job: "body_review",
        payload: { anchor_day: "2026-10-05", kind: "on_demand" },
      },
    ]
  ) {
    const response = await handleCoachTick(
      post({ mode: "job", user_id: A, ...job }),
      dependencies,
    );
    assertEquals(response.status, 202);
  }
  await Promise.all(observed);
  assertEquals(calls.map((call) => call.runner), [
    "digest",
    "plan",
    "training_plan",
    "body_review",
  ]);
  assertEquals((calls[1].args[1] as Row).trigger, "daily");
  assertEquals(calls[2].args[2], {
    instructions: "Four days, before work",
    reason: "user_request",
  });
  assertEquals((calls[2].args[3] as Row).copyGuard, coachCardCopyGuard);
  assertEquals(calls[3].args[2], {
    anchorDay: "2026-10-05",
    kind: "on_demand",
  });

  const unknown = await handleCoachTick(
    post({ mode: "job", job: "nope", user_id: A }),
    dependencies,
  );
  assertEquals(unknown.status, 400);
});
