#!/bin/zsh -f

set -euo pipefail
umask 077

provided_access_token="${SUPABASE_ACCESS_TOKEN:-}"
provided_home="${HOME:-}"
provided_supabase_home="${SUPABASE_HOME:-}"
unset SUPABASE_ACCESS_TOKEN

repo_root="${0:A:h:h}"
project_ref="fjfashsjrajtdilxhcbn"
supabase_cli="/opt/homebrew/Cellar/supabase/2.109.1/bin/supabase"
supabase_cli_sha256="b7be23f4e211b75c00a3df5fcd1f96f3905983c74ff3189bfc69ad5b0f7132c4"
node_cli="/Users/luke/.nvm/versions/node/v24.16.0/bin/node"
node_cli_sha256="1ee75375e33b94fc34b3b19aede049e11dae90efb63b374dc96d6bdace70c4b8"
apply_changes=false

# Pin every ambient Supabase routing input before the CLI is invoked. Workdir
# is replaced with the immutable release snapshot below before credentials are
# loaded or any authenticated command runs.
export SUPABASE_NO_KEYRING=1
export SUPABASE_PROJECT_ID="$project_ref"
export SUPABASE_PROFILE="supabase"

case "${1:-}" in
  "") ;;
  --apply) apply_changes=true ;;
  *)
    print -u2 "Usage: ${0:t} [--apply]"
    exit 64
    ;;
esac

if [[ ! -x "$supabase_cli" ]]; then
  print -u2 "Supabase CLI not found at $supabase_cli"
  exit 1
fi

actual_cli_sha256="$(shasum -a 256 "$supabase_cli" | awk '{print $1}')"
if [[ "$actual_cli_sha256" != "$supabase_cli_sha256" ]]; then
  print -u2 "Supabase CLI integrity check failed. Refusing to load credentials."
  exit 1
fi

supabase_cli_version="$($supabase_cli --version)"
if [[ "$supabase_cli_version" != "2.109.1" ]]; then
  print -u2 "Supabase CLI 2.109.1 is required; found $supabase_cli_version."
  exit 1
fi

if [[ ! -x "$node_cli" ]]; then
  print -u2 "Node 24.16.0 not found at $node_cli"
  exit 1
fi
actual_node_sha256="$(shasum -a 256 "$node_cli" | awk '{print $1}')"
if [[ "$actual_node_sha256" != "$node_cli_sha256" ]]; then
  print -u2 "Node integrity check failed. Refusing to load credentials."
  exit 1
fi
if [[ "$(/usr/bin/env -i "$node_cli" --version)" != "v24.16.0" ]]; then
  print -u2 "Node 24.16.0 is required."
  exit 1
fi

if ! command -v git >/dev/null 2>&1 \
  || ! command -v jq >/dev/null 2>&1 \
  || ! command -v rg >/dev/null 2>&1 \
  || ! command -v tar >/dev/null 2>&1; then
  print -u2 "This release script requires git, jq, rg, and tar."
  exit 1
fi

cd "$repo_root"

release_paths=(
  scripts/deploy-supabase-production.zsh
  scripts/configure-supabase-auth.mjs
  supabase
)
release_tree_status="$(git status --porcelain --untracked-files=all -- $release_paths)"
if [[ -n "$release_tree_status" ]]; then
  print -u2 "Refusing mutable or uncommitted Supabase release inputs:"
  print -u2 -r -- "$release_tree_status"
  exit 1
fi

release_commit="$(git rev-parse --verify HEAD^{commit})"
release_tmp="$(mktemp -d "${TMPDIR:-/tmp}/shudo-supabase-release.XXXXXX")"
release_root="$release_tmp/source"
mkdir -p "$release_root"
git archive --format=tar "$release_commit" \
  -- supabase scripts/configure-supabase-auth.mjs | tar -xf - -C "$release_root"
if [[ -n "$(find "$release_root" -type l -print -quit)" ]]; then
  print -u2 "Refusing symlinks in the immutable release snapshot."
  exit 1
fi
if [[ ! -f "$release_root/scripts/configure-supabase-auth.mjs" ]]; then
  print -u2 "The immutable release is missing the Auth configurator."
  exit 1
