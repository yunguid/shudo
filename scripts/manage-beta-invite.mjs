#!/usr/bin/env node

import { pathToFileURL } from "node:url";
import {
  loadAccessToken,
  PROJECT_REF,
} from "./configure-supabase-auth.mjs";

export const DATABASE_QUERY_URL =
  `https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`;

const USAGE = `Usage:
  manage-beta-invite.zsh list
  manage-beta-invite.zsh add EMAIL [NOTE] [--apply]
  manage-beta-invite.zsh enable EMAIL [--apply]
  manage-beta-invite.zsh disable EMAIL [--apply]
  manage-beta-invite.zsh remove EMAIL [--apply]

Mutations are dry-run by default. --apply is required to change production.
`;

const INSPECT_QUERY = `
select email, enabled, note, created_at
from public.beta_signup_allowlist
where email = lower($1::text)
order by email;
`.trim();

const LIST_QUERY = `
select email, enabled, note, created_at
from public.beta_signup_allowlist
order by email;
`.trim();

const WRITE_QUERIES = Object.freeze({
  add: `
insert into public.beta_signup_allowlist (email, enabled, note)
values (lower($1::text), true, nullif(btrim($2::text), ''))
on conflict (email) do update
set enabled = true,
    note = coalesce(excluded.note, public.beta_signup_allowlist.note)
returning email, enabled, note, created_at;
`.trim(),
  enable: `
update public.beta_signup_allowlist
set enabled = true
where email = lower($1::text)
returning email, enabled, note, created_at;
`.trim(),
  disable: `
update public.beta_signup_allowlist
set enabled = false
where email = lower($1::text)
returning email, enabled, note, created_at;
`.trim(),
  remove: `
delete from public.beta_signup_allowlist
where email = lower($1::text)
returning email, enabled, note, created_at;
`.trim(),
});

function fail(message, exitCode = 1) {
  const error = new Error(message);
  error.exitCode = exitCode;
  throw error;
}

export function normalizeEmail(raw) {
  const email = raw.trim().toLowerCase();
  if (
    email.length < 3 || email.length > 320 ||
    !/^[^@\s]+@[^@\s]+\.[^@\s]+$/u.test(email)
  ) {
    fail("EMAIL must be a valid address.", 64);
  }
  return email;
}

function normalizeNote(raw) {
  const note = raw?.trim() ?? "";
  if (note.length > 200) fail("NOTE must be 200 characters or fewer.", 64);
  if (/[\u0000\r\n]/u.test(note)) fail("NOTE must be a single line.", 64);
  return note;
}

export function parseArgs(argv) {
  const positional = [];
  let apply = false;
  let help = false;
  for (const arg of argv) {
    if (arg === "--apply") {
      if (apply) fail("Duplicate argument: --apply", 64);
      apply = true;
    } else if (arg === "--help" || arg === "-h") {
      help = true;
    } else if (arg.startsWith("-")) {
      fail(`Unknown argument: ${arg}`, 64);
    } else {
      positional.push(arg);
    }
  }

  if (help) {
    if (argv.length !== 1) fail("--help cannot be combined with other arguments.", 64);
    return { help: true };
  }
  const action = positional[0];
  if (action === "list") {
    if (positional.length !== 1 || apply) fail("list does not accept other arguments.", 64);
    return { help: false, action, apply: false, email: null, note: "" };
  }
  if (!["add", "enable", "disable", "remove"].includes(action)) {
    fail("Choose list, add, enable, disable, or remove.", 64);
  }
  if (positional.length < 2 || positional.length > (action === "add" ? 3 : 2)) {
    fail(`Invalid arguments for ${action}.`, 64);
  }
  return {
    help: false,
    action,
    apply,
    email: normalizeEmail(positional[1]),
    note: action === "add" ? normalizeNote(positional[2]) : "",
  };
}

export function writeQueryFor(action) {
  const query = WRITE_QUERIES[action];
  if (!query) fail("Unsupported beta invite action.", 64);
  return query;
}

