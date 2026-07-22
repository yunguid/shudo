# Shudo

Shudo is a lean, voice-first nutrition log for iPhone. Record what you ate,
optionally add photos or text, and get a streamed meal breakdown with calories
and macros. Pick any day, correct a meal later, adjust goals, and review progress
without turning logging into a questionnaire.

The initial release is intentionally small: one excellent capture flow, a clear
daily view, editable targets, a 12-week adherence heatmap, and one useful weekly
summary.

## Repository

- `shudo/` — SwiftUI iPhone app
- `shudoTests/` and `shudoUITests/` — native tests
- `shudo-web/` — read-only Next.js desktop companion and public auth/policy pages
- `supabase/migrations/` — PostgreSQL schema, RLS, queues, quotas, and RPCs
- `supabase/functions/` — authenticated Edge Functions
- `scripts/verify-release.zsh` — complete local release gate
- `scripts/verify-ios-release.zsh` — iPhone metadata and Release-build gate
- `docs/ios-release-readiness.md` — Apple/TestFlight handoff checklist

## Product flow

1. Create an account in the iPhone app with email/password or a configured
   Apple/Google provider.
2. Describe goals by voice or text, review the proposed profile and daily targets,
   and edit anything before saving.
3. Log a meal with voice, photos, text, or any combination. A stable request ID
   makes retries idempotent, and the saved entry continues processing if the app
   backgrounds.
4. Review daily totals against the target effective on that date. Add context to
   a completed meal to re-estimate it without losing the prior valid result if
   the update fails.
5. Use Settings for profile/target changes, the adherence heatmap, weekly
   insights, password recovery, and account deletion.

The web app signs existing users in and provides a larger read-only history. New
email/password accounts are created in the native app so every user completes
the short onboarding flow.

## Architecture and privacy boundaries

- Supabase Auth, PostgreSQL, private Storage, RLS, and Edge Functions provide the
  backend. The active hosted project is `shudo-2`.
- OpenAI `gpt-4o-transcribe` transcribes voice. `gpt-5.6-sol` produces structured
  meal estimates, onboarding proposals, and weekly summaries with `store: false`.
- OpenAI and Supabase service credentials stay server-side. The apps contain only
  the public Supabase project URL and publishable key.
- Every user-owned row is isolated by RLS. Server-only RPCs are revoked from
  browser roles and invoked by authenticated Edge Functions.
- Capture, onboarding, correction, and weekly work use durable claims, leases,
  idempotency keys, bounded inputs, per-user quotas, and fenced retries.
- Raw audio is detached and queued for deletion after transcription. Photos and
  meal records remain until their meal or account is deleted.
- Account deletion first removes Auth access and database ownership, then drains
  any recoverable Storage cleanup work.

Nutrition output is an estimate, not medical advice. Shudo does not diagnose,
treat, or provide allergy or emergency guidance.

## Local development

Requirements:

- Xcode at `/Applications/Xcode.app`
- Node.js 24.x
- Deno 2.x
- PostgreSQL 17 client/server tools
- Supabase CLI
- Vercel CLI for web deployment verification

Web:

```bash
cd shudo-web
cp .env.example .env.local
npm ci
npm run dev
```

Populate only the two public values in `.env.local` for browser development.
Never place an OpenAI key, service-role key, OAuth secret, or maintenance secret
in a `NEXT_PUBLIC_` variable.

Native:

```bash
open shudo.xcodeproj
```

Select the `shudo` scheme and an iPhone simulator or a trusted registered iPhone.
The app’s public backend configuration lives in `shudo/AppConfig.swift`.

Local Edge Functions copy `supabase/functions/.env.example` to an ignored env
file and receive standard Supabase URL/keys from the local runtime.

## Required hosted secrets

Supabase Edge Function secrets:

```dotenv
OPENAI_API_KEY=...
SHUDO_CLEANUP_SECRET=...
SHUDO_WEEKLY_SECRET=...
```

Vercel server-only environment variables:

```dotenv
CRON_SECRET=...
SHUDO_CLEANUP_SECRET=...
SHUDO_WEEKLY_SECRET=...
```

Generate three different high-entropy maintenance values of at least 32
characters. `CRON_SECRET` protects the Vercel route; the route forwards each
distinct Shudo secret only to its matching Supabase function.

