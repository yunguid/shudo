# Shudo iOS release readiness

Last audited: 2026-07-22

This document separates the build that can be installed directly from Xcode
today from the credentials and App Store Connect work needed for TestFlight or
public distribution. It does not authorize changes to Luke's Apple account.

## Verified in source

- Product: `Shudo` / bundle identifier `luke.shudo`
- Version: `1.0` / build `2`
- Platform: iPhone, portrait, iOS 18.5 or later
- Signing mode: automatic, with Luke's Personal Team selected and a dedicated
  local `ShudoSigning` keychain ahead of the stale login-keychain identity
- Deep links: `shudo://capture` and the `shudo://auth/callback` OAuth callback
- Permission prompts: microphone and camera only
- Photo selection: SwiftUI `PhotosPicker`; it does not request unrestricted
  photo-library access, and selected images are re-rendered before upload so
  their original metadata is not sent
- Background mode: audio, used only while the user explicitly records a voice
  note
- Export declaration: no non-exempt encryption. This is appropriate while the
  app only uses Apple's networking encryption and SHA-256/secure randomness for
  authentication; revisit it if custom cryptography is added
- App icon: light, dark, and tinted 1024-by-1024 variants, all opaque
- Privacy manifest: bundled, tracking disabled, first-party data categories
  declared, and the `CA92.1` reason declared for app-only `UserDefaults`
- App deletion: the current Settings UI includes a destructive, confirmed
  in-app account-deletion path

Run the focused source and unsigned Release-build check with:

```bash
scripts/verify-ios-release.zsh
```

Use `--metadata-only` for the fast plist, icon, and build-setting checks. The
full command creates a clean unsigned device Release build, treats compiler
warnings as errors, runs Xcode's store validation step, and confirms that the
compiled app contains the privacy manifest and asset catalog.

## Current distribution blockers that require Luke

1. **Apple Developer Program access.** Xcode's supported repair flow revoked the
   inaccessible development certificate and created a replacement identity in
   the dedicated `ShudoSigning` keychain. Shudo 1.0 (2) was then signed,
   installed, and launched on Luke's iPhone. Its device-only development profile
   expires on 2026-07-29 at 00:05 EST and has `get-task-allow` enabled. There is
   still no Apple Distribution identity or App Store provisioning profile. Luke
   needs an active paid Apple Developer Program membership and an App Store
   Connect role that can create or manage the app before friends can use
   TestFlight or Sign in with Apple.
2. **Permanent App ID and app record.** An Account Holder or Admin must confirm
   that `luke.shudo` belongs to the paid team, then create the App Store Connect
   app record with that exact bundle ID. Do not change the bundle ID casually:
   doing so creates a different app and prevents updates over the installed
   development build.
3. **Sign in with Apple.** Before Apple login is shipped, an Account Holder or
   Admin must enable Sign in with Apple on the App ID and finish the Apple-side
   provider configuration used by Supabase. Only then should the Xcode target
   receive the Sign in with Apple capability/entitlement and a fresh profile.
   Adding that entitlement now may make the Personal Team build un-installable.
4. **Google and Apple provider credentials.** The OAuth clients, return URLs,
   consent-screen details, and Supabase provider settings must be created and
   verified. These are persistent account changes and need Luke's confirmation
   and Apple password/MFA handoff.
5. **A real privacy policy.** The placeholder policy was intentionally removed
   at Luke's direction. `/privacy` must remain absent instead of presenting
   invented legal copy. Direct installation from Xcode can proceed without a
   public policy URL. External TestFlight testing still goes through TestFlight
   App Review and may require complete privacy information; a public App Store
   submission definitely needs an accurate policy that Luke has reviewed and
   accepted.
6. **Store listing decisions.** Luke must accept the app name, subtitle,
   category, age-rating answers, screenshots, description, countries, pricing
   (free), and App Store agreements. A practical initial category is Health &
   Fitness; Shudo should be described as a nutrition estimate/log, not medical
   advice.
7. **Reviewer access.** Create a dedicated review account that exercises
   onboarding and a sample meal without exposing Luke's personal history.
   Include working credentials and concise voice/photo testing instructions in
   App Review Information. Keep the production backend available during review.

