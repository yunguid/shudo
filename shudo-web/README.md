# Shudo Web

A private, view-only desktop companion for the Shudo iPhone app. It shows one timezone-correct nutrition day at a time and a paginated history of completed meal entries.

## What it does

- Email magic-link sign-in for an existing Shudo account
- Explicit previous/next-day navigation using `profiles.timezone`
- Daily calorie and macro totals
- Recent seven-day context
- Read-only meal history

New accounts are not created from the web login. Create the owner account in Supabase first and keep public signups disabled.

## Local setup

Requirements: Node.js 24.x and access to the same Supabase project used by the iOS app.

```bash
cp .env.example .env.local
npm ci
npm run dev
```

Fill these public client settings in `.env.local`:

```dotenv
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
```

The legacy `NEXT_PUBLIC_SUPABASE_ANON_KEY` is accepted as a fallback. Never place a service-role key in a `NEXT_PUBLIC_` variable.

## Verification

```bash
npm test
npm run lint
npm run typecheck
npm run build
```

## Vercel

Connect the repository and set the Vercel project Root Directory to `shudo-web`. Add both public Supabase variables to Development, Preview, and Production, then add the deployed `/auth/callback` URL to Supabase Auth redirect URLs.

Generate one random secret of at least 32 characters. Configure it as
`CRON_SECRET` in Vercel and as `SHUDO_CLEANUP_SECRET` in Supabase. The production
deployment invokes `/api/cron/keepalive` once daily; the route verifies Vercel's
bearer secret and relays an idempotent cleanup drain to Supabase. This supplies
an external database request during a quiet week without exposing a public
database health function. It supplements the fifteen-minute Supabase cleanup
schedule and stays within Vercel Hobby's once-daily cron limit.

The Vercel project is linked only through ignored local `.vercel/` metadata; no
deployment credentials or project identifiers are committed.
