import {
  COACH_TOOL_DEFINITIONS,
  STRICT_SCHEMA_LIMITS,
} from "../_shared/coach_tools.ts";
import { assert } from "./assertions.ts";

type SchemaCounts = { unions: number; optional: number };

function countSchema(node: unknown, counts: SchemaCounts): void {
  if (!node || typeof node !== "object") return;
  if (Array.isArray(node)) {
    for (const child of node) countSchema(child, counts);
    return;
  }
  const object = node as Record<string, unknown>;
  if (Array.isArray(object.anyOf) || Array.isArray(object.type)) {
    counts.unions += 1;
  }
  if (object.properties && typeof object.properties === "object") {
    const required = new Set(
      Array.isArray(object.required) ? object.required : [],
    );
    for (const key of Object.keys(object.properties)) {
      if (!required.has(key)) counts.optional += 1;
    }
  }
  for (const value of Object.values(object)) {
    if (value && typeof value === "object") countSchema(value, counts);
  }
}

Deno.test("strict chat tools stay inside the API's combined schema limits", () => {
  const strictTools = COACH_TOOL_DEFINITIONS.filter((tool) =>
    (tool as { strict?: boolean }).strict === true
  );
  const counts: SchemaCounts = { unions: 0, optional: 0 };
  for (const tool of strictTools) {
    countSchema((tool as { input_schema?: unknown }).input_schema, counts);
  }
  assert(
    strictTools.length <= STRICT_SCHEMA_LIMITS.strictTools,
    `${strictTools.length} strict tools`,
  );
  assert(
    counts.unions <= STRICT_SCHEMA_LIMITS.unionParams,
    `${counts.unions} union-typed params across strict tools (limit ${STRICT_SCHEMA_LIMITS.unionParams})`,
  );
  assert(
    counts.optional <= STRICT_SCHEMA_LIMITS.optionalParams,
    `${counts.optional} optional params across strict tools`,
  );
});

Deno.test("every structured-output schema fits the per-request limits on its own", async () => {
  const { toClaudeSchema } = await import("../_shared/claude.ts");
  const schemas: Record<string, unknown> = {
    meal: (await import("../_shared/analysis.ts")).RESULT_SCHEMA,
    activity: (await import("../_shared/activity_analysis.ts"))
      .ACTIVITY_RESULT_SCHEMA,
    digest: (await import("../_shared/coach_digest.ts")).DAY_DIGEST_SCHEMA,
    training_plan: (await import("../_shared/training_plan.ts"))
      .TRAINING_PLAN_RESPONSE_SCHEMA,
    bio_merge: (await import("../_shared/coach_bio.ts")).BIO_MERGE_SCHEMA,
    physique: (await import("../_shared/physique_review.ts"))
      .PHYSIQUE_RESPONSE_SCHEMA,
    nearby: (await import("../_shared/nearby_food.ts")).nearbyResponseSchema([
      "s1",
      "s2",
      "home",
      "any",
    ]),
    coach_plan: (await import("../_shared/coach_plan.ts")).COACH_PLAN_SCHEMA,
    weekly: (await import("../_shared/weekly_summary.ts"))
      .WEEKLY_SUMMARY_SCHEMA,
    onboarding: (await import("../_shared/onboarding.ts")).ONBOARDING_SCHEMA,
  };
  for (const [name, schema] of Object.entries(schemas)) {
    const counts: SchemaCounts = { unions: 0, optional: 0 };
    countSchema(toClaudeSchema(schema), counts);
    assert(
      counts.unions <= STRICT_SCHEMA_LIMITS.unionParams,
      `${name}: ${counts.unions} union-typed params`,
    );
    assert(
      counts.optional <= STRICT_SCHEMA_LIMITS.optionalParams,
      `${name}: ${counts.optional} optional params`,
    );
  }
});