fi
mkdir -p "$release_root/supabase/.temp"
print -r -- "$project_ref" > "$release_root/supabase/.temp/project-ref"
(
  cd "$release_root"
  find supabase/config.toml supabase/migrations supabase/functions \
    scripts/configure-supabase-auth.mjs -type f -print0 |
    sort -z |
    xargs -0 shasum -a 256
) > "$release_tmp/source-manifest.sha256"
print -r -- "$release_commit" > "$release_tmp/git-commit.txt"
export SUPABASE_WORKDIR="$release_root"

print "Prepared immutable Supabase release commit $release_commit."
print "Release snapshots: $release_tmp"

credential_root="${TMPDIR:-/tmp}"
credential_root="${credential_root%/}"
auth_input_directory=""

cleanup_auth_input() {
  [[ -n "$auth_input_directory" ]] || return 0
  case "$auth_input_directory" in
    "$credential_root"/shudo-supabase-auth-input.*)
      /bin/rm -rf -- "$auth_input_directory"
      ;;
    *)
      print -u2 "Refusing to remove unexpected Auth credential path."
      ;;
  esac
}
trap cleanup_auth_input EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

auth_input_directory="$(mktemp -d "$credential_root/shudo-supabase-auth-input.XXXXXX")"
staged_token_path="$auth_input_directory/SUPABASE_ACCESS_TOKEN"
if [[ -n "$provided_access_token" ]]; then
  if [[ "$provided_access_token" == *[[:space:]]* ]]; then
    print -u2 "SUPABASE_ACCESS_TOKEN must contain exactly one token without whitespace."
    exit 1
  fi
  print -rn -- "$provided_access_token" > "$staged_token_path"
  chmod 600 "$staged_token_path"
else
  token_environment=()
  [[ -n "$provided_home" ]] && token_environment+=("HOME=$provided_home")
  [[ -n "$provided_supabase_home" ]] && \
    token_environment+=("SUPABASE_HOME=$provided_supabase_home")
  /usr/bin/env -i "${token_environment[@]}" \
    "$node_cli" "$release_root/scripts/configure-supabase-auth.mjs" \
    stage-access-token "$staged_token_path"
fi

supabase_access_token=""
IFS= read -r supabase_access_token < "$staged_token_path" || \
  [[ -n "$supabase_access_token" ]]
if [[ -z "$supabase_access_token" || "$supabase_access_token" == *[[:space:]]* ]]; then
  print -u2 "The staged Supabase access token is invalid."
  exit 1
fi

run_supabase() {
  SUPABASE_ACCESS_TOKEN="$supabase_access_token" "$supabase_cli" "$@"
}

linked_ref_file="$repo_root/supabase/.temp/project-ref"
if [[ ! -f "$linked_ref_file" ]]; then
  print -u2 "Supabase project link is missing."
  exit 1
fi

linked_ref="$(tr -d '\r\n' < "$linked_ref_file")"
if [[ "$linked_ref" != "$project_ref" ]]; then
  print -u2 "Refusing linked project $linked_ref; expected $project_ref."
  exit 1
fi

cd "$release_root"

projects_json="$(run_supabase projects list --output-format json)"
if ! print -r -- "$projects_json" | jq -e --arg ref "$project_ref" \
  '(.projects // .) as $projects | any($projects[]; (.ref // .id) == $ref)' >/dev/null; then
  print -u2 "Authenticated Supabase account cannot access project $project_ref."
  exit 1
fi

required_secret_names=(
  OPENAI_API_KEY
  SHUDO_CLEANUP_SECRET
  SHUDO_WEEKLY_SECRET
)
secrets_json="$(run_supabase secrets list --project-ref "$project_ref" --output-format json)"
for secret_name in $required_secret_names; do
  if ! print -r -- "$secrets_json" | jq -e --arg name "$secret_name" \
    '(.secrets // .) as $secrets | any($secrets[]; .name == $name)' >/dev/null; then
    print -u2 "Required hosted secret is missing: $secret_name"
    exit 1
  fi
done
print "Verified required hosted secret names."

authenticated_functions=(
  create_entry
  correct_entry
  delete_entry
  delete_account
  process_entry
  onboard_profile
  reanalyze_entry
  resume_entry
)

maintenance_functions=(
  drain_storage_cleanup
  generate_weekly_summaries
)

allowed_function_slugs_json="$(
  print -l -- $authenticated_functions $maintenance_functions |
    jq -Rsc 'split("\n") | map(select(length > 0))'
)"
function_inventory_json="$(run_supabase functions list \
  --project-ref "$project_ref" --output-format json)"
