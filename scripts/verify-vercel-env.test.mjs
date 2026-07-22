import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  parseVercelEnvironment,
  validateProductionEnvironment,
  writeCronCurlConfig,
} from "./verify-vercel-env.mjs";

function validEnvironment() {
  return {
    NEXT_PUBLIC_SUPABASE_URL: "https://fjfashsjrajtdilxhcbn.supabase.co",
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: `sb_publishable_${"p".repeat(32)}`,
    CRON_SECRET: `cron-${"a".repeat(40)}`,
    SHUDO_CLEANUP_SECRET: `cleanup-${"b".repeat(40)}`,
    SHUDO_WEEKLY_SECRET: `weekly-${"c".repeat(40)}`,
  };
}

test("Vercel quoted environment parser handles equals signs without evaluation", () => {
  const parsed = parseVercelEnvironment([
    'CRON_SECRET="abc=def"',
    'NEXT_PUBLIC_SUPABASE_URL="https://example.test"',
  ].join("\n"));
  assert.equal(parsed.CRON_SECRET, "abc=def");
  assert.equal(parsed.NEXT_PUBLIC_SUPABASE_URL, "https://example.test");
  assert.throws(() => parseVercelEnvironment('CRON_SECRET="unterminated'), /quoting/);
});

test("production validation pins project and distinct high-entropy secrets", () => {
  const env = validEnvironment();
  assert.equal(validateProductionEnvironment(env), true);
  assert.throws(
    () => validateProductionEnvironment({ ...env, SHUDO_WEEKLY_SECRET: env.CRON_SECRET }),
    /different/,
  );
  assert.throws(
    () => validateProductionEnvironment({ ...env, CRON_SECRET: "short" }),
    /at least 32/,
  );
  assert.throws(
    () => validateProductionEnvironment({ ...env, NEXT_PUBLIC_SUPABASE_URL: "https://wrong.test" }),
    /wrong Supabase project/,
  );
});

test("cron curl configuration is owner-only and never printed", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "shudo-vercel-env-test."));
  const input = path.join(directory, "production.env");
  const output = path.join(directory, "curl.conf");
  const values = validEnvironment();
  await writeFile(
    input,
    `${Object.entries(values).map(([name, value]) => `${name}=${JSON.stringify(value)}`).join("\n")}\n`,
    { mode: 0o600 },
  );
  try {
    await writeCronCurlConfig(input, output);
    assert.equal((await stat(output)).mode & 0o777, 0o600);
    const config = await readFile(output, "utf8");
    assert.match(config, /Authorization: Bearer/);
    assert.match(config, new RegExp(values.CRON_SECRET));
    assert.doesNotMatch(config, /^location$/mu);
    await assert.rejects(writeCronCurlConfig(input, output), /EEXIST/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
