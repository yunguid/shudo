#!/bin/zsh

set -euo pipefail

shudo_repo_root="${0:A:h:h}"
shudo_project="$shudo_repo_root/shudo.xcodeproj"
shudo_unlock_helper="$shudo_repo_root/scripts/unlock-shudo-keychain.swift"
shudo_device_udid="${SHUDO_DEVICE_UDID:-00008150-0004658214F2401C}"
shudo_core_device_id="${SHUDO_CORE_DEVICE_ID:-D662BA1F-D7E4-500E-A4F4-D9B9A136D7B5}"
shudo_signing_keychain="${SHUDO_SIGNING_KEYCHAIN:-/Users/luke/Library/Keychains/ShudoSigning.keychain-db}"
shudo_passphrase_file="${SHUDO_SIGNING_PASSPHRASE_FILE:-/Users/luke/Library/Application Support/ShudoSigning/keychain-passphrase}"
shudo_expected_bundle_id="luke.shudo"
shudo_derived_data=""

fail() {
  print -u2 "Shudo device install failed: $1"
  exit 1
}

cleanup_shudo_device_install() {
  if [[ -n "$shudo_derived_data" ]]; then
    case "$shudo_derived_data" in
      /private/tmp/shudo-device-install.*) rm -r -- "$shudo_derived_data" ;;
      *) print -u2 "Refusing to remove unexpected path: $shudo_derived_data" ;;
    esac
  fi
}
trap cleanup_shudo_device_install EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] || fail "Xcode is unavailable at $DEVELOPER_DIR"
[[ -f "$shudo_project/project.pbxproj" ]] || fail "run this command from the Shudo checkout"
[[ -f "$shudo_unlock_helper" && ! -L "$shudo_unlock_helper" ]] || \
  fail "the Shudo keychain helper is missing"
[[ -f "$shudo_signing_keychain" && ! -L "$shudo_signing_keychain" ]] || \
  fail "the dedicated Shudo signing keychain is missing"
[[ -f "$shudo_passphrase_file" && ! -L "$shudo_passphrase_file" ]] || \
  fail "the owner-only signing passphrase file is missing"
[[ "$(stat -f '%Su' "$shudo_passphrase_file")" == "$(id -un)" ]] || \
  fail "the signing passphrase file has the wrong owner"
[[ "$(stat -f '%Lp' "$shudo_passphrase_file")" == "600" ]] || \
  fail "the signing passphrase file must use mode 600"

shudo_first_keychain="$(
  security list-keychains -d user \
    | sed -n '1{s/^[[:space:]]*"//;s/"[[:space:]]*$//;p;}'
)"
[[ "$shudo_first_keychain" == "$shudo_signing_keychain" ]] || \
  fail "ShudoSigning must remain first in the user Keychain search list"

xcrun swift -suppress-warnings \
  "$shudo_unlock_helper" \
  "$shudo_signing_keychain" \
  "$shudo_passphrase_file"

security find-identity -v -p codesigning "$shudo_signing_keychain" \
  | rg -q 'Apple Development: lrgnyc@icloud\.com \(5A6M37BUS4\)' || \
  fail "the replacement Apple Development identity is unavailable"

shudo_device_line="$(
  xcrun devicectl list devices \
    | awk -v identifier="$shudo_core_device_id" '$0 ~ identifier { print; exit }'
)"
[[ -n "$shudo_device_line" ]] || fail "Luke's trusted iPhone is not paired"
if [[ "$shudo_device_line" != *connected* && "$shudo_device_line" != *"available (paired)"* ]]; then
  fail "Luke's trusted iPhone is not available"
fi

shudo_derived_data="$(mktemp -d /private/tmp/shudo-device-install.XXXXXX)"

print "Building the signed Shudo Release for Luke's iPhone…"
xcodebuild \
  -project "$shudo_project" \
  -scheme shudo \
  -configuration Release \
  -destination "id=$shudo_device_udid" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  -derivedDataPath "$shudo_derived_data" \
  -quiet \
  build

shudo_app="$shudo_derived_data/Build/Products/Release-iphoneos/Shudo.app"
[[ -d "$shudo_app" ]] || shudo_app="$shudo_derived_data/Build/Products/Release-iphoneos/shudo.app"
[[ -d "$shudo_app" ]] || fail "the signed Release app was not created"

shudo_bundle_id="$(plutil -extract CFBundleIdentifier raw "$shudo_app/Info.plist")"
shudo_version="$(plutil -extract CFBundleShortVersionString raw "$shudo_app/Info.plist")"
shudo_build="$(plutil -extract CFBundleVersion raw "$shudo_app/Info.plist")"
[[ "$shudo_bundle_id" == "$shudo_expected_bundle_id" ]] || fail "the built bundle identifier changed"

print "Installing Shudo $shudo_version ($shudo_build)…"
xcrun devicectl device install app \
  --device "$shudo_core_device_id" \
  "$shudo_app"
xcrun devicectl device process launch \
  --device "$shudo_core_device_id" \
  "$shudo_bundle_id"

# awk must read devicectl's full output: an early `exit` here sends devicectl
# SIGPIPE, which pipefail turns into a spurious 141 after a successful install.
shudo_installed_version="$(
  xcrun devicectl device info apps \
    --device "$shudo_core_device_id" \
    --include-all-apps \
    | awk -v bundle="$shudo_bundle_id" '$2 == bundle && !found { print $3 "|" $4; found = 1 }'
)"
[[ "$shudo_installed_version" == "$shudo_version|$shudo_build" ]] || \
  fail "the phone did not report the expected installed version"

print "Installed and launched Shudo $shudo_version ($shudo_build) on Luke's iPhone."
