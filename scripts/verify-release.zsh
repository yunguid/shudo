#!/bin/zsh

set -euo pipefail

shudo_repo_root="${0:A:h:h}"
shudo_web_root="$shudo_repo_root/shudo-web"
shudo_core_migration="$shudo_repo_root/supabase/migrations/20260720221116_rebuild_shudo_core.sql"
shudo_core_migration_sha="d2e46d509e50fef4266136c92a7aab60f218915a4cca44017d952c0f6247ad77"
shudo_streaming_migration="$shudo_repo_root/supabase/migrations/20260721125035_add_analysis_streaming_preview.sql"
shudo_streaming_migration_sha="acb508783d67fb3baf8594f47762443322550912653b0cd1af9e94601a399dae"
shudo_rls_helper_migration="$shudo_repo_root/supabase/migrations/20260721222010_restrict_rls_auto_enable_execute.sql"
shudo_rls_helper_migration_sha="4fa8100a1001f22ae4e97a678ce8828f301df3436fc815f16b7c7910c92e5508"
shudo_account_migration="$shudo_repo_root/supabase/migrations/20260721223105_account_onboarding_corrections_weekly.sql"
shudo_account_migration_sha="d8ba1c1a16984df4afddba3f96772709baa28ffb15bae7d7ec63458266ecded1"
shudo_hardening_migration="$shudo_repo_root/supabase/migrations/20260721231126_harden_target_history_weekly_claims.sql"
shudo_hardening_migration_sha="2334b068da5874533d6923f6a1039bac787eee140ac566dce2e64e77fb07c9f0"
shudo_voice_correction_migration="$shudo_repo_root/supabase/migrations/20260721234531_add_voice_entry_correction_requests.sql"
shudo_voice_correction_migration_sha="0b6c89f623ff2ecc4e0223c60c1ff4a792ca7f953d116319fa622721521f7041"
shudo_budget_migration="$shudo_repo_root/supabase/migrations/20260722001415_project_ai_budget_timezone.sql"
shudo_budget_migration_sha="ce7c138b6196d9b4a9ce6f93e8017458ef0707c065802ff80877d9ee93ab3be8"
shudo_beta_signup_migration="$shudo_repo_root/supabase/migrations/20260722015329_restrict_beta_signups_to_allowlist.sql"
shudo_beta_signup_migration_sha="9ca9a33afc91e370a2f1a469b8291fdc637a4ddd79b9f56aeb8e636c628decf2"
shudo_node24_dir="/Users/luke/.nvm/versions/node/v24.16.0/bin"
shudo_node24_sha="1ee75375e33b94fc34b3b19aede049e11dae90efb63b374dc96d6bdace70c4b8"
shudo_supabase_cli="/opt/homebrew/Cellar/supabase/2.109.1/bin/supabase"
shudo_supabase_cli_sha="b7be23f4e211b75c00a3df5fcd1f96f3905983c74ff3189bfc69ad5b0f7132c4"

if [[ -x "$shudo_node24_dir/node" ]]; then
  export PATH="$shudo_node24_dir:$PATH"
fi
if [[ "$(node --version)" != v24.* ]]; then
  print -u2 "Shudo release verification requires Node 24.x."
  exit 1
fi
[[ "$(shasum -a 256 "$shudo_node24_dir/node" | awk '{print $1}')" == "$shudo_node24_sha" ]]

verify_migration_sha() {
  local migration_path="$1"
  local expected_sha="$2"
  local actual_sha
  actual_sha="$(shasum -a 256 "$migration_path" | awk '{print $1}')"
  if [[ "$actual_sha" != "$expected_sha" ]]; then
    print -u2 "Migration hash changed: ${migration_path:t}"
    exit 1
  fi
}

verify_migration_sha "$shudo_core_migration" "$shudo_core_migration_sha"
verify_migration_sha "$shudo_streaming_migration" "$shudo_streaming_migration_sha"
verify_migration_sha "$shudo_rls_helper_migration" "$shudo_rls_helper_migration_sha"
verify_migration_sha "$shudo_account_migration" "$shudo_account_migration_sha"
verify_migration_sha "$shudo_hardening_migration" "$shudo_hardening_migration_sha"
verify_migration_sha "$shudo_voice_correction_migration" "$shudo_voice_correction_migration_sha"
verify_migration_sha "$shudo_budget_migration" "$shudo_budget_migration_sha"
verify_migration_sha "$shudo_beta_signup_migration" "$shudo_beta_signup_migration_sha"

cd "$shudo_repo_root"
git diff --check
plutil -lint shudo/Info.plist shudo.xcodeproj/project.pbxproj
[[ "$(shasum -a 256 "$shudo_supabase_cli" | awk '{print $1}')" == "$shudo_supabase_cli_sha" ]]
! rg -q 'SHUDO_SUPABASE_CLI' \
  scripts/login-supabase-no-keyring.zsh scripts/deploy-supabase-production.zsh
