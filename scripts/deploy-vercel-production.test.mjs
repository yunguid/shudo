import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const source = await readFile(new URL("./deploy-vercel-production.zsh", import.meta.url), "utf8");
const verificationSource = await readFile(new URL("./verify-release.zsh", import.meta.url), "utf8");

test("immutable release runs npm and Vercel from the shudo-web snapshot", () => {
  const webCwd = source.indexOf('cd "$release_source/shudo-web"');
  const npmCi = source.indexOf("npm ci", webCwd);
  const pull = source.indexOf("vercel@$vercel_version pull", npmCi);
  const rootCheck = source.indexOf(".settings.rootDirectory == null", pull);
  const build = source.indexOf("vercel@$vercel_version build", rootCheck);
  const deploy = source.indexOf("vercel@$vercel_version deploy", build);

  assert.ok(webCwd >= 0);
  assert.ok(npmCi > webCwd);
  assert.ok(pull > npmCi);
  assert.ok(rootCheck > pull);
  assert.ok(build > rootCheck);
  assert.ok(deploy > build);
  assert.doesNotMatch(source, /settings: \{rootDirectory:/u);
  assert.match(source, /releases run from shudo-web/u);
  assert.match(source, /\.\.\/scripts\/verify-vercel-env\.mjs/u);
});

test("release verification uses a disposable shudo-web Vercel snapshot", () => {
  const webCwd = verificationSource.indexOf('cd "$shudo_web_root"');
  const npmCi = verificationSource.indexOf("npm ci", webCwd);
  const npmAudit = verificationSource.indexOf("npm audit", npmCi);
  const snapshot = verificationSource.indexOf("shudo_vercel_snapshot=", npmAudit);
  const snapshotCwd = verificationSource.indexOf(
    'cd "$shudo_vercel_snapshot/shudo-web"',
    snapshot,
  );
  const pull = verificationSource.indexOf("vercel@$shudo_vercel_version pull", snapshotCwd);
  const rootCheck = verificationSource.indexOf(".settings.rootDirectory == null", pull);
  const build = verificationSource.indexOf("vercel@$shudo_vercel_version build", rootCheck);
  const dryDeploy = verificationSource.indexOf("deploy --dry --format=json", build);

  assert.ok(webCwd >= 0);
  assert.ok(npmCi > webCwd);
  assert.ok(npmAudit > npmCi);
  assert.ok(snapshot > npmAudit);
  assert.ok(snapshotCwd > snapshot);
  assert.ok(pull > snapshotCwd);
  assert.ok(rootCheck > pull);
  assert.ok(build > rootCheck);
  assert.ok(dryDeploy > build);
  assert.match(
    verificationSource,
    /git ls-files --cached --others --exclude-standard -z -- shudo-web/u,
  );
  assert.doesNotMatch(verificationSource, /settings: \{rootDirectory:/u);
});

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
