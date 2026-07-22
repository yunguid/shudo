#!/bin/zsh -f

set -euo pipefail
umask 077

repo_root="${0:A:h:h}"
node_dir="/Users/luke/.nvm/versions/node/v24.16.0/bin"
node_cli="$node_dir/node"
node_cli_sha256="1ee75375e33b94fc34b3b19aede049e11dae90efb63b374dc96d6bdace70c4b8"
vercel_version="56.4.1"
team_slug="ekuls-projects"
project_id="prj_TYVMUzLGdkP8RkaL27wRdwX9Br4I"
org_id="team_T0jbOZn2SkfEsSDj44ILJ57y"
apply_changes=false

case "${1:-}" in
  "") ;;
  --apply) apply_changes=true ;;
  *)
    print -u2 "Usage: ${0:t} [--apply]"
    exit 64
    ;;
esac

if [[ ! -x "$node_cli" ]]; then
  print -u2 "Node 24.16.0 not found at $node_cli"
  exit 1
fi
actual_node_sha256="$(/usr/bin/shasum -a 256 "$node_cli")"
actual_node_sha256="${actual_node_sha256%% *}"
if [[ "$actual_node_sha256" != "$node_cli_sha256" ]]; then
  print -u2 "Node integrity check failed."
  exit 1
fi
export PATH="$node_dir:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset NODE_OPTIONS

if [[ "$(node --version)" != "v24.16.0" ]]; then
  print -u2 "Node 24.16.0 is required."
  exit 1
fi
if [[ "$(npx --offline --yes vercel@$vercel_version --version 2>/dev/null)" != "$vercel_version" ]]; then
  print -u2 "Vercel CLI $vercel_version is required in the local npm cache."
  exit 1
fi

cd "$repo_root"
release_paths=(
  scripts/deploy-vercel-production.zsh
  scripts/verify-vercel-env.mjs
  shudo-web
)
release_tree_status="$(git status --porcelain --untracked-files=all -- $release_paths)"
if [[ -n "$release_tree_status" ]]; then
  print -u2 "Refusing mutable or uncommitted Vercel release inputs:"
  print -u2 -r -- "$release_tree_status"
  exit 1
fi

release_commit="$(git rev-parse --verify HEAD^{commit})"
temporary_root="${TMPDIR:-/tmp}"
temporary_root="${temporary_root%/}"
release_tmp="$(mktemp -d "$temporary_root/shudo-vercel-release.XXXXXX")"
release_source="$release_tmp/source"
audit_dir="$release_tmp/audit"
mkdir -p "$release_source" "$audit_dir"

cleanup_release_source() {
  case "$release_source" in
    "$temporary_root"/shudo-vercel-release.*/source)
      /bin/rm -rf -- "$release_source"
      ;;
    *)
      print -u2 "Refusing to remove unexpected Vercel release source."
      ;;
  esac
}
trap cleanup_release_source EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

git archive --format=tar "$release_commit" -- \
  shudo-web scripts/verify-vercel-env.mjs | tar -xf - -C "$release_source"
if [[ -n "$(find "$release_source" -type l -print -quit)" ]]; then
  print -u2 "Refusing symlinks in the immutable Vercel source snapshot."
  exit 1
fi
(
  cd "$release_source"
  find shudo-web scripts/verify-vercel-env.mjs -type f -print0 |
    sort -z |
    xargs -0 shasum -a 256
) > "$audit_dir/source-manifest.sha256"
print -r -- "$release_commit" > "$audit_dir/git-commit.txt"

cd "$release_source/shudo-web"
mkdir -p .vercel
jq -n --arg projectId "$project_id" --arg orgId "$org_id" \
  '{projectId: $projectId, orgId: $orgId, projectName: "shudo"}' \
  > .vercel/project.json

print "Prepared immutable Vercel release commit $release_commit."
print "Installing and testing the exact web snapshot..."
npm ci
npm test
npm run lint
npm run typecheck

print "Pulling current production settings into the disposable snapshot..."
npx --offline --yes vercel@$vercel_version pull \
  --yes --environment=production --scope "$team_slug"