function rowsFromResponse(value) {
  if (Array.isArray(value)) return value;
  if (value && Array.isArray(value.data)) return value.data;
  if (value && Array.isArray(value.result)) return value.result;
  fail("Supabase returned an unexpected database-query response.");
}

async function queryDatabase(fetchImpl, token, { query, parameters, write }) {
  const response = await fetchImpl(DATABASE_QUERY_URL, {
    method: "POST",
    redirect: "error",
    signal: AbortSignal.timeout(20_000),
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
      "Content-Type": "application/json",
      "User-Agent": "shudo-beta-invite/1",
    },
    body: JSON.stringify({ query, parameters, read_only: !write }),
  });
  if (!response.ok) {
    const requestId = response.headers.get("x-request-id");
    fail(
      `Supabase database query failed with HTTP ${response.status}` +
        (requestId ? ` (request ${requestId}).` : "."),
    );
  }
  let value;
  try {
    value = JSON.parse(await response.text());
  } catch {
    fail("Supabase returned an invalid database-query response.");
  }
  return rowsFromResponse(value);
}

function verifyApplied(action, email, rows, expectedNote = "") {
  const row = rows.find((candidate) => candidate?.email === email);
  if (action === "remove") {
    if (row) fail("Invite removal could not be verified.");
    return;
  }
  if (!row) fail("Invite change did not return the requested email.");
  const expectedEnabled = action !== "disable";
  if (row.enabled !== expectedEnabled) fail("Invite enabled state could not be verified.");
  if (action === "add" && expectedNote.length > 0 && row.note !== expectedNote) {
    fail("Invite note could not be verified.");
  }
}

export async function run({ argv, env, fetchImpl = globalThis.fetch, log = console.log }) {
  const options = parseArgs(argv);
  if (options.help) {
    log(USAGE.trimEnd());
    return { help: true };
  }
  if (typeof fetchImpl !== "function") fail("A fetch implementation is required.");
  const token = await loadAccessToken(env);

  if (options.action === "list") {
    const rows = await queryDatabase(fetchImpl, token, {
      query: LIST_QUERY,
      parameters: [],
      write: false,
    });
    log(JSON.stringify(rows, null, 2));
    return { action: "list", rows };
  }

  const before = await queryDatabase(fetchImpl, token, {
    query: INSPECT_QUERY,
    parameters: [options.email],
    write: false,
  });
  log(`Shudo beta invite: ${options.email}`);
  log(`Mode: ${options.apply ? "apply" : "dry-run"}`);
  log(`Action: ${options.action}`);
  log(`Current: ${before.length === 0 ? "not invited" : before[0].enabled ? "enabled" : "disabled"}`);
  if (!options.apply) {
    log("Dry run complete. Re-run with --apply to change production.");
    return { applied: false, before, options };
  }

  const parameters = options.action === "add"
    ? [options.email, options.note]
    : [options.email];
  const changed = await queryDatabase(fetchImpl, token, {
    query: writeQueryFor(options.action),
    parameters,
    write: true,
  });
  if (["enable", "disable", "remove"].includes(options.action) && changed.length === 0) {
    fail("That email is not currently in the beta allowlist.");
  }

  const after = await queryDatabase(fetchImpl, token, {
    query: INSPECT_QUERY,
    parameters: [options.email],
    write: false,
  });
  verifyApplied(options.action, options.email, after, options.note);
  log(`Verified: ${options.action} ${options.email}`);
  return { applied: true, before, after, options };
}

async function main() {
  const env = { ...process.env };
  delete process.env.SUPABASE_ACCESS_TOKEN;
  await run({ argv: process.argv.slice(2), env });
}

const invokedPath = process.argv[1] ? pathToFileURL(process.argv[1]).href : null;
if (invokedPath === import.meta.url) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : "Beta invite command failed.");
    process.exitCode = Number.isInteger(error?.exitCode) ? error.exitCode : 1;
  });
}
