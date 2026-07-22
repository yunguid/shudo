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
  assertEquals(daily?.status, 429);
  assertEquals(daily?.message.includes("30-meal"), true);
  assertEquals(active?.status, 409);
  assertEquals(consumed?.status, 409);
  assertEquals(project?.status, 429);
  assertEquals(project?.message.includes("shared beta AI limit"), true);
  assertEquals(modelQuotaHttpError(new Error("other")), null);
});
