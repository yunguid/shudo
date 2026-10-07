import { modelQuotaHttpError } from "../_shared/quotas.ts";
import { assertEquals } from "./assertions.ts";

Deno.test("database quota signals map to deterministic friendly responses", () => {
  const daily = modelQuotaHttpError({ message: "entry_daily_quota_exceeded" });
  const active = modelQuotaHttpError({
    message: "onboarding_concurrency_quota_exceeded",
  });
  const consumed = modelQuotaHttpError({
    message: "entry_request_already_consumed",
  });
  const project = modelQuotaHttpError({
    message: "project_ai_budget_exceeded",
  });
  const beta = modelQuotaHttpError({ message: "beta_access_required" });
  assertEquals(daily?.status, 429);
  assertEquals(daily?.message.includes("30-meal"), true);
  assertEquals(active?.status, 409);
  assertEquals(consumed?.status, 409);
  assertEquals(project?.status, 429);
  assertEquals(project?.message.includes("shared beta AI limit"), true);
  assertEquals(beta?.status, 403);
  assertEquals(beta?.message.includes("not part of the Shudo beta"), true);
  assertEquals(modelQuotaHttpError(new Error("other")), null);
});

Deno.test("coach spend and activity quota signals map to friendly responses", () => {
  const spend = modelQuotaHttpError({ message: "project_ai_spend_exceeded" });
  const daily = modelQuotaHttpError({
    message: "activity_daily_quota_exceeded",
  });
  const active = modelQuotaHttpError({
    message: "activity_concurrency_quota_exceeded",
  });
  assertEquals(spend?.status, 429);
  assertEquals(spend?.message.includes("AI budget"), true);
  assertEquals(daily?.status, 429);
  assertEquals(daily?.message.includes("40-workout"), true);
  assertEquals(active?.status, 429);
  assertEquals(active?.message.includes("still processing"), true);
});