Vercel browser variables:

```dotenv
NEXT_PUBLIC_SUPABASE_URL=https://PROJECT_REF.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
```

## Auth providers and email

Email confirmation and password recovery require a custom SMTP provider before
friends are invited. Google and Apple buttons are driven by live Supabase Auth
settings and remain hidden until their provider is actually enabled, so an
unfinished provider cannot create a dead sign-in path.

Production URLs:

- Site: `https://shudo.yng.sh`
- OAuth callback: `https://shudo.yng.sh/auth/callback`
- Password recovery: `https://shudo.yng.sh/reset-password`
- Native callback: `shudo://auth/callback`

Keep the Vercel hostname redirects as a fallback. Sign in with Apple also needs
the permanent App ID capability and Apple-side provider credentials before the
Xcode entitlement is added.

## Database and Edge deployment

Use the guarded release wrapper from the linked repository root. It is pinned to
Supabase CLI `2.109.1`, reads a mode-`600` file token into the environment, and
never asks macOS Keychain for credentials:

```bash
# One time: browser verification that never touches macOS Keychain.
scripts/login-supabase-no-keyring.zsh

# Inspect the exact migration plan without applying schema or data migrations.
scripts/deploy-supabase-production.zsh

# Apply only the verified migration suffix and deploy the verified functions.
scripts/deploy-supabase-production.zsh --apply
```

The authenticated group is `create_entry`, `correct_entry`, `delete_entry`,
`delete_account`, `process_entry`, `onboard_profile`, `reanalyze_entry`, and
`resume_entry`. Only `drain_storage_cleanup` and `generate_weekly_summaries`
disable gateway JWT verification because they enforce dedicated server secrets.
The wrapper deploys one function at a time, never uses `--prune`, verifies JWT
settings, and runs database advisors. Use only disposable accounts for hosted
release tests; never mutate Luke’s real meal history.

## Scheduled maintenance and free-tier behavior

Vercel calls `/api/cron/keepalive` once daily. The route:

- authenticates Vercel with `CRON_SECRET`;
- drains pending private Storage cleanup with `SHUDO_CLEANUP_SECRET`; and
- idempotently generates due weekly summaries with `SHUDO_WEEKLY_SECRET`.

The external request also keeps a legitimately used Supabase Free project from
sitting completely idle. It is operational maintenance, not a guarantee against
provider policy changes. The initial app should remain within the Free plan for
a small friend group, but usage and OpenAI spend still need monitoring.

## Release verification

Run the complete gate from the repository root:

```bash
scripts/verify-release.zsh
```

The deploy script refuses the wrong linked project, unexpected or modified
migrations, unapproved functions, insecure token-file permissions, missing
functions, and incorrect JWT verification settings. It never prints the access
token or places it in command arguments.

`verify-release.zsh` verifies immutable migration hashes, clean diffs, web tests/lint/typecheck/
production build/audit, safe Vercel upload contents, Deno format/lint/check/tests,
fresh and restored PostgreSQL shapes, and native unit/UI tests with compiler
warnings treated as errors. The focused unsigned device Release check is:

```bash
scripts/verify-ios-release.zsh
```

Before promotion, additionally verify the hosted migration/function inventory,
Supabase security advisors, custom-domain policy/reset pages, cron unauthorized
and authorized responses, email confirmation/recovery, provider sign-in, meal
capture, correction rollback, onboarding, weekly generation, and account deletion
with disposable users.

Direct Xcode installation works with the registered development device and
profile. TestFlight and public distribution require an active Apple Developer
Program team, Apple Distribution signing, an App Store Connect record, completed
privacy/listing details, and a verified physical-iPhone archive.

## Deployment policy

- Production deployment does not require Vercel Git integration; the current
  project can be deployed through the authenticated CLI. Connecting the GitHub
  repository is optional and should be a deliberate account-level choice.
- Never print, commit, or paste recovery codes, API keys, database passwords,
  OAuth secrets, service-role keys, or maintenance credentials into logs.
- Do not rewrite or delete historical migrations after they reach production.
- Take a private database backup before destructive production recovery.
- Keep the retired paused Supabase project intact until the replacement has been
  verified and a fresh backup exists.
