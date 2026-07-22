import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  generateCronMaterial,
  parseVercelEnvironment,
  validateCronRotation,
  validateProductionInventory,
  validatePublicProductionEnvironment,
} from "./verify-vercel-env.mjs";

function validPublicEnvironment() {
  return {
    NEXT_PUBLIC_SUPABASE_URL: "https://fjfashsjrajtdilxhcbn.supabase.co",
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: `sb_publishable_${"p".repeat(32)}`,
  };
}

function validInventory() {
  let updatedAt = 100;
  return {
    envs: [
      ...Object.keys(validPublicEnvironment()).map((key) => ({
        key,
        type: "encrypted",
        target: ["production"],
        configurationId: null,
        updatedAt: updatedAt++,
      })),
      ...["CRON_SECRET", "SHUDO_CLEANUP_SECRET", "SHUDO_WEEKLY_SECRET"].map((key) => ({
        key,
        type: "sensitive",
        target: ["production"],
        configurationId: null,
        updatedAt: updatedAt++,
      })),
    ],
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

test("readable production validation pins the Supabase project and publishable key", () => {
  const env = validPublicEnvironment();
  assert.equal(validatePublicProductionEnvironment(env), true);
  assert.throws(
    () => validatePublicProductionEnvironment({ ...env, NEXT_PUBLIC_SUPABASE_URL: "https://wrong.test" }),
    /wrong Supabase project/,
  );
  assert.throws(
    () => validatePublicProductionEnvironment({ ...env, NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "short" }),
    /publishable key/,
  );
});

test("production inventory requires exact encrypted and sensitive variable types", () => {
  const inventory = validInventory();
  assert.equal(validateProductionInventory(inventory), true);
  assert.throws(
    () => validateProductionInventory({
      envs: inventory.envs.filter(({ key }) => key !== "SHUDO_WEEKLY_SECRET"),
    }),
    /SHUDO_WEEKLY_SECRET/,
  );
  assert.throws(
    () => validateProductionInventory({
      envs: inventory.envs.map((entry) => (
        entry.key === "CRON_SECRET" ? { ...entry, type: "encrypted" } : entry
      )),
    }),
    /CRON_SECRET must be stored as a Vercel sensitive variable/,
  );
  assert.throws(
    () => validateProductionInventory({
      envs: inventory.envs.map((entry) => (
        entry.key === "CRON_SECRET" ? { ...entry, target: ["production", "preview"] } : entry
      )),
    }),
    /production only/,
  );
  assert.throws(
    () => validateProductionInventory({
      envs: inventory.envs.map((entry) => (
        entry.key === "CRON_SECRET" ? { ...entry, configurationId: "shared" } : entry
      )),
    }),
    /owned directly/,
  );
});

test("cron rotation requires a fresh production metadata timestamp", () => {
  const before = validInventory();
  const after = structuredClone(before);
  after.envs.find(({ key }) => key === "CRON_SECRET").updatedAt += 1;
  assert.equal(validateCronRotation(before, after), true);
  assert.throws(() => validateCronRotation(before, before), /did not advance/);
});

test("cron release material is random, owner-only, and exclusive", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "shudo-vercel-env-test."));
  const secretPath = path.join(directory, "cron.secret");
  const output = path.join(directory, "curl.conf");
  try {
    await generateCronMaterial(secretPath, output);
    assert.equal((await stat(secretPath)).mode & 0o777, 0o600);
    assert.equal((await stat(output)).mode & 0o777, 0o600);
    const secret = await readFile(secretPath, "utf8");
    assert.match(secret, /^[a-f0-9]{64}$/u);
    const config = await readFile(output, "utf8");
    assert.match(config, /Authorization: Bearer/);
    assert.match(config, new RegExp(secret));
    assert.doesNotMatch(config, /^location$/mu);
    await assert.rejects(generateCronMaterial(secretPath, output), /EEXIST/);

    await rm(secretPath);
    await assert.rejects(generateCronMaterial(secretPath, output), /EEXIST/);
    await assert.rejects(readFile(secretPath, "utf8"), /ENOENT/);
    assert.match(await readFile(output, "utf8"), /Authorization: Bearer/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
