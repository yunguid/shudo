# Shudo morning handoff

Updated: 2026-07-23 (overnight performance/polish run)

## Overnight run (2026-07-23)

An autonomous overnight pass landed capture-latency, image-caching, backend,
web, and UI-polish improvements on `main` (see `docs/overnight-audit.md` for
the full evidence, tradeoffs, and rejected ideas). Key user-visible changes:

- Tapping **Log meal** no longer stalls while photos are collaged/encoded;
  photo preparation happens in the background as you pick.
- Meal thumbnails and detail photos no longer flash back to placeholders on
  refresh/foreground — signed URLs are cached and reused.
- Faster durable acceptance for photo+voice captures (uploads parallelized,
  auth overlapped) and slightly faster processing start.
- Settings loads its sections in parallel; heatmap/trends render cheaper.
- Design-system radius/hairline unification, Reduce Motion and Dynamic Type
  fixes, 44 pt touch targets, VoiceOver labels on calorie/photo elements.
- Web dashboard fetches fewer/lighter queries; login card no longer pops in
  provider buttons; public pages regained their card background.

**Deployment needed to activate backend/web changes** (not done overnight,
per guardrails):

1. `scripts/deploy-supabase-production.zsh` then `--apply` — Edge Function
   updates only (create_entry, process_entry, correct_entry, onboard_profile,
   delete_account, drain_storage_cleanup, generate_weekly_summaries shared
   modules). **No new migration was added**; schema is unchanged.
2. `scripts/deploy-vercel-production.zsh` then `--apply` — web companion.

The native app changes are already in the Release build installed on the
phone (if the overnight install step succeeded; see the final summary).

## Ready now

- Shudo 1.0 (2) is signed, installed, and verified running on Luke's iPhone.
- A second signed Release build passed without a Keychain password prompt.
- Future signed updates use `scripts/install-ios-device.zsh`; it builds,
  installs, launches, and verifies the connected phone in one command.
- The replacement Personal Team profile is active through 2026-07-29 00:05 EST.
- Supabase and Vercel production releases are live at `https://shudo.yng.sh`.
- The complete release gate passed and `agent/rebuild-shudo` is published to
  `github.com/yunguid/shudo`.
- OpenAI, Supabase CLI, Vercel, cron, database, storage, and device-signing
  credentials are already configured. Luke does not need to provide them again.

## Information or decisions still needed from Luke

1. **Friend beta emails**
   - Send the exact email address for each friend who should be allowed to make
     an account.
   - Only `luke@yng.sh` is currently admitted. The database blocks every other
     signup before it can consume shared AI capacity.

2. **Google OAuth owner**
   - Say which Google account should own Shudo's OAuth client.
   - When prompted, Luke should complete that account's sign-in or MFA himself;
     no Google password needs to be pasted into chat.
   - The prepared configuration uses these production values:
     - origins: `https://shudo.yng.sh` and `https://shudo.vercel.app`
     - redirect URI: `https://fjfashsjrajtdilxhcbn.supabase.co/auth/v1/callback`

3. **Transactional email sender**
   - Approve a provider and sender address for confirmation and password-reset
     messages. Recommended lean default: a free Resend account with
     `Shudo <hello@shudo.yng.sh>`.
   - Luke will need to approve the provider login and DNS verification. Codex
     can configure the DNS records and install the generated SMTP credential in
     Supabase without printing it.

4. **Apple distribution choice**
   - Decide whether to enroll the existing Apple account in the paid Apple
     Developer Program. Paid membership is required for TestFlight, practical
     friend distribution, a permanent App ID, and Sign in with Apple.
   - Without it, the current Luke-only build works but must be re-signed about
     every seven days; Apple login remains hidden.

5. **Only if proceeding to TestFlight/App Store**
   - Approve the honest privacy facts and listing choices: app name/subtitle,
     Health & Fitness category, age-rating answers, screenshots, countries, and
     free pricing.
   - The invented placeholder privacy page remains deleted. A real policy should
     only be published after Luke reviews its factual claims.

## Passwords not needed

Do not send a Mac password, old Keychain password, Apple password, Google
password, Supabase password, Vercel password, or OpenAI key. The remaining work
uses existing secure sessions or a brief owner-controlled login/MFA handoff.

## Fast morning acceptance check

1. Open Shudo and confirm the Today screen and Settings load normally.
2. Record a short meal, optionally attach one photo, and wait for the streamed
   result.
3. Add a correction to that meal and confirm its totals update.
4. Switch to yesterday and back to today.
5. Edit a daily target and confirm the current-versus-target totals change.

Password-recovery email and Google sign-in should be tested only after their two
external providers above are configured.
