#!/bin/zsh

set -euo pipefail

shudo_repo_root="${0:A:h:h}"
shudo_project="$shudo_repo_root/shudo.xcodeproj"
shudo_info="$shudo_repo_root/shudo/Info.plist"
shudo_privacy="$shudo_repo_root/shudo/PrivacyInfo.xcprivacy"
shudo_icon_root="$shudo_repo_root/shudo/Assets.xcassets/AppIcon.appiconset"
shudo_expected_bundle_id="luke.shudo"
shudo_expected_url_scheme="shudo"
shudo_metadata_only=false

case "${1:-}" in
  "") ;;
  --metadata-only) shudo_metadata_only=true ;;
  *)
    print -u2 "Usage: ${0:t} [--metadata-only]"
    exit 64
    ;;
esac

fail() {
  print -u2 "iOS release check failed: $1"
  exit 1
}

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]] || fail "Xcode is unavailable at $DEVELOPER_DIR"
command -v jq >/dev/null || fail "jq is required"

plutil -lint "$shudo_project/project.pbxproj" "$shudo_info" "$shudo_privacy"

[[ "$(plutil -extract CFBundleDisplayName raw "$shudo_info")" == "Shudo" ]] || \
  fail "CFBundleDisplayName must remain Shudo"
[[ "$(plutil -extract ITSAppUsesNonExemptEncryption raw "$shudo_info")" == "false" ]] || \
  fail "export-compliance declaration changed; review it before release"
[[ -n "$(plutil -extract NSCameraUsageDescription raw "$shudo_info")" ]] || \
  fail "camera purpose text is missing"
[[ -n "$(plutil -extract NSMicrophoneUsageDescription raw "$shudo_info")" ]] || \
  fail "microphone purpose text is missing"
[[ "$(plutil -extract CFBundleURLTypes.0.CFBundleURLSchemes.0 raw "$shudo_info")" == \
  "$shudo_expected_url_scheme" ]] || fail "the shudo deep-link scheme changed"
[[ "$(plutil -extract UIBackgroundModes.0 raw "$shudo_info")" == "audio" ]] || \
  fail "background recording mode is missing"
if plutil -extract NSPhotoLibraryUsageDescription raw "$shudo_info" >/dev/null 2>&1; then
  fail "PhotosPicker does not need full-library permission; remove NSPhotoLibraryUsageDescription"
fi

[[ "$(plutil -extract NSPrivacyTracking raw "$shudo_privacy")" == "false" ]] || \
  fail "the privacy manifest unexpectedly enables tracking"
[[ "$(plutil -extract NSPrivacyTrackingDomains raw "$shudo_privacy")" == "0" ]] || \
  fail "tracking domains must be empty"
[[ "$(plutil -extract NSPrivacyCollectedDataTypes raw "$shudo_privacy")" -ge 8 ]] || \
  fail "the privacy manifest is missing Shudo data categories"
[[ "$(plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPIType raw "$shudo_privacy")" == \
  "NSPrivacyAccessedAPICategoryUserDefaults" ]] || fail "UserDefaults required-reason API is missing"
[[ "$(plutil -extract NSPrivacyAccessedAPITypes.0.NSPrivacyAccessedAPITypeReasons.0 raw "$shudo_privacy")" == \
  "CA92.1" ]] || fail "UserDefaults reason must remain CA92.1"

jq -e '
  [.images[].filename] | sort == ["1.png", "AppIconDark.png", "AppIconTinted.png"]
' "$shudo_icon_root/Contents.json" >/dev/null || fail "the complete app-icon variants are not assigned"

for shudo_icon in 1.png AppIconDark.png AppIconTinted.png; do
  shudo_icon_path="$shudo_icon_root/$shudo_icon"
  [[ -f "$shudo_icon_path" ]] || fail "missing $shudo_icon"
  shudo_icon_width="$(sips -g pixelWidth "$shudo_icon_path" | awk '/pixelWidth/ { print $2 }')"
  shudo_icon_height="$(sips -g pixelHeight "$shudo_icon_path" | awk '/pixelHeight/ { print $2 }')"
  shudo_icon_alpha="$(sips -g hasAlpha "$shudo_icon_path" | awk '/hasAlpha/ { print $2 }')"
  [[ "$shudo_icon_width" == 1024 && "$shudo_icon_height" == 1024 ]] || \
    fail "$shudo_icon must be 1024 by 1024 pixels"
  [[ "$shudo_icon_alpha" == "no" ]] || fail "$shudo_icon must not contain transparency"
