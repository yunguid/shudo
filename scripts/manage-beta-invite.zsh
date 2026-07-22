#!/bin/zsh -f

set -euo pipefail
umask 077

node_cli="/Users/luke/.nvm/versions/node/v24.16.0/bin/node"
node_cli_sha256="1ee75375e33b94fc34b3b19aede049e11dae90efb63b374dc96d6bdace70c4b8"
command_file="${0:A:h}/manage-beta-invite.mjs"
provided_home="${HOME:-}"
provided_supabase_home="${SUPABASE_HOME:-}"

# Invite management always reads the owner-only token file created by the
# no-Keychain login helper; an ambient token is intentionally ignored.
unset SUPABASE_ACCESS_TOKEN

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
if [[ ! -f "$command_file" || -L "$command_file" ]]; then
  print -u2 "The beta invite command is missing or unsafe."
  exit 1
fi

safe_environment=()
[[ -n "$provided_home" ]] && safe_environment+=("HOME=$provided_home")
[[ -n "$provided_supabase_home" ]] && \
  safe_environment+=("SUPABASE_HOME=$provided_supabase_home")

exec /usr/bin/env -i "${safe_environment[@]}" \
  "$node_cli" "$command_file" "$@"
