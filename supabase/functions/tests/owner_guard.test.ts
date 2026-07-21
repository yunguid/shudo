import { evaluateOwnerAccess, hasOwnerPolicy } from "../_shared/owner_guard.ts";
import { assert, assertEquals } from "./assertions.ts";

Deno.test("owner policy fails closed when no owner is configured", () => {
  assert(!hasOwnerPolicy(undefined, "  "));
  assertEquals(
    evaluateOwnerAccess({ id: "user-1", email: "owner@example.com" }),
    "missing_policy",
  );
});

Deno.test("owner id and email policies are each enforced", () => {
  const user = { id: "user-1", email: "Owner@Example.com" };
  assertEquals(evaluateOwnerAccess(user, "user-1", null), "allowed");
  assertEquals(evaluateOwnerAccess(user, "user-2", null), "denied");
  assertEquals(
    evaluateOwnerAccess(user, null, " owner@example.com "),
    "allowed",
  );
  assertEquals(evaluateOwnerAccess(user, null, "other@example.com"), "denied");
  assertEquals(
    evaluateOwnerAccess(
      { id: "user-1", email: null },
      null,
      "owner@example.com",
    ),
    "denied",
  );
});

Deno.test("when both owner claims are configured both must match", () => {
  const owner = { id: "user-1", email: "owner@example.com" };
  assertEquals(
    evaluateOwnerAccess(owner, " user-1 ", "OWNER@example.com"),
    "allowed",
  );
  assertEquals(
    evaluateOwnerAccess(owner, "user-1", "intruder@example.com"),
    "denied",
  );
  assertEquals(
    evaluateOwnerAccess(owner, "user-2", "owner@example.com"),
    "denied",
  );
});
