#!/usr/bin/env node

import { randomBytes } from "node:crypto";
import { realpathSync } from "node:fs";
import { chmod, readFile, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const EXPECTED_SUPABASE_URL = "https://fjfashsjrajtdilxhcbn.supabase.co";
const REQUIRED_PUBLIC = [
  "NEXT_PUBLIC_SUPABASE_URL",
  "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY",
];
const REQUIRED_SENSITIVE = [
  "CRON_SECRET",
  "SHUDO_CLEANUP_SECRET",
  "SHUDO_WEEKLY_SECRET",
];

function fail(message, exitCode = 1) {
  const error = new Error(message);
  error.exitCode = exitCode;
  throw error;
}

export function parseVercelEnvironment(text) {
  const values = {};
  for (const sourceLine of text.split(/\r?\n/u)) {
    const line = sourceLine.trim();
    if (!line || line.startsWith("#")) continue;
    const separator = line.indexOf("=");
    if (separator < 1) fail("Vercel environment file has an invalid line.");
    const name = line.slice(0, separator);
    if (!/^[A-Z_][A-Z0-9_]*$/u.test(name)) {
      fail("Vercel environment file has an invalid variable name.");
    }
    if (Object.hasOwn(values, name)) fail(`Duplicate Vercel environment variable: ${name}`);
    const rawValue = line.slice(separator + 1);
    let value;
    if (rawValue.startsWith('"')) {
      try {
        value = JSON.parse(rawValue);
      } catch {
        fail(`Vercel environment variable ${name} has invalid quoting.`);
      }
    } else {
      value = rawValue;
    }
    if (typeof value !== "string") fail(`Vercel environment variable ${name} is not text.`);
    values[name] = value;
  }
  return values;
}

export function validatePublicProductionEnvironment(values) {
  const missing = REQUIRED_PUBLIC.filter((name) => !values[name]);
  if (missing.length > 0) {
    fail(`Missing readable production environment variables: ${missing.join(", ")}`);
  }
  if (values.NEXT_PUBLIC_SUPABASE_URL !== EXPECTED_SUPABASE_URL) {
    fail("Production points at the wrong Supabase project.");
  }
  if (
    !values.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY.startsWith("sb_publishable_") ||
    values.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY.length < 32
  ) {
    fail("Production Supabase publishable key is invalid.");
  }
  return true;
}

export function validateProductionInventory(inventory) {
  if (!inventory || !Array.isArray(inventory.envs)) {
    fail("Vercel production environment inventory is invalid.");
  }

  const requiredTypes = new Map([
    ...REQUIRED_PUBLIC.map((name) => [name, "encrypted"]),
    ...REQUIRED_SENSITIVE.map((name) => [name, "sensitive"]),
  ]);
  for (const [name, expectedType] of requiredTypes) {
    const matches = inventory.envs.filter(
      (entry) => entry?.key === name,
    );
    if (matches.length !== 1) {
      fail(`Expected exactly one production environment variable named ${name}.`);
    }
    if (
      !Array.isArray(matches[0].target) ||
      matches[0].target.length !== 1 ||
      matches[0].target[0] !== "production"
    ) {
      fail(`${name} must target production only.`);
    }
    if (matches[0].type !== expectedType) {
      fail(`${name} must be stored as a Vercel ${expectedType} variable.`);
    }
    if (matches[0].configurationId !== null) {
      fail(`${name} must be owned directly by the pinned Vercel project.`);
    }
  }
  return true;
}

function cronInventoryEntry(inventory) {
  return inventory.envs.find((entry) => entry?.key === "CRON_SECRET");
}

export function validateCronRotation(before, after) {
  validateProductionInventory(before);
  validateProductionInventory(after);
  const beforeUpdatedAt = cronInventoryEntry(before)?.updatedAt;
  const afterUpdatedAt = cronInventoryEntry(after)?.updatedAt;
  if (!Number.isSafeInteger(beforeUpdatedAt) || !Number.isSafeInteger(afterUpdatedAt)) {
    fail("CRON_SECRET inventory is missing a valid update timestamp.");
  }
  if (afterUpdatedAt <= beforeUpdatedAt) {
    fail("CRON_SECRET update timestamp did not advance after rotation.");
  }
  return true;
}

function escapeCurlConfig(value) {
  return value.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
}

export async function verifyPublicFile(inputPath) {
  const values = parseVercelEnvironment(await readFile(inputPath, "utf8"));
  validatePublicProductionEnvironment(values);
  return values;
}

export async function verifyInventoryFile(inputPath) {
  const inventory = JSON.parse(await readFile(inputPath, "utf8"));
  validateProductionInventory(inventory);
  return inventory;
}

export async function generateCronMaterial(secretPath, curlConfigPath) {
  const secret = randomBytes(32).toString("hex");
  const curlSecret = escapeCurlConfig(secret);
  let secretCreated = false;
  let curlConfigCreated = false;
  try {
    await writeFile(secretPath, secret, { encoding: "utf8", flag: "wx", mode: 0o600 });
    secretCreated = true;
    await writeFile(
      curlConfigPath,
      `silent\nshow-error\nmax-time = 120\nheader = "Authorization: Bearer ${curlSecret}"\n`,
      { encoding: "utf8", flag: "wx", mode: 0o600 },
    );
    curlConfigCreated = true;
    await Promise.all([chmod(secretPath, 0o600), chmod(curlConfigPath, 0o600)]);
  } catch (error) {
    await Promise.allSettled([
      ...(secretCreated ? [rm(secretPath, { force: true })] : []),
      ...(curlConfigCreated ? [rm(curlConfigPath, { force: true })] : []),
    ]);
    throw error;
  }
}

async function main() {
  const [command, inputPath, outputPath] = process.argv.slice(2);
  if (command === "verify-public" && inputPath && !outputPath) {
    await verifyPublicFile(inputPath);
    console.log(`Verified readable production environment names: ${REQUIRED_PUBLIC.join(", ")}`);
    return;
  }
  if (command === "verify-inventory" && inputPath && !outputPath) {
    await verifyInventoryFile(inputPath);
    console.log(
      `Verified sensitive production environment names: ${REQUIRED_SENSITIVE.join(", ")}`,
    );
    return;
  }
  if (command === "verify-cron-rotation" && inputPath && outputPath) {
    const before = JSON.parse(await readFile(inputPath, "utf8"));
    const after = JSON.parse(await readFile(outputPath, "utf8"));
    validateCronRotation(before, after);
    console.log("Verified production cron credential rotation metadata.");
    return;
  }
  if (command === "generate-cron-material" && inputPath && outputPath) {
    await generateCronMaterial(inputPath, outputPath);
    console.log("Generated owner-only cron release material.");
    return;
  }
  fail(
    "Usage: verify-vercel-env.mjs verify-public ENV_FILE | " +
      "verify-inventory INVENTORY_FILE | " +
      "verify-cron-rotation BEFORE_INVENTORY AFTER_INVENTORY | " +
      "generate-cron-material SECRET_FILE CURL_CONFIG_FILE",
    64,
  );
}

const invokedPath = process.argv[1] ? realpathSync(process.argv[1]) : null;
const modulePath = realpathSync(fileURLToPath(import.meta.url));
if (invokedPath === modulePath) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : "Vercel environment verification failed.");
    process.exitCode = Number.isInteger(error?.exitCode) ? error.exitCode : 1;
  });
}