[[ -x scripts/login-supabase-no-keyring.zsh ]]
zsh -n scripts/login-supabase-no-keyring.zsh
[[ -x scripts/deploy-supabase-production.zsh ]]
zsh -n scripts/deploy-supabase-production.zsh
[[ -f scripts/configure-supabase-auth.mjs && ! -L scripts/configure-supabase-auth.mjs ]]
[[ -x scripts/configure-supabase-auth.zsh ]]
zsh -n scripts/configure-supabase-auth.zsh
/usr/bin/env -i "$shudo_node24_dir/node" --check \
  scripts/configure-supabase-auth.mjs
/usr/bin/env -i "$shudo_node24_dir/node" --test \
  scripts/configure-supabase-auth.test.mjs
[[ -x scripts/manage-beta-invite.zsh ]]
zsh -n scripts/manage-beta-invite.zsh
/usr/bin/env -i "$shudo_node24_dir/node" --check \
  scripts/manage-beta-invite.mjs
/usr/bin/env -i "$shudo_node24_dir/node" --test \
  scripts/manage-beta-invite.test.mjs
[[ -x scripts/deploy-vercel-production.zsh ]]
zsh -n scripts/deploy-vercel-production.zsh
/usr/bin/env -i "$shudo_node24_dir/node" --check \
  scripts/verify-vercel-env.mjs
/usr/bin/env -i "$shudo_node24_dir/node" --test \
  scripts/verify-vercel-env.test.mjs

cd "$shudo_web_root"
npm ci
npm test
npm run lint
npm run typecheck
npm run build
npm audit --audit-level=moderate
npx --offline --yes vercel@56.4.1 build --prod --yes --scope ekuls-projects
npx --offline --yes vercel@56.4.1 deploy --dry --format=json \
  --scope ekuls-projects | jq -e '
    . as $manifest
    | ([".env.local", ".next", ".vercel", "node_modules", "tsconfig.tsbuildinfo"] - .ignored) as $missing
    | [.files[].path | select(test("(^|/)(\\.env\\.local|\\.next|\\.vercel|node_modules|.*\\.tsbuildinfo)(/|$)"))] as $included
    | if (($missing | length) == 0 and ($included | length) == 0)
      then {fileCount, totalSize, missingRequiredIgnored: $missing, sensitiveIncluded: $included}
      else error("unsafe Vercel upload manifest")
      end
  '

cd "$shudo_repo_root"
npx --yes deno@2.5.6 fmt --check supabase/functions
npx --yes deno@2.5.6 lint supabase/functions
npx --yes deno@2.5.6 test supabase/functions/tests
npx --yes deno@2.5.6 check supabase/functions/**/*.ts

shudo_pg_dir="$(mktemp -d /tmp/shudo-release-pg.XXXXXX)"
shudo_pg_port=55459
cleanup_shudo_release_pg() {
  /opt/homebrew/bin/pg_ctl -D "$shudo_pg_dir/data" -m fast stop >/dev/null 2>&1 || true
  case "$shudo_pg_dir" in
    /tmp/shudo-release-pg.*) rm -r -- "$shudo_pg_dir" ;;
    *) print -u2 "Refusing to remove unexpected path: $shudo_pg_dir" ;;
  esac
}
trap cleanup_shudo_release_pg EXIT

/opt/homebrew/bin/initdb -D "$shudo_pg_dir/data" --auth=trust \
  --no-locale --encoding=UTF8 >"$shudo_pg_dir/initdb.log"
/opt/homebrew/bin/pg_ctl -D "$shudo_pg_dir/data" \
  -o "-k $shudo_pg_dir -p $shudo_pg_port" \
  -l "$shudo_pg_dir/postgres.log" -w start >/dev/null
/opt/homebrew/bin/createdb -h "$shudo_pg_dir" -p "$shudo_pg_port" shudo_fresh
/opt/homebrew/bin/createdb -h "$shudo_pg_dir" -p "$shudo_pg_port" shudo_legacy
PGOPTIONS='--client-min-messages=warning' /opt/homebrew/bin/psql -X \
  -v ON_ERROR_STOP=1 -h "$shudo_pg_dir" -p "$shudo_pg_port" \
  -d shudo_fresh -f supabase/tests/fresh_schema.sql >/dev/null
PGOPTIONS='--client-min-messages=warning' /opt/homebrew/bin/psql -X \
  -v ON_ERROR_STOP=1 -h "$shudo_pg_dir" -p "$shudo_pg_port" \
  -d shudo_legacy -f supabase/tests/legacy_restore.sql >/dev/null

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
shudo_xc_dir="$(mktemp -d /tmp/shudo-release-xcode.XXXXXX)"
shudo_xc_result="$shudo_xc_dir/Shudo.xcresult"
xcodebuild -project shudo.xcodeproj -scheme shudo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -parallel-testing-enabled NO -resultBundlePath "$shudo_xc_result" \
  CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES test
xcrun xcresulttool get test-results summary --path "$shudo_xc_result"
"$shudo_repo_root/scripts/verify-ios-release.zsh"

print "Shudo release verification passed."
print "Xcode result bundle: $shudo_xc_result"