unexpected_function_text="$(
  print -r -- "$function_inventory_json" |
    jq -r --argjson allowed "$allowed_function_slugs_json" '
      (.functions // .)[] |
      .slug as $slug |
      select(($allowed | index($slug)) == null) |
      $slug
    '
)"
if [[ -n "$unexpected_function_text" ]]; then
  print -u2 "Refusing production release with unapproved Edge Functions:"
  print -u2 -r -- "$unexpected_function_text"
  print -u2 "Audit and explicitly delete each obsolete function before retrying."
  exit 1
fi
print "Verified production Edge Function allowlist."

approved_migration_files=(
  20260720221116_rebuild_shudo_core.sql
  20260721125035_add_analysis_streaming_preview.sql
  20260721222010_restrict_rls_auto_enable_execute.sql
  20260721223105_account_onboarding_corrections_weekly.sql
  20260721231126_harden_target_history_weekly_claims.sql
  20260721234531_add_voice_entry_correction_requests.sql
  20260722001415_project_ai_budget_timezone.sql
  20260722015329_restrict_beta_signups_to_allowlist.sql
)

approved_migration_hashes=(
  d2e46d509e50fef4266136c92a7aab60f218915a4cca44017d952c0f6247ad77
  acb508783d67fb3baf8594f47762443322550912653b0cd1af9e94601a399dae
  4fa8100a1001f22ae4e97a678ce8828f301df3436fc815f16b7c7910c92e5508
  d8ba1c1a16984df4afddba3f96772709baa28ffb15bae7d7ec63458266ecded1
  2334b068da5874533d6923f6a1039bac787eee140ac566dce2e64e77fb07c9f0
  0b6c89f623ff2ecc4e0223c60c1ff4a792ca7f953d116319fa622721521f7041
  ce7c138b6196d9b4a9ce6f93e8017458ef0707c065802ff80877d9ee93ab3be8
  9ca9a33afc91e370a2f1a469b8291fdc637a4ddd79b9f56aeb8e636c628decf2
)

