# Shudo Web

The small desktop companion and public web surface for Shudo. It provides:

- sign-in for existing accounts;
- timezone-correct daily totals and target progress;
- read-only meal history;
- password-recovery completion; and
- public Terms and Support pages.

Account creation, onboarding, meal capture, corrections, goals, the
adherence heatmap, weekly insights, and account deletion live in the iPhone app.

## Local setup

Use Node.js 24.x:

```bash
cp .env.example .env.local
npm ci
npm run dev
```

Set the public Supabase project URL and publishable key in `.env.local`. Never
put a service-role key or other secret in a `NEXT_PUBLIC_` variable.

## Verification

```bash
npm test
npm run lint
npm run typecheck
npm run build
npm audit --audit-level=moderate
```

The repository-level `scripts/verify-release.zsh` also verifies the Vercel build
and checks that ignored credentials, `.env.local`, dependencies, and build output
cannot enter the upload manifest.

## Vercel

The production project is `shudo` in the `ekuls-projects` team, with
`https://shudo.yng.sh` as its preferred hostname. Its root directory is this
folder and the hosted Root Directory remains `.` because releases start here.
Git integration is optional; authenticated CLI deployment is sufficient. If
the GitHub monorepo is connected later, migrate the hosted Root Directory and
release tooling together instead of changing one side independently.

Configure the two public Supabase variables plus three distinct server-only
secrets:

```dotenv
NEXT_PUBLIC_SUPABASE_URL=...
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=...
CRON_SECRET=...
SHUDO_CLEANUP_SECRET=...
SHUDO_WEEKLY_SECRET=...
```

Each secret must be a different random value of at least 32 characters.
`CRON_SECRET` authenticates the Vercel schedule. The route forwards the cleanup
and weekly credentials only to their matching Supabase functions.

The daily `/api/cron/keepalive` request drains pending media cleanup and
idempotently creates due weekly summaries. Verify it returns `401` without the
exact bearer token and succeeds with the configured Vercel scheduler.

Supabase Auth must allow these production redirects:

- `https://shudo.yng.sh/auth/callback`
- `https://shudo.yng.sh/reset-password`

Keep the corresponding `shudo.vercel.app` URLs only as fallbacks.