if ! jq -e --arg project "$project_id" --arg org "$org_id" \
  '.projectId == $project and
   .orgId == $org and
   .settings.rootDirectory == null' \
  .vercel/project.json >/dev/null; then
  print -u2 "Vercel project must use its project root while releases run from shudo-web."
  exit 1
fi

production_env=".vercel/.env.production.local"
production_inventory="$audit_dir/production-env-inventory.json"
npx --offline --yes vercel@$vercel_version env ls production \
  --format json --project "$project_id" --scope "$team_slug" \
  > "$production_inventory"
"$node_cli" ../scripts/verify-vercel-env.mjs verify-public "$production_env"
"$node_cli" ../scripts/verify-vercel-env.mjs verify-inventory "$production_inventory"

print "Building with the current production environment..."
npx --offline --yes vercel@$vercel_version build \
  --prod --yes --scope "$team_slug"

if [[ "$apply_changes" != true ]]; then
  print "Dry-run production build passed. Re-run with --apply to deploy and smoke-test it."
  print "Non-secret audit artifacts: $audit_dir"
  exit 0
fi

cron_secret_file="$release_source/.cron-secret"
cron_curl_config="$release_source/.cron-curl.conf"
"$node_cli" ../scripts/verify-vercel-env.mjs generate-cron-material \
  "$cron_secret_file" "$cron_curl_config"
print "Rotating the production cron credential for this release..."
npx --offline --yes vercel@$vercel_version env update CRON_SECRET production \
  --sensitive --yes --project "$project_id" --scope "$team_slug" \
  < "$cron_secret_file"
production_inventory_after_rotation="$audit_dir/production-env-inventory-after-cron-rotation.json"
npx --offline --yes vercel@$vercel_version env ls production \
  --format json --project "$project_id" --scope "$team_slug" \
  > "$production_inventory_after_rotation"
"$node_cli" ../scripts/verify-vercel-env.mjs verify-cron-rotation \
  "$production_inventory" "$production_inventory_after_rotation"

print "Deploying the prebuilt immutable snapshot to production..."
deployment_output=""
if ! deployment_output="$(npx --offline --yes vercel@$vercel_version deploy \
  --prebuilt --prod --yes --scope "$team_slug")"; then
  print -u2 "Deployment failed after rotating CRON_SECRET."
  print -u2 "The current production deployment is unchanged; re-run --apply to rotate again and deploy."
  exit 1
fi
print -r -- "$deployment_output"
print -r -- "$deployment_output" > "$audit_dir/deployment-output.txt"

assert_status() {
  local url="$1"
  local expected="$2"
  local actual
  actual="$(curl --silent --show-error \
    --retry 5 --retry-all-errors --retry-delay 2 --max-time 30 \
    --output /dev/null --write-out '%{http_code}' "$url")"
  if [[ "$actual" != "$expected" ]]; then
    print -u2 "Smoke check failed: $url returned $actual, expected $expected."
    exit 1
  fi
  print -r -- "$actual $url" >> "$audit_dir/smoke.txt"
}

for origin in https://shudo.yng.sh https://shudo.vercel.app; do
  assert_status "$origin/terms" 200
  assert_status "$origin/support" 200
  assert_status "$origin/privacy" 404
  assert_status "$origin/auth/confirm" 200
  assert_status "$origin/reset-password" 200
  assert_status "$origin/api/cron/keepalive" 401
done

authorized_cron_status="$(curl --config "$cron_curl_config" \
  --output /dev/null --write-out '%{http_code}' \
  https://shudo.yng.sh/api/cron/keepalive)"
if [[ "$authorized_cron_status" != "200" ]]; then
  print -u2 "Authorized maintenance smoke returned $authorized_cron_status, expected 200."
  exit 1
fi
print -r -- "$authorized_cron_status authorized-cron" >> "$audit_dir/smoke.txt"

print "Vercel production release passed from commit $release_commit."
print "Non-secret deployment and smoke artifacts: $audit_dir"
