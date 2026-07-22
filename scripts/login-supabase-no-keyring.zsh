#!/bin/zsh -f

set -euo pipefail
umask 077

provided_access_token="${SUPABASE_ACCESS_TOKEN:-}"
unset SUPABASE_ACCESS_TOKEN

repo_root="${0:A:h:h}"
project_ref="fjfashsjrajtdilxhcbn"
supabase_cli="/opt/homebrew/Cellar/supabase/2.109.1/bin/supabase"
supabase_cli_sha256="b7be23f4e211b75c00a3df5fcd1f96f3905983c74ff3189bfc69ad5b0f7132c4"

case "${1:-}" in
  "") ;;
  --replace) ;;
  *)
    print -u2 "Usage: ${0:t} [--replace]"
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
if [[ "$($supabase_cli --version)" != "2.109.1" ]]; then
  print -u2 "Supabase CLI 2.109.1 is required."
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  print -u2 "This login helper requires jq."
  exit 1
fi

export SUPABASE_NO_KEYRING=1
export SUPABASE_PROJECT_ID="$project_ref"
export SUPABASE_WORKDIR="$repo_root"
export SUPABASE_PROFILE="supabase"

token_file="${SUPABASE_HOME:-$HOME/.supabase}/access-token"

token_has_project_access() {
  local candidate_token="$1"
  local projects_json

  if [[ -z "$candidate_token" ]]; then
    return 1
  fi
  if ! projects_json="$(
    SUPABASE_ACCESS_TOKEN="$candidate_token" \
      "$supabase_cli" projects list --output-format json 2>/dev/null
  )"; then
    return 1
  fi
  print -r -- "$projects_json" | jq -e --arg ref "$project_ref" \
    '(.projects // .) as $projects | any($projects[]; (.ref // .id) == $ref)' \
    >/dev/null
}

if [[ -n "$provided_access_token" ]] && \
    token_has_project_access "$provided_access_token"; then
  print "The current environment already has prompt-free access to Shudo."
  exit 0
fi

existing_token=""
if [[ -f "$token_file" && -r "$token_file" ]]; then
  IFS= read -r existing_token < "$token_file" || [[ -n "$existing_token" ]]
  if [[ "$(stat -f '%Lp' "$token_file")" == "600" ]] && \
      token_has_project_access "$existing_token"; then
    print "Prompt-free Supabase access is already configured for Shudo."
    exit 0
  fi
  if [[ "${1:-}" != "--replace" ]]; then
    print -u2 "The existing non-Keychain token is invalid, inaccessible, or belongs to another account."
    print -u2 "Re-run with --replace to perform a fresh browser verification."
    exit 1
  fi
fi

print "Starting one-time Supabase browser verification."
print "Open the URL shown below, approve it, paste the short verification code, and press Return."
"$supabase_cli" login --no-browser --name supabase --agent no --output-format text

if [[ ! -f "$token_file" || ! -r "$token_file" ]]; then
  print -u2 "Supabase login completed without creating the non-Keychain token file."
  exit 1
fi
chmod 600 "$token_file"

saved_token=""
IFS= read -r saved_token < "$token_file" || [[ -n "$saved_token" ]]
if ! token_has_project_access "$saved_token"; then
  print -u2 "The authenticated account cannot access the Shudo production project."
  exit 1
fi

print "Prompt-free Supabase access is ready. The token was not printed."