done

shudo_audit_root="$(mktemp -d /tmp/shudo-ios-release.XXXXXX)"
cleanup_shudo_ios_audit() {
  case "$shudo_audit_root" in
    /tmp/shudo-ios-release.*) rm -r -- "$shudo_audit_root" ;;
    *) print -u2 "Refusing to remove unexpected path: $shudo_audit_root" ;;
  esac
}
trap cleanup_shudo_ios_audit EXIT

shudo_settings="$shudo_audit_root/release-build-settings.txt"
xcodebuild -project "$shudo_project" -scheme shudo -configuration Release \
  -destination 'generic/platform=iOS' -showBuildSettings >"$shudo_settings"

build_setting() {
  local key="$1"
  sed -n "s/^[[:space:]]*${key} = //p" "$shudo_settings" | sed -n '1p'
}

shudo_bundle_id="$(build_setting PRODUCT_BUNDLE_IDENTIFIER)"
shudo_marketing_version="$(build_setting MARKETING_VERSION)"
shudo_build_number="$(build_setting CURRENT_PROJECT_VERSION)"
shudo_deployment_target="$(build_setting IPHONEOS_DEPLOYMENT_TARGET)"
shudo_device_family="$(build_setting TARGETED_DEVICE_FAMILY)"
shudo_team="$(build_setting DEVELOPMENT_TEAM)"

[[ "$shudo_bundle_id" == "$shudo_expected_bundle_id" ]] || \
  fail "bundle identifier changed from $shudo_expected_bundle_id"
[[ "$shudo_marketing_version" =~ '^[0-9]+([.][0-9]+){1,2}$' ]] || \
  fail "MARKETING_VERSION is not an App Store version string"
[[ "$shudo_build_number" =~ '^[1-9][0-9]*$' ]] || \
  fail "CURRENT_PROJECT_VERSION must be a positive integer"
[[ -n "$shudo_deployment_target" ]] || fail "deployment target is missing"
[[ "$shudo_device_family" == "1" ]] || fail "Shudo should remain iPhone-only unless iPad is tested"
[[ -n "$shudo_team" ]] || fail "DEVELOPMENT_TEAM is missing"

print "Metadata ready: Shudo $shudo_marketing_version ($shudo_build_number), iOS $shudo_deployment_target+, $shudo_bundle_id"

if $shudo_metadata_only; then
  print "Shudo iOS metadata verification passed."
  exit 0
fi

shudo_derived_data="$shudo_audit_root/DerivedData"
xcodebuild -project "$shudo_project" -scheme shudo -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$shudo_derived_data" \
  CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  GCC_TREAT_WARNINGS_AS_ERRORS=YES build

shudo_app="$shudo_derived_data/Build/Products/Release-iphoneos/shudo.app"
[[ -d "$shudo_app" ]] || fail "Release build product was not created"
[[ -f "$shudo_app/PrivacyInfo.xcprivacy" ]] || fail "privacy manifest was not bundled"
[[ -f "$shudo_app/Assets.car" ]] || fail "asset catalog was not bundled"
plutil -lint "$shudo_app/Info.plist" "$shudo_app/PrivacyInfo.xcprivacy"
[[ "$(plutil -extract CFBundleIdentifier raw "$shudo_app/Info.plist")" == "$shudo_bundle_id" ]] || \
  fail "compiled bundle identifier does not match build settings"
[[ "$(plutil -extract CFBundleShortVersionString raw "$shudo_app/Info.plist")" == \
  "$shudo_marketing_version" ]] || fail "compiled marketing version does not match build settings"
[[ "$(plutil -extract CFBundleVersion raw "$shudo_app/Info.plist")" == "$shudo_build_number" ]] || \
  fail "compiled build number does not match build settings"

print "Shudo unsigned Release build and bundled privacy metadata passed."
