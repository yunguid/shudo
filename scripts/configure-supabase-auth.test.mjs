import assert from "node:assert/strict";
import {
  chmod,
  mkdir,
  mkdtemp,
  open,
  readFile,
  rename,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import {
  AUTH_CONFIG_URL,
  PROJECT_REF,
  REDIRECT_ALLOW_LIST,
  buildPatch,
  createPlan,
  loadCredentialEnvironment,
  loadAccessToken,
  nonSecretSnapshot,
  parseArgs,
  readOwnerOnlyCredentialFile,
  redactPatch,
  run,
  stageAccessToken,
  verifyOwnedNonSecretFields,
} from "./configure-supabase-auth.mjs";

test("production project and endpoint are hard-pinned", () => {
  assert.equal(PROJECT_REF, "fjfashsjrajtdilxhcbn");
  assert.equal(
    AUTH_CONFIG_URL,
    "https://api.supabase.com/v1/projects/fjfashsjrajtdilxhcbn/config/auth",
  );
});

test("arguments are dry-run by default and fail closed", () => {
  assert.deepEqual(parseArgs([]), {
    apply: false,
    google: false,
    smtp: false,
    help: false,
  });
  assert.deepEqual(parseArgs(["--smtp", "--apply", "--google"]), {
    apply: true,
    google: true,
    smtp: true,
    help: false,
  });
  assert.throws(() => parseArgs(["--apply", "--apply"]), /Duplicate/);
  assert.throws(() => parseArgs(["--project-ref=other"]), /Unknown/);
  assert.throws(() => parseArgs(["--help", "--apply"]), /cannot be combined/);
});

test("core plan owns the exact lean Auth fields", () => {
  const patch = buildPatch(parseArgs([]), {});
  assert.deepEqual(patch, {
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
  assert.equal(REDIRECT_ALLOW_LIST.split(",").length, 9);
});

test("Google is opt-in, requires both inputs, and redacts its secret", () => {
  const options = parseArgs(["--google"]);
  assert.throws(() => buildPatch(options, {}), /SHUDO_GOOGLE_CLIENT_ID/);

  const secret = "google-secret-never-print";
  const patch = buildPatch(options, {
    SHUDO_GOOGLE_CLIENT_ID: "client.apps.googleusercontent.com",
    SHUDO_GOOGLE_CLIENT_SECRET: secret,
  });
  assert.equal(patch.external_google_enabled, true);
  assert.equal(patch.external_google_secret, secret);
  assert.equal(redactPatch(patch).external_google_secret, "[redacted]");
  assert.doesNotMatch(JSON.stringify(redactPatch(patch)), new RegExp(secret));

  const planText = JSON.stringify(createPlan({}, patch));
  assert.doesNotMatch(planText, new RegExp(secret));
});

test("SMTP is opt-in, validated, and redacts its password", () => {
  const options = parseArgs(["--smtp"]);
  const env = {
    SHUDO_SMTP_ADMIN_EMAIL: "hello@yng.sh",
    SHUDO_SMTP_HOST: "smtp.example.com",
    SHUDO_SMTP_PORT: "587",
    SHUDO_SMTP_USER: "shudo",
    SHUDO_SMTP_PASS: "smtp-secret-never-print",
    SHUDO_SMTP_SENDER_NAME: "Shudo",
  };
  const patch = buildPatch(options, env);
  assert.equal(patch.smtp_port, 587);
  assert.equal(redactPatch(patch).smtp_pass, "[redacted]");
  assert.doesNotMatch(JSON.stringify(redactPatch(patch)), /smtp-secret-never-print/);

  assert.throws(
    () => buildPatch(options, { ...env, SHUDO_SMTP_PORT: "0" }),
    /1 through 65535/,
  );
  assert.throws(
    () => buildPatch(options, { ...env, SHUDO_SMTP_HOST: "https:\/\/smtp.test" }),
    /hostname/,
  );
});

test("snapshots allowlist non-secret fields", () => {
  const snapshot = nonSecretSnapshot({
    site_url: "https://shudo.yng.sh",
    external_google_secret: "do-not-store",
    smtp_pass: "do-not-store-either",
    jwt_secret: "also-do-not-store",
    unrelated_field: "not-owned",
  });
  assert.deepEqual(snapshot, { site_url: "https://shudo.yng.sh" });
});

test("verification checks every owned non-secret field but not write-only secrets", () => {
  const patch = {
    site_url: "https://shudo.yng.sh",
    external_google_secret: "new-secret",
  };
  assert.doesNotThrow(() =>
    verifyOwnedNonSecretFields(
      { site_url: "https://shudo.yng.sh", external_google_secret: "masked" },
      patch,
    ));
  assert.throws(
    () => verifyOwnedNonSecretFields({ site_url: "https://wrong.test" }, patch),
    /site_url/,
  );
});

test("token loader accepts only a regular owner-only non-symlink file", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "shudo-auth-token-test."));
  const tokenPath = path.join(directory, "access-token");
  const realTokenPath = path.join(directory, "real-token");
  try {
    await writeFile(tokenPath, "sbp_testtoken", { mode: 0o600 });
    await chmod(tokenPath, 0o600);
    assert.equal(
      await loadAccessToken({ SUPABASE_HOME: directory }),
      "sbp_testtoken",
    );

    await chmod(tokenPath, 0o644);
    await assert.rejects(
      loadAccessToken({ SUPABASE_HOME: directory }),
      /mode 600/,
    );

    await rm(tokenPath);
    await writeFile(realTokenPath, "sbp_symlink_target", { mode: 0o600 });
    await symlink(realTokenPath, tokenPath);
    await assert.rejects(
      loadAccessToken({ SUPABASE_HOME: directory }),
      /symbolic link|regular file/,
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("credential reader validates the opened descriptor and resists path replacement", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "shudo-auth-fd-test."));
  const tokenPath = path.join(directory, "access-token");
  const openedPath = path.join(directory, "opened-token");
  try {
    await writeFile(tokenPath, "sbp_original", { mode: 0o600 });
    const value = await readOwnerOnlyCredentialFile(tokenPath, {
      label: "Test token",
      openImpl: async (inputPath, flags) => {
        const handle = await open(inputPath, flags);
        await rename(inputPath, openedPath);
        await writeFile(inputPath, "sbp_replacement", { mode: 0o600 });
        return handle;
      },
    });
    assert.equal(value, "sbp_original");

    let readAttempted = false;
    let closed = false;
    const wrongOwnerHandle = {
      stat: async () => ({
        isFile: () => true,
        mode: 0o100600,
        uid: (typeof process.getuid === "function" ? process.getuid() : 0) + 1,
        size: 12,
      }),
      readFile: async () => {
        readAttempted = true;
        return "must-not-read";
      },
      close: async () => {
        closed = true;
      },
    };
    await assert.rejects(
      readOwnerOnlyCredentialFile(tokenPath, {
        label: "Test token",
        openImpl: async () => wrongOwnerHandle,
      }),
      /owned by another user/,
    );
    assert.equal(readAttempted, false);
    assert.equal(closed, true);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("token staging creates a new owner-only copy", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "shudo-auth-stage-test."));
  const sourceDirectory = path.join(directory, "source");
  const destination = path.join(directory, "staged-token");
  await mkdir(sourceDirectory, { mode: 0o700 });
  const source = path.join(sourceDirectory, "access-token");
  try {
    await writeFile(source, "sbp_staged", { mode: 0o600 });
    await stageAccessToken({ SUPABASE_HOME: sourceDirectory }, destination);
    assert.equal(await readFile(destination, "utf8"), "sbp_staged");
    assert.equal((await stat(destination)).mode & 0o777, 0o600);
    await assert.rejects(
      stageAccessToken({ SUPABASE_HOME: sourceDirectory }, destination),
      /EEXIST/,
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("credential files carry secrets without putting them in process arguments", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "shudo-auth-input-test."));
  const secret = "not-visible-in-argv";
  const secretPath = path.join(directory, "SHUDO_GOOGLE_CLIENT_SECRET");
  await writeFile(secretPath, secret, { mode: 0o600 });
  await chmod(secretPath, 0o600);

  try {
    const env = await loadCredentialEnvironment({
      SHUDO_AUTH_INPUT_DIRECTORY: directory,
      HOME: "/safe/home",
    });
    assert.equal(env.SHUDO_GOOGLE_CLIENT_SECRET, secret);
    assert.equal(env.HOME, "/safe/home");
    assert.equal(Object.hasOwn(env, "SHUDO_AUTH_INPUT_DIRECTORY"), false);

    await chmod(secretPath, 0o644);
    await assert.rejects(
      loadCredentialEnvironment({ SHUDO_AUTH_INPUT_DIRECTORY: directory }),
      /mode 600/,
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("dry-run performs one GET, redacts output, and writes only 600 snapshots", async () => {
  const googleSecret = "dry-run-google-secret";
  const logs = [];
  const calls = [];
  const result = await run({
    argv: ["--google"],
    env: {
      SUPABASE_ACCESS_TOKEN: "sbp_testtoken",
      SHUDO_GOOGLE_CLIENT_ID: "client.apps.googleusercontent.com",
      SHUDO_GOOGLE_CLIENT_SECRET: googleSecret,
    },
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      return new Response(JSON.stringify({
        site_url: "https://old.test",
        external_google_enabled: false,
        external_google_secret: "existing-server-secret",
      }), { status: 200, headers: { "content-type": "application/json" } });
    },
    log: (message) => logs.push(String(message)),
  });

  try {
    assert.equal(result.applied, false);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, AUTH_CONFIG_URL);
    assert.equal(calls[0].options.method, "GET");
    assert.equal(calls[0].options.body, undefined);
    assert.equal(calls[0].options.headers.Authorization, "Bearer sbp_testtoken");
    assert.doesNotMatch(logs.join("\n"), new RegExp(googleSecret));
    assert.doesNotMatch(logs.join("\n"), /existing-server-secret/);

    assert.equal((await stat(result.snapshots)).mode & 0o777, 0o700);
    for (const name of ["before.json", "planned.json"]) {
      const snapshotPath = path.join(result.snapshots, name);
      assert.equal((await stat(snapshotPath)).mode & 0o777, 0o600);
      const snapshotText = await readFile(snapshotPath, "utf8");
      assert.doesNotMatch(snapshotText, /secret/);
    }
  } finally {
    await rm(result.snapshots, { recursive: true, force: true });
  }
});

test("apply PATCHes only owned fields and verifies with a fresh GET", async () => {
  const desired = buildPatch(parseArgs([]), {});
  const calls = [];
  const result = await run({
    argv: ["--apply"],
    env: { SUPABASE_ACCESS_TOKEN: "sbp_testtoken" },
    fetchImpl: async (url, options) => {
      calls.push({ url, options });
      if (calls.length === 1) {
        return new Response(JSON.stringify({
          ...desired,
          disable_signup: true,
          unrelated_remote_field: "preserve-me",
        }), { status: 200 });
      }
      if (calls.length === 2) return new Response(null, { status: 204 });
      return new Response(JSON.stringify({
        ...desired,
        unrelated_remote_field: "preserve-me",
      }), { status: 200 });
    },
    log: () => {},
  });

  try {
    assert.equal(result.applied, true);
    assert.deepEqual(calls.map(({ options }) => options.method), [
      "GET",
      "PATCH",
      "GET",
    ]);
    assert.deepEqual(JSON.parse(calls[1].options.body), desired);
    assert.equal(
      Object.hasOwn(JSON.parse(calls[1].options.body), "unrelated_remote_field"),
      false,
    );
    assert.equal(
      (await stat(path.join(result.snapshots, "after.json"))).mode & 0o777,
      0o600,
    );
  } finally {
    await rm(result.snapshots, { recursive: true, force: true });
  }
});
