#!/usr/bin/env node

import { chmod, readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const EXPECTED_SUPABASE_URL = "https://fjfashsjrajtdilxhcbn.supabase.co";
const REQUIRED = [
  "NEXT_PUBLIC_SUPABASE_URL",
  "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY",
  "CRON_SECRET",
  "SHUDO_CLEANUP_SECRET",
  "SHUDO_WEEKLY_SECRET",
];
const SECRET_NAMES = [
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

export function validateProductionEnvironment(values) {
  const missing = REQUIRED.filter((name) => !values[name]);
  if (missing.length > 0) {
    fail(`Missing production environment variables: ${missing.join(", ")}`);
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
  for (const name of SECRET_NAMES) {
    if (values[name].length < 32 || /[\u0000\r\n]/u.test(values[name])) {
      fail(`${name} must be at least 32 characters and one line.`);
    }
  }
  if (new Set(SECRET_NAMES.map((name) => values[name])).size !== SECRET_NAMES.length) {
    fail("Production maintenance secrets must all be different.");
  }
  return true;
}

function escapeCurlConfig(value) {
  return value.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
}

export async function verifyFile(inputPath) {
  const values = parseVercelEnvironment(await readFile(inputPath, "utf8"));
  validateProductionEnvironment(values);
  return values;
}

export async function writeCronCurlConfig(inputPath, outputPath) {
  const values = await verifyFile(inputPath);
  const secret = escapeCurlConfig(values.CRON_SECRET);
  await writeFile(
    outputPath,
    `silent\nshow-error\nmax-time = 120\nheader = "Authorization: Bearer ${secret}"\n`,
    { encoding: "utf8", flag: "wx", mode: 0o600 },
  );
  await chmod(outputPath, 0o600);
}

async function main() {
  const [command, inputPath, outputPath] = process.argv.slice(2);
  if (command === "verify" && inputPath && !outputPath) {
    await verifyFile(inputPath);
    console.log(`Verified production environment names: ${REQUIRED.join(", ")}`);
    return;
  }
  if (command === "write-cron-curl-config" && inputPath && outputPath) {
    await writeCronCurlConfig(inputPath, outputPath);
    console.log("Wrote owner-only cron smoke configuration.");
    return;
  }
  fail(
    "Usage: verify-vercel-env.mjs verify ENV_FILE | " +
      "write-cron-curl-config ENV_FILE OUTPUT_FILE",
    64,
  );
}

const invokedPath = process.argv[1] ? pathToFileURL(process.argv[1]).href : null;
if (invokedPath === import.meta.url) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : "Vercel environment verification failed.");
    process.exitCode = Number.isInteger(error?.exitCode) ? error.exitCode : 1;
  });
}
