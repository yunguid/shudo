#!/bin/zsh

set -euo pipefail

shudo_repo_root="${0:A:h:h}"
shudo_web_root="$shudo_repo_root/shudo-web"
shudo_migration="$shudo_repo_root/supabase/migrations/20260720221116_rebuild_shudo_core.sql"
shudo_expected_migration_sha="d2e46d509e50fef4266136c92a7aab60f218915a4cca44017d952c0f6247ad77"
shudo_node24_dir="/Users/luke/.nvm/versions/node/v24.16.0/bin"

if [[ -x "$shudo_node24_dir/node" ]]; then
  export PATH="$shudo_node24_dir:$PATH"
fi
if [[ "$(node --version)" != v24.* ]]; then
  print -u2 "Shudo release verification requires Node 24.x."
  exit 1
fi

shudo_actual_migration_sha="$(shasum -a 256 "$shudo_migration" | awk '{print $1}')"
if [[ "$shudo_actual_migration_sha" != "$shudo_expected_migration_sha" ]]; then
  print -u2 "Migration hash changed; update the private recovery manifest before cutover."
  exit 1
fi

cd "$shudo_repo_root"
git diff --check
plutil -lint shudo/Info.plist shudo.xcodeproj/project.pbxproj

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

print "Shudo release verification passed."
print "Xcode result bundle: $shudo_xc_result"