approved_migration_versions=()
for (( index = 1; index <= ${#approved_migration_files}; index++ )); do
  migration_file="${approved_migration_files[$index]}"
  migration_path="$release_root/supabase/migrations/$migration_file"
  if [[ ! -f "$migration_path" ]]; then
    print -u2 "Approved migration is missing: $migration_file"
    exit 1
  fi

  actual_hash="$(shasum -a 256 "$migration_path" | awk '{print $1}')"
  if [[ "$actual_hash" != "${approved_migration_hashes[$index]}" ]]; then
    print -u2 "Approved migration hash changed: $migration_file"
    exit 1
  fi
  approved_migration_versions+=("${migration_file%%_*}")
done

print "Checking production migration history..."
migration_history_json="$(run_supabase migration list --linked --output-format json)"
remote_version_text="$(
  print -r -- "$migration_history_json" |
    jq -r '(.migrations // .)[] | .remote | select(length > 0)'
)"
remote_versions=("${(@f)remote_version_text}")
if (( ${#remote_versions} == 1 )) && [[ -z "${remote_versions[1]}" ]]; then
  remote_versions=()
fi

if (( ${#remote_versions} < 2 )); then
  print -u2 "Remote migration history is missing the verified Shudo baseline."
  exit 1
fi
if (( ${#remote_versions} > ${#approved_migration_versions} )); then
  print -u2 "Remote migration history contains unapproved versions."
  exit 1
fi
for (( index = 1; index <= ${#remote_versions}; index++ )); do
  if [[ "${remote_versions[$index]}" != "${approved_migration_versions[$index]}" ]]; then
    print -u2 "Remote migration history diverges at ${remote_versions[$index]}."
    exit 1
  fi
done
print "Verified remote migration prefix: ${#remote_versions}/${#approved_migration_versions}"

dry_run_output=""
if ! dry_run_output="$(run_supabase db push --linked --dry-run 2>&1)"; then
  print -u2 -r -- "$dry_run_output"
  exit 1
fi
print -r -- "$dry_run_output"

pending_migration_text="$(
  print -r -- "$dry_run_output" |
    rg -o '[0-9]{14}_[A-Za-z0-9_]+\.sql' |
    awk '!seen[$0]++' || true
)"
pending_migrations=("${(@f)pending_migration_text}")
if (( ${#pending_migrations} == 1 )) && [[ -z "${pending_migrations[1]}" ]]; then
  pending_migrations=()
fi

expected_pending_count=$(( ${#approved_migration_files} - ${#remote_versions} ))
if (( ${#pending_migrations} != expected_pending_count )); then
  print -u2 "Dry-run migration count does not match verified remote history."
  exit 1
fi
for (( index = 1; index <= ${#pending_migrations}; index++ )); do
  expected_index=$(( ${#remote_versions} + index ))
  if [[ "${pending_migrations[$index]}" != "${approved_migration_files[$expected_index]}" ]]; then
    print -u2 "Unexpected migration plan: ${pending_migrations[$index]}"
    exit 1
  fi
done

print "Inspecting the exact hosted Auth configuration plan..."
/usr/bin/env -i TMPDIR="$release_tmp" \
  SHUDO_AUTH_INPUT_DIRECTORY="$auth_input_directory" \
  "$node_cli" "$release_root/scripts/configure-supabase-auth.mjs"

if [[ "$apply_changes" != true ]]; then
  print "Dry-run passed. Re-run with --apply to deploy migrations, Auth, and functions."
  exit 0
fi

print -r -- "$migration_history_json" > "$release_tmp/migrations-before.json"
print -r -- "$function_inventory_json" > "$release_tmp/functions-before.json"

if (( ${#pending_migrations} > 0 )); then
  print "Applying ${#pending_migrations} approved migration(s)..."
  run_supabase db push --linked --yes
else
  print "Database migrations are already current."
fi

post_push_output=""
if ! post_push_output="$(run_supabase db push --linked --dry-run 2>&1)"; then
  print -u2 -r -- "$post_push_output"
  exit 1
fi
print -r -- "$post_push_output"
if print -r -- "$post_push_output" | rg -q '[0-9]{14}_[A-Za-z0-9_]+\.sql'; then
  print -u2 "Database still reports pending migrations after deployment."
  exit 1
fi

print "Applying and verifying the friends-beta hosted Auth configuration..."
/usr/bin/env -i TMPDIR="$release_tmp" \
  SHUDO_AUTH_INPUT_DIRECTORY="$auth_input_directory" \
  "$node_cli" "$release_root/scripts/configure-supabase-auth.mjs" --apply

for function_name in $authenticated_functions; do
  print "Deploying authenticated function: $function_name"
  run_supabase functions deploy "$function_name" \
    --project-ref "$project_ref" --use-api --jobs 1
done

for function_name in $maintenance_functions; do
  print "Deploying maintenance function: $function_name"
  run_supabase functions deploy "$function_name" \
    --project-ref "$project_ref" --use-api --jobs 1 --no-verify-jwt
done

run_supabase functions list --project-ref "$project_ref" --output-format json \
  > "$release_tmp/functions-after.json"

jq -e '
  def authenticated:
    ["create_entry", "correct_entry", "delete_entry", "delete_account",
     "process_entry", "onboard_profile", "reanalyze_entry", "resume_entry"];
  def maintenance: ["drain_storage_cleanup", "generate_weekly_summaries"];
  (.functions // .) as $all |
  ([$all[] | .slug] | sort) == ((authenticated + maintenance) | sort) and
  ([$all[] |
      select(.slug as $slug | authenticated | index($slug)) |
      select(.status != "ACTIVE" or .verify_jwt != true)] | length == 0) and
  ([$all[] |
      select(.slug as $slug | maintenance | index($slug)) |
      select(.status != "ACTIVE" or .verify_jwt != false)] | length == 0)
' "$release_tmp/functions-after.json" >/dev/null

print "Running Supabase security and performance advisors..."
run_supabase db advisors --linked --type security --level warn --fail-on error
run_supabase db advisors --linked --type performance --level warn --fail-on error

post_migration_history="$(run_supabase migration list --linked --output-format json)"
print -r -- "$post_migration_history" > "$release_tmp/migrations-after.json"
if ! print -r -- "$post_migration_history" | jq -e \
  --argjson expected_count "${#approved_migration_versions}" '
    (.migrations // .) as $rows |
    ([$rows[] | .remote | select(length > 0)] | length) == $expected_count and
    ([$rows[] | select(.local != .remote)] | length) == 0
  ' >/dev/null; then
  print -u2 "Migration history is not fully synchronized after deployment."
  exit 1
fi
print "Supabase production release passed from commit $release_commit."
print "Snapshots and source manifest: $release_tmp"
