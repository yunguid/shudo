#!/usr/bin/env node

import { chmod, lstat, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";

process.umask(0o077);

export const PROJECT_REF = "fjfashsjrajtdilxhcbn";
export const AUTH_CONFIG_URL =
  `https://api.supabase.com/v1/projects/${PROJECT_REF}/config/auth`;

export const REDIRECT_ALLOW_LIST = [
  "http://127.0.0.1:3000/auth/callback",
  "http://127.0.0.1:3000/reset-password",
  "https://shudo.yng.sh/auth/callback",
  "https://shudo.yng.sh/auth/confirm",
  "https://shudo.yng.sh/reset-password",
  "https://shudo.vercel.app/auth/callback",
  "https://shudo.vercel.app/auth/confirm",
  "https://shudo.vercel.app/reset-password",
  "shudo://auth/callback",
].join(",");

const CORE_PATCH = Object.freeze({
  site_url: "https://shudo.yng.sh",
  uri_allow_list: REDIRECT_ALLOW_LIST,
  disable_signup: false,
  external_email_enabled: true,
  mailer_autoconfirm: false,
  mailer_secure_email_change_enabled: true,
  password_min_length: 10,
  hook_before_user_created_enabled: true,
  hook_before_user_created_uri:
    "pg-functions://postgres/public/hook_restrict_shudo_signup",
});

const SECRET_FIELDS = new Set(["external_google_secret", "smtp_pass"]);
const SNAPSHOT_FIELDS = [
  ...Object.keys(CORE_PATCH),
  "external_google_enabled",
  "external_google_client_id",
  "smtp_admin_email",
  "smtp_host",
  "smtp_port",
  "smtp_user",
  "smtp_sender_name",
];

const GOOGLE_ENV = [
  "SHUDO_GOOGLE_CLIENT_ID",
  "SHUDO_GOOGLE_CLIENT_SECRET",
];

const SMTP_ENV = [
  "SHUDO_SMTP_ADMIN_EMAIL",
  "SHUDO_SMTP_HOST",
  "SHUDO_SMTP_PORT",
  "SHUDO_SMTP_USER",
  "SHUDO_SMTP_PASS",
  "SHUDO_SMTP_SENDER_NAME",
];

const USAGE = `Usage: configure-supabase-auth.zsh [--apply] [--google] [--smtp]

Defaults to a read-only dry run. --apply is the only mode that PATCHes Auth.

  --google  Also enable Google using SHUDO_GOOGLE_CLIENT_ID and
            SHUDO_GOOGLE_CLIENT_SECRET.
  --smtp    Also configure SMTP using SHUDO_SMTP_ADMIN_EMAIL,
            SHUDO_SMTP_HOST, SHUDO_SMTP_PORT, SHUDO_SMTP_USER,
            SHUDO_SMTP_PASS, and SHUDO_SMTP_SENDER_NAME.
`;

function fail(message, exitCode = 1) {
  const error = new Error(message);
  error.exitCode = exitCode;
  throw error;
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireEnv(env, names) {
  const missing = names.filter(
    (name) => typeof env[name] !== "string" || env[name].length === 0,
  );
  if (missing.length > 0) {
    fail(`Missing required environment variables: ${missing.join(", ")}`);
  }
}

function rejectControlCharacters(name, value) {
  if (/[\u0000\r\n]/u.test(value)) {
    fail(`${name} must not contain control characters.`);
  }
}

export function parseArgs(argv) {
  const options = { apply: false, google: false, smtp: false, help: false };
  const seen = new Set();

  for (const arg of argv) {
    const key = {
      "--apply": "apply",
      "--google": "google",
      "--smtp": "smtp",
      "--help": "help",
      "-h": "help",
    }[arg];
    if (!key) fail(`Unknown argument: ${arg}`, 64);
    if (seen.has(key)) fail(`Duplicate argument: ${arg}`, 64);
    seen.add(key);
    options[key] = true;
  }

  if (options.help && seen.size > 1) {
    fail("--help cannot be combined with other arguments.", 64);
  }
  return options;
}

export function buildPatch(options, env) {
  const patch = { ...CORE_PATCH };

  if (options.google) {
    requireEnv(env, GOOGLE_ENV);
    for (const name of GOOGLE_ENV) rejectControlCharacters(name, env[name]);
    patch.external_google_enabled = true;
    patch.external_google_client_id = env.SHUDO_GOOGLE_CLIENT_ID;
    patch.external_google_secret = env.SHUDO_GOOGLE_CLIENT_SECRET;
  }

  if (options.smtp) {
    requireEnv(env, SMTP_ENV);
    for (const name of SMTP_ENV) rejectControlCharacters(name, env[name]);

    const smtpPort = Number(env.SHUDO_SMTP_PORT);
    if (!Number.isInteger(smtpPort) || smtpPort < 1 || smtpPort > 65535) {
      fail("SHUDO_SMTP_PORT must be an integer from 1 through 65535.");
    }
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/u.test(env.SHUDO_SMTP_ADMIN_EMAIL)) {
      fail("SHUDO_SMTP_ADMIN_EMAIL must be an email address.");
    }
    if (/[:/\s]/u.test(env.SHUDO_SMTP_HOST)) {
      fail("SHUDO_SMTP_HOST must be a hostname without a scheme or port.");
    }

    Object.assign(patch, {
      smtp_admin_email: env.SHUDO_SMTP_ADMIN_EMAIL,
      smtp_host: env.SHUDO_SMTP_HOST,
      smtp_port: smtpPort,
      smtp_user: env.SHUDO_SMTP_USER,
      smtp_pass: env.SHUDO_SMTP_PASS,
      smtp_sender_name: env.SHUDO_SMTP_SENDER_NAME,
    });
  }

  return patch;
}

export function redactPatch(patch) {
  return Object.fromEntries(
    Object.entries(patch).map(([key, value]) => [
      key,
      SECRET_FIELDS.has(key) ? "[redacted]" : value,
    ]),
  );
}

export function createPlan(current, patch) {
  const plan = {};
  for (const [key, desired] of Object.entries(patch)) {
    if (SECRET_FIELDS.has(key)) {
      plan[key] = { from: "[redacted]", to: "[redacted]" };
    } else if (!Object.is(current[key], desired)) {
      plan[key] = { from: current[key] ?? null, to: desired };
    }
  }
  return plan;
}

export function nonSecretSnapshot(config) {
  if (!isPlainObject(config)) fail("Auth config response was not an object.");
  return Object.fromEntries(
    SNAPSHOT_FIELDS.filter((key) => Object.hasOwn(config, key)).map((key) => [
      key,
      config[key],
    ]),
  );
}

export function verifyOwnedNonSecretFields(actual, patch) {
  const mismatches = [];
  for (const [key, desired] of Object.entries(patch)) {
    if (!SECRET_FIELDS.has(key) && !Object.is(actual[key], desired)) {
      mismatches.push(key);
    }
  }
  if (mismatches.length > 0) {
    fail(
      `Auth verification failed for owned fields: ${mismatches.join(", ")}`,
    );
  }
}

function validateToken(token, source) {
  if (typeof token !== "string" || token.length === 0) {
    fail(`${source} is empty.`);
  }
  if (/\s/u.test(token)) {
    fail(`${source} must contain exactly one token without whitespace.`);
  }
  return token;
}

export async function loadAccessToken(env) {
  if (typeof env.SUPABASE_ACCESS_TOKEN === "string") {
    return validateToken(env.SUPABASE_ACCESS_TOKEN, "SUPABASE_ACCESS_TOKEN");
  }

  const tokenHome = env.SUPABASE_HOME ||
    (env.HOME ? path.join(env.HOME, ".supabase") : null);
  if (!tokenHome) {
    fail("HOME or SUPABASE_HOME is required to locate the access token.");
  }
  const tokenPath = path.resolve(tokenHome, "access-token");
  let stats;
  try {
    stats = await lstat(tokenPath);
  } catch (error) {
    if (error?.code === "ENOENT") {
      fail(
        "No non-Keychain Supabase token is available. Run scripts/login-supabase-no-keyring.zsh first.",
      );
    }
    throw error;
  }

  if (!stats.isFile()) fail("Refusing a non-regular Supabase token file.");
  if ((stats.mode & 0o777) !== 0o600) {
    fail("Refusing a Supabase token file whose mode is not 600.");
  }
  if (typeof process.getuid === "function" && stats.uid !== process.getuid()) {
    fail("Refusing a Supabase token file owned by another user.");
  }

  return validateToken(await readFile(tokenPath, "utf8"), "Supabase token file");
}

async function requestJson(fetchImpl, token, method, body) {
  const response = await fetchImpl(AUTH_CONFIG_URL, {
    method,
    redirect: "error",
    signal: AbortSignal.timeout(20_000),
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
      ...(body ? { "Content-Type": "application/json" } : {}),
      "User-Agent": "shudo-auth-config/1",
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });

  if (!response.ok) {
    const requestId = response.headers.get("x-request-id");
    fail(
      `Supabase Management API ${method} failed with HTTP ${response.status}` +
        (requestId ? ` (request ${requestId})` : "."),
    );
  }
  const responseText = await response.text();
  if (responseText.length === 0 && method === "PATCH") return {};

  let config;
  try {
    config = JSON.parse(responseText);
  } catch {
    fail("Supabase returned an invalid Auth config response.");
  }
  if (!isPlainObject(config)) fail("Supabase returned an invalid Auth config.");
  return config;
}

async function createSnapshotDirectory() {
  const directory = await mkdtemp(path.join(os.tmpdir(), "shudo-auth-config."));
  await chmod(directory, 0o700);
  return directory;
}

async function writeSnapshot(directory, name, config) {
  const destination = path.join(directory, name);
  const snapshot = {
    project_ref: PROJECT_REF,
    auth: nonSecretSnapshot(config),
  };
  await writeFile(destination, `${JSON.stringify(snapshot, null, 2)}\n`, {
    encoding: "utf8",
    flag: "wx",
    mode: 0o600,
  });
  await chmod(destination, 0o600);
}

export async function run({ argv, env, fetchImpl = globalThis.fetch, log = console.log }) {
  const options = parseArgs(argv);
  if (options.help) {
    log(USAGE.trimEnd());
    return { help: true };
  }
  if (typeof fetchImpl !== "function") fail("A fetch implementation is required.");

  const patch = buildPatch(options, env);
  const token = await loadAccessToken(env);
  const snapshots = await createSnapshotDirectory();
  const before = await requestJson(fetchImpl, token, "GET");
  await writeSnapshot(snapshots, "before.json", before);
  await writeSnapshot(snapshots, "planned.json", { ...before, ...patch });

  const plan = createPlan(before, patch);
  log(`Supabase Auth project: ${PROJECT_REF}`);
  log(`Mode: ${options.apply ? "apply" : "dry-run"}`);
  log(`Non-secret snapshots: ${snapshots}`);
  log("Owned-field plan:");
  log(JSON.stringify(plan, null, 2));

  if (!options.apply) {
    log("Dry run complete. No Auth configuration was changed.");
    return { applied: false, plan, snapshots };
  }

  if (Object.keys(plan).length > 0) {
    await requestJson(fetchImpl, token, "PATCH", patch);
  }
  const after = await requestJson(fetchImpl, token, "GET");
  await writeSnapshot(snapshots, "after.json", after);
  verifyOwnedNonSecretFields(after, patch);
  log("Auth configuration applied and all owned non-secret fields verified.");
  return { applied: true, plan: redactPatch(patch), snapshots };
}

async function main() {
  const env = { ...process.env };
  for (const name of [
    "SUPABASE_ACCESS_TOKEN",
    "SHUDO_GOOGLE_CLIENT_SECRET",
    "SHUDO_SMTP_PASS",
  ]) {
    delete process.env[name];
  }
  await run({ argv: process.argv.slice(2), env });
}

const invokedPath = process.argv[1] ? pathToFileURL(process.argv[1]).href : null;
if (invokedPath === import.meta.url) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : "Auth configuration failed.");
    process.exitCode = Number.isInteger(error?.exitCode) ? error.exitCode : 1;
  });
}
