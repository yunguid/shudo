import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = await readFile(new URL("./deploy-vercel-production.zsh", import.meta.url), "utf8");

test("dry run exits before cron credential generation or mutation", () => {
  const dryRunGuard = source.indexOf('if [[ "$apply_changes" != true ]]');
  const dryRunExit = source.indexOf("exit 0", dryRunGuard);
  const generation = source.indexOf("generate-cron-material");
  const mutation = source.indexOf("env update CRON_SECRET production");
  assert.ok(dryRunGuard >= 0 && dryRunExit > dryRunGuard);
  assert.ok(generation > dryRunExit);
  assert.ok(mutation > generation);
});

test("cron credential travels over stdin and never argv or audit artifacts", () => {
  assert.match(
    source,
    /env update CRON_SECRET production[\s\S]*--sensitive --yes[\s\S]*< "\$cron_secret_file"/u,
  );
  assert.doesNotMatch(source, /env update CRON_SECRET[\s\S]*--value/u);
  assert.match(source, /cron_secret_file="\$release_source\/\.cron-secret"/u);
  assert.match(source, /cron_curl_config="\$release_source\/\.cron-curl\.conf"/u);
  assert.doesNotMatch(source, /cron_(?:secret_file|curl_config)="\$audit_dir/u);
});

test("release verifies rotation before deploy and uses the generated smoke credential", () => {
  const mutation = source.indexOf("env update CRON_SECRET production");
  const rotationVerification = source.indexOf("verify-cron-rotation");
  const deployment = source.indexOf("deploy \\");
  const authorizedSmoke = source.indexOf('curl --config "$cron_curl_config"');
  assert.ok(mutation >= 0);
  assert.ok(rotationVerification > mutation);
  assert.ok(deployment > rotationVerification);
  assert.ok(authorizedSmoke > deployment);
});
