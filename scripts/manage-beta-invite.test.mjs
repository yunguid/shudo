import assert from "node:assert/strict";
import test from "node:test";

import {
  DATABASE_QUERY_URL,
  normalizeEmail,
  parseArgs,
  run,
  writeQueryFor,
} from "./manage-beta-invite.mjs";

test("invite arguments normalize email and require explicit apply", () => {
  assert.deepEqual(parseArgs(["add", " Friend@Example.com ", "Friend beta"]), {
    help: false,
    action: "add",
    apply: false,
    email: "friend@example.com",
    note: "Friend beta",
  });
  assert.equal(parseArgs(["disable", "friend@example.com", "--apply"]).apply, true);
  assert.equal(normalizeEmail("LUKE@YNG.SH"), "luke@yng.sh");
  assert.throws(() => parseArgs(["remove"]), /Invalid arguments/);
  assert.throws(() => parseArgs(["add", "not-an-email"]), /valid address/);
});

test("fixed mutation queries use parameters instead of interpolated email", () => {
  for (const action of ["add", "enable", "disable", "remove"]) {
    const query = writeQueryFor(action);
    assert.match(query, /\$1::text/);
    assert.doesNotMatch(query, /friend@example\.com/);
  }
});

test("dry run uses the privileged query endpoint in read-only mode", async () => {
  const calls = [];
  const result = await run({
    argv: ["add", "friend@example.com"],
    env: { SUPABASE_ACCESS_TOKEN: "sbp_testtoken" },
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      return new Response("[]", { status: 201 });
    },
    log: () => {},
  });
  assert.equal(result.applied, false);
  assert.deepEqual(calls.map(({ url }) => url), [DATABASE_QUERY_URL]);
  const requestBody = JSON.parse(calls[0].options.body);
  assert.match(requestBody.query, /from public\.beta_signup_allowlist/u);
  assert.deepEqual(requestBody.parameters, ["friend@example.com"]);
  assert.equal(requestBody.read_only, true);
});

test("apply writes once and verifies with a fresh read", async () => {
  const calls = [];
  const email = "friend@example.com";
  const result = await run({
    argv: ["add", email, "Friend beta", "--apply"],
    env: { SUPABASE_ACCESS_TOKEN: "sbp_testtoken" },
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      if (calls.length === 1) return new Response("[]", { status: 201 });
      return new Response(JSON.stringify([{
        email,
        enabled: true,
        note: "Friend beta",
        created_at: "2026-07-21T00:00:00Z",
      }]), { status: 201 });
    },
    log: () => {},
  });
  assert.equal(result.applied, true);
  assert.deepEqual(calls.map(({ url }) => url), [
    DATABASE_QUERY_URL,
    DATABASE_QUERY_URL,
    DATABASE_QUERY_URL,
  ]);
  assert.deepEqual(JSON.parse(calls[0].options.body).read_only, true);
  assert.deepEqual(JSON.parse(calls[1].options.body), {
    query: writeQueryFor("add"),
    parameters: [email, "Friend beta"],
    read_only: false,
  });
  assert.deepEqual(JSON.parse(calls[2].options.body).read_only, true);
  assert.doesNotMatch(calls[1].options.body, /sbp_testtoken/);
});

test("apply fails closed when the fresh row does not contain the requested note", async () => {
  const email = "friend@example.com";
  let callCount = 0;
  await assert.rejects(
    run({
      argv: ["add", email, "Expected note", "--apply"],
      env: { SUPABASE_ACCESS_TOKEN: "sbp_testtoken" },
      fetchImpl: async () => {
        callCount += 1;
        if (callCount === 1) return new Response("[]", { status: 201 });
        return new Response(JSON.stringify([{
          email,
          enabled: true,
          note: callCount === 2 ? "Expected note" : "Concurrent overwrite",
          created_at: "2026-07-21T00:00:00Z",
        }]), { status: 201 });
      },
      log: () => {},
    }),
    /note could not be verified/,
  );
});