The current profile remains suitable for direct Xcode installation on the one
registered iPhone. It is not a TestFlight or public-distribution profile. At the
2026-07-21 release check, Luke's iPhone was connected and visible to Xcode. It
must remain connected, unlocked, and trusted when the direct install runs.

## App Store Connect privacy answers

The following is the source-of-truth mapping encoded in
`shudo/PrivacyInfo.xcprivacy`. Confirm it still matches production immediately
before submission.

| Data category | Linked to user | Tracking | Purpose |
| --- | --- | --- | --- |
| Email address | Yes | No | App functionality |
| User ID | Yes | No | App functionality |
| Health | Yes | No | App functionality; product personalization |
| Photos or videos | Yes | No | App functionality; product personalization |
| Audio data | Yes | No | App functionality |
| Other user content | Yes | No | App functionality; product personalization |
| Other diagnostic data | Yes | No | App functionality |
| Customer support | Yes | No | App functionality |

“Health” covers height, weight, goal weight, macro targets, meal history, and
nutrition estimates. “Other user content” covers typed notes, transcripts,
corrections, and generated meal records. Audio is sent for transcription and
should be queued for deletion after the transcript is saved; photos and meal
records remain until the meal or account is deleted. If production retention
differs, fix the service or change both the privacy policy and store disclosure
before release.

The app declares no advertising, cross-app tracking, or third-party analytics.
Do not answer “Data Not Collected”: authenticated meal content and account data
are transmitted off device and retained by the service.

## Required public URLs and in-app access

The current legitimate public URLs are:

- Support URL: `https://shudo.yng.sh/support`
- Marketing URL, if used: `https://shudo.yng.sh`
- Terms: `https://shudo.yng.sh/terms`

Before a public App Store submission, add a separately reviewed privacy-policy
URL that accurately describes production. Do not restore the deleted placeholder
as a shortcut. Terms and Support must return public `200` responses and work on
mobile; `/privacy` should return `404` until a real policy exists.

## App Review notes to prepare

- Shudo estimates nutrition from a voice note, optional photo, and optional
  text. Results can be wrong and are not medical, allergy, or emergency advice.
- Microphone permission is optional: a user can log with text and/or a photo.
- Camera permission is optional: a user can log with voice and/or text.
- The `audio` background mode exists only so a user-initiated meal recording is
  not lost if the screen locks or the app briefly backgrounds. The recording
  indicator remains visible and recording stops at the app's fixed ceiling.
- Account deletion is available in Settings and removes authentication data,
  meals, profile information, and stored media after explicit confirmation.
- No purchases, subscriptions, ads, tracking, or third-party analytics exist in
  the initial release.

## TestFlight and App Store sequence

1. Complete the Apple/Google/Supabase auth configuration and verify email,
   Google, Apple, password recovery, sign-out, and account deletion with test
   accounts.
2. Enable the Apple capability on the permanent App ID, add the matching Xcode
   entitlement, refresh automatic signing, and install that signed build on a
   physical iPhone.
3. Run the complete project release gate, then archive the Release
   configuration. Generate Xcode's privacy report from the archive and compare
   it with the table above and App Store Connect.
4. Validate the archive. Resolve every validation warning before upload.
5. Increment `CURRENT_PROJECT_VERSION` for every subsequent upload. Apple uses
   bundle ID, version, and build string to associate and uniquely identify the
   build.
6. Upload to App Store Connect. Wait for processing, complete export-compliance
   and privacy questions, and add the build to an internal TestFlight group.
7. Friends who are not App Store Connect team members are external testers. The
   first external build of a version requires TestFlight App Review; later
   builds may not require a full review.
8. After the release candidate passes physical-device tests, complete the
   listing and submit the same verified build for App Review.

## Apple references

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Offering account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
- [Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy-manifest-files)
- [Required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Configuring Sign in with Apple](https://developer.apple.com/documentation/xcode/configuring-sign-in-with-apple)
- [Uploading builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [TestFlight](https://developer.apple.com/testflight/)
