#!/bin/zsh -f

set -euo pipefail
umask 077

node_cli="/Users/luke/.nvm/versions/node/v24.16.0/bin/node"
node_cli_sha256="1ee75375e33b94fc34b3b19aede049e11dae90efb63b374dc96d6bdace70c4b8"
configurator="${0:A:h}/configure-supabase-auth.mjs"

provided_home="${HOME:-}"
provided_supabase_home="${SUPABASE_HOME:-}"
provided_access_token="${SUPABASE_ACCESS_TOKEN:-}"
provided_google_client_id="${SHUDO_GOOGLE_CLIENT_ID:-}"
provided_google_client_secret="${SHUDO_GOOGLE_CLIENT_SECRET:-}"
provided_smtp_admin_email="${SHUDO_SMTP_ADMIN_EMAIL:-}"
provided_smtp_host="${SHUDO_SMTP_HOST:-}"
provided_smtp_port="${SHUDO_SMTP_PORT:-}"
provided_smtp_user="${SHUDO_SMTP_USER:-}"
provided_smtp_pass="${SHUDO_SMTP_PASS:-}"
provided_smtp_sender_name="${SHUDO_SMTP_SENDER_NAME:-}"

unset SUPABASE_ACCESS_TOKEN SHUDO_GOOGLE_CLIENT_ID \
  SHUDO_GOOGLE_CLIENT_SECRET SHUDO_SMTP_ADMIN_EMAIL SHUDO_SMTP_HOST \
  SHUDO_SMTP_PORT SHUDO_SMTP_USER SHUDO_SMTP_PASS SHUDO_SMTP_SENDER_NAME

if [[ ! -x "$node_cli" ]]; then
  print -u2 "Node 24.16.0 not found at $node_cli"
  exit 1
fi
actual_node_sha256="$(/usr/bin/shasum -a 256 "$node_cli")"
actual_node_sha256="${actual_node_sha256%% *}"
if [[ "$actual_node_sha256" != "$node_cli_sha256" ]]; then
  print -u2 "Node integrity check failed. Refusing to load credentials."
  exit 1
fi
if [[ "$(/usr/bin/env -i "$node_cli" --version)" != "v24.16.0" ]]; then
  print -u2 "Node 24.16.0 is required."
  exit 1
fi
if [[ ! -f "$configurator" || -L "$configurator" ]]; then
  print -u2 "The Supabase Auth configurator is missing or unsafe."
  exit 1
fi

credential_root="${TMPDIR:-/tmp}"
credential_root="${credential_root%/}"
credential_directory=""

cleanup_credentials() {
  [[ -n "$credential_directory" ]] || return 0
  case "$credential_directory" in
    "$credential_root"/shudo-auth-input.*)
      /bin/rm -rf -- "$credential_directory"
      ;;
    *)
      print -u2 "Refusing to remove unexpected credential path."
      ;;
  esac
}
trap cleanup_credentials EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

credential_directory="$(mktemp -d "$credential_root/shudo-auth-input.XXXXXX")"

write_credential() {
  local name="$1"
  local value="$2"
  [[ -n "$value" ]] || return 0
  print -rn -- "$value" > "$credential_directory/$name"
}

write_credential SUPABASE_ACCESS_TOKEN "$provided_access_token"
write_credential SHUDO_GOOGLE_CLIENT_ID "$provided_google_client_id"
write_credential SHUDO_GOOGLE_CLIENT_SECRET "$provided_google_client_secret"
write_credential SHUDO_SMTP_ADMIN_EMAIL "$provided_smtp_admin_email"
write_credential SHUDO_SMTP_HOST "$provided_smtp_host"
write_credential SHUDO_SMTP_PORT "$provided_smtp_port"
write_credential SHUDO_SMTP_USER "$provided_smtp_user"
write_credential SHUDO_SMTP_PASS "$provided_smtp_pass"
write_credential SHUDO_SMTP_SENDER_NAME "$provided_smtp_sender_name"

safe_environment=("SHUDO_AUTH_INPUT_DIRECTORY=$credential_directory")
[[ -n "$provided_home" ]] && safe_environment+=("HOME=$provided_home")
[[ -n "$provided_supabase_home" ]] && \
  safe_environment+=("SUPABASE_HOME=$provided_supabase_home")

/usr/bin/env -i "${safe_environment[@]}" \
  "$node_cli" "$configurator" "$@"
