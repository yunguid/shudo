# Shudo

Shudo is a private, voice-first meal log. The iPhone app accepts a long voice
note, an optional meal photo, and optional text, then shows a structured macro
estimate on the user-selected day. `shudo-web` is a read-only desktop history.

## Architecture

- `shudo/` — native SwiftUI iPhone app
- `shudo-web/` — small Next.js/Vercel companion
- `supabase/migrations/` — the complete PostgreSQL, RLS, Storage, and Realtime
  model
- `supabase/functions/` — authenticated capture, processing, resume, delete, and
  cleanup endpoints
- OpenAI `gpt-4o-transcribe` — voice transcription
- OpenAI `gpt-5.6-sol` — structured meal and macro analysis

The phone never receives an OpenAI key or a Supabase service-role key. Captures
are stored before processing, use stable request IDs, and can be reclaimed after
an interrupted worker. Storage deletion uses a private, leased, retryable queue,
so database state is committed before raw audio or replaced/deleted media is
removed. Raw provider responses are not stored, buckets are private, and all
user-facing reads use RLS.

Voice captures use mono AAC at 48 kbps and stop automatically at 15 minutes.
That ceiling is roughly 5.4 MB of encoded audio before small container overhead,
comfortably inside Shudo's 12 MB capture limit and OpenAI's documented 25 MB
transcription upload limit. The processor allows 60 seconds for transcription
and 65 seconds for analysis, preserving 25 seconds of database, Storage, and
dispatch overhead inside the 150-second worker budget.

## Required server configuration

Hosted Edge Functions receive Supabase's standard URL and server keys. Add:

```dotenv
OPENAI_API_KEY=...
SHUDO_OWNER_USER_ID=...
SHUDO_CLEANUP_SECRET=...
```

`SHUDO_OWNER_EMAIL` can be used instead of, or together with, the owner ID.
Functions deliberately fail closed if neither owner guard is configured.
`SHUDO_CLEANUP_SECRET` must be a separately generated high-entropy value of at
least 32 characters. Keep it in Supabase Edge Function secrets and the scheduled
request header; never commit it to source or place the literal value in a
migration. Set Vercel's `CRON_SECRET` to the same value: Vercel authenticates
its daily cron route with that variable, and the route forwards it to the
Supabase cleanup endpoint.

The iOS app's public project URL/key live in `shudo/AppConfig.swift`. The web
app uses the two public variables documented in `shudo-web/.env.example`.

## Restore and deploy order

1. Verify the immutable database and Storage archive hashes against the private
   recovery manifest and run `gzip -t` before making a live connection. Restore
   the database backup into an isolated new Supabase project with PostgreSQL 17
   `psql`, using a direct or session-mode database URI (never the transaction
   pooler). Keep `ON_ERROR_STOP` off for this one full-cluster restore because
   Supabase-managed objects already exist. Capture the complete log privately
   and compare every `ERROR` with the sanitized PostgreSQL 17 signature at
   `/Users/luke/Documents/Shudo Recovery/2026-07-20/restore-expected-errors.md`:
   any new `COPY`, Auth data, application-data, or Storage data error stops the
   cutover. Verify exactly 2 Auth users, 2 identities, 2 profiles, 46 entries,
   and 37 Storage metadata rows. A zero `psql` exit status alone is not proof:
   expected SQL errors do not make it nonzero.
2. Before exposing the project, invalidate every restored legacy session and
   refresh token with the one-off maintenance transaction below. It preserves
   users, identities, and password hashes, so every device must authenticate
   again against the replacement project.
3. Verify the migration file hash against the private recovery manifest, then
   apply `supabase/migrations/20260720221116_rebuild_shudo_core.sql` with
   `ON_ERROR_STOP=1` and `--single-transaction`. Link the CLI explicitly to the
   replacement project, record the manual application in Supabase migration
   history, and require the local and remote versions to match:

   ```bash
   npx --yes supabase@2.109.1 link --project-ref "$SHUDO_PROJECT_REF"
   npx --yes supabase@2.109.1 migration repair 20260720221116 --status applied --linked
   npx --yes supabase@2.109.1 migration list --linked
   ```

   Do not run `db push` until this repair is visible remotely; otherwise the
   already-applied migration may be attempted again.
4. Remove stale restored `storage.objects` metadata, then restore from the
   private archive only the object paths still referenced by the migrated
   entries. Do not re-upload legacy raw audio that the migration detached; keep
   the complete archive secured locally. The recovery-specific manifest and
   credential-free extractor/uploader live beside the private backup, never in
   this repository.
5. Configure the Edge Function secrets. Deploy `create_entry`, `process_entry`,
   `resume_entry`, and `delete_entry` with JWT verification enabled. Deploy
   `drain_storage_cleanup` with JWT verification disabled; that endpoint checks
   the dedicated `x-shudo-cleanup-secret` header itself.
6. In Supabase Cron, schedule an Edge Function POST to `drain_storage_cleanup`
   every fifteen minutes. Set `x-shudo-cleanup-secret` from a protected
   secret/Vault value and use a JSON body such as `{ "limit": 25 }`. Do not
   embed the secret in committed SQL.
7. Keep public signup disabled and email/password sign-in enabled. Select
   `SHUDO_OWNER_USER_ID` from the restored account that owns all 46 entries;
   confirm its identity privately before deleting or changing either restored
   account. A wrong owner ID makes every capture endpoint fail closed.
8. Link/reserve the Vercel project and production hostname. Set
   `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`, and the
   Production-scoped `CRON_SECRET` before the first production build. Deploy
   `shudo-web` with its root directory set to `shudo-web`, but do not yet treat
   the URL as released.
9. Configure hosted Supabase Auth with the exact deployed Site URL and exact
   `/auth/callback` URL, then verify a magic-link login. The checked-in
   `supabase/config.toml` intentionally contains localhost development URLs;
   never blindly push that Auth configuration to the hosted project.
10. Verify both cleanup schedules: a successful fifteen-minute Supabase Cron
    run and the Vercel route returning `401` without its Bearer credential and
    `200` with it. Promote the exact verified Vercel deployment.
11. Point `shudo/AppConfig.swift` at the replacement public project URL/key only
    after the database, media, Auth, functions, advisors, and both cron paths
    are green. The phone is the final client cutover.

### One-off restored Auth credential revocation

Supabase's public admin sign-out API requires a valid user JWT; it has no bulk
"sign out restored user ID" operation. Direct writes to the `auth` schema are
therefore a **one-off vendor-support caveat**, not an application pattern or a
migration. Run this only while the brand-new replacement project is isolated.
If the hosted Auth schema differs from the downloaded backup, stop and ask
Supabase Support instead of adapting the deletes by guesswork.

```sql
begin;

create temporary table shudo_auth_users_before on commit drop as
select id, encrypted_password from auth.users;

create temporary table shudo_auth_identities_before on commit drop as
select id, user_id, provider, identity_data from auth.identities;

-- sessions cascades to session-bound refresh tokens and MFA AMR claims.
delete from auth.sessions;
-- Also remove any legacy refresh token that was not attached to a session.
delete from auth.refresh_tokens;

do $verify$
begin
  if exists (
    (select * from shudo_auth_users_before
     except
     select id, encrypted_password from auth.users)
    union all
    (select id, encrypted_password from auth.users
     except
     select * from shudo_auth_users_before)
  ) then
    raise exception 'Restored users or password hashes changed';
  end if;

  if exists (
    (select * from shudo_auth_identities_before
     except
     select id, user_id, provider, identity_data from auth.identities)
    union all
    (select id, user_id, provider, identity_data from auth.identities
     except
     select * from shudo_auth_identities_before)
  ) then
    raise exception 'Restored identities changed';
  end if;

  if exists (select 1 from auth.sessions)
     or exists (select 1 from auth.refresh_tokens)
     or exists (select 1 from auth.mfa_amr_claims) then
    raise exception 'Legacy Auth credentials remain';
  end if;
end
$verify$;

commit;
```

The downloaded Shudo backup's other transient credential tables (`flow_state`,
`one_time_tokens`, `mfa_challenges`, and `saml_relay_states`) were verified
empty. Recheck them on the hosted restore before cutover; do not delete durable
MFA factors or Auth identities.

## Release anchor and backout

Before live mutation, create a local release-candidate commit and record its
SHA together with the new Supabase project ref, Vercel project/deployment IDs,
and the verified database, Storage, and migration hashes. After hosted restore,
migration, media, Auth, and advisor verification—but before configuring the
phone—capture a private PostgreSQL 17 logical snapshot, set it to mode `600`,
and record its SHA-256 beside the immutable recovery archives. The Storage
archive remains the byte-level media source.

If any integrity check fails before client cutover, do not promote the web app
or install the phone build. Do not attempt a down-migration: keep the failed
project isolated and, only after separate destructive confirmation, rebuild a
fresh replacement from the immutable archives. If a problem appears after the
phone has written new data, first take a fresh private database dump and Storage
inventory before any destructive recovery. The retired paused project is not a
usable rollback target.

## Verification

The SQL fixtures cover a fresh project, RLS isolation, processing and cleanup
lease fencing, transactional media enqueue/detach/delete behavior, and the
legacy restore shape. Edge Functions are checked with Deno.

The reproducible local release gate is `scripts/verify-release.zsh`. It selects
the installed Node 24 runtime, verifies the pinned migration hash, runs the web,
Vercel-manifest, Edge, PostgreSQL 17, and full Xcode test suites, and writes an
`.xcresult` bundle under `/tmp`. Xcode commands explicitly use
`/Applications/Xcode.app/Contents/Developer`, because this machine's global
`xcode-select` still points at Command Line Tools.

After the hosted migration and media upload, verify at minimum:

```sql
select status, count(*) from public.entries group by status order by status;
select
  count(*) filter (where image_path is not null) as image_references,
  count(*) filter (where audio_path is not null) as audio_references
from public.entries;
select bucket, mode, count(*)
from private.storage_cleanup_jobs
group by bucket, mode
order by bucket, mode;
select bucket_id, count(*), sum((metadata ->> 'size')::bigint) as bytes
from storage.objects
where bucket_id in ('entry-images', 'entry-audio')
group by bucket_id
order by bucket_id;
with referenced as (
  select 'entry-images'::text as bucket_id, image_path as object_path
  from public.entries where image_path is not null
  union all
  select 'entry-audio', audio_path
  from public.entries where audio_path is not null
)
select
  (select count(*) from referenced) as references,
  (select count(*) from referenced r
   left join storage.objects o
     on o.bucket_id = r.bucket_id and o.name = r.object_path
   where o.id is null) as missing_objects,
  (select count(*) from storage.objects o
   left join referenced r
     on r.bucket_id = o.bucket_id and r.object_path = o.name
   where o.bucket_id in ('entry-images', 'entry-audio')
     and r.object_path is null) as extra_objects;
select
  (select count(*) from auth.sessions) as sessions,
  (select count(*) from auth.refresh_tokens) as refresh_tokens,
  (select count(*) from auth.mfa_amr_claims) as mfa_amr_claims;
```

The Storage uploader must download and SHA-256-check every remote object, and a
database anti-join must prove there are no missing or extra entry-media paths.
Then verify the four user functions reject missing JWTs, the cleanup function
rejects a missing/wrong cleanup secret, a valid owner capture reaches
`complete`, Supabase Cron records a successful cleanup run, and Vercel records a
successful daily cron response. Run Supabase's security and performance
advisors before client cutover.

Local web commands are:

```bash
cd shudo-web
npm test
npm run lint
npm run typecheck
npm run build
```

The native target and tests are built from `shudo.xcodeproj` once the local
Xcode license and signing team are configured.

## iPhone installation and updates

The supported same-evening installation path is a development build from Xcode,
not TestFlight:

1. Connect the unlocked iPhone to the Mac with USB, tap **Trust**, and enable
   Developer Mode when iOS asks for it.
2. In Xcode Settings > Accounts, add the Apple Account that owns the intended
   development team. In Shudo's Signing & Capabilities settings, keep automatic
   signing enabled and select that team.
3. Open `shudo.xcodeproj`, choose the physical iPhone as the `shudo` run
   destination, and press Run. Do this only after `shudo/AppConfig.swift` has
   been cut over to the verified replacement Supabase project.

After the first signed-in launch, the phone shortcut can be one **URL** action
containing `shudo://capture` followed by **Open URLs**. Adding that Shortcut to
the Home Screen opens Shudo directly into the composer and starts voice capture.

Subsequent Run operations install the new build over the existing app because
the bundle identifier remains `luke.shudo`. Shudo's durable meal data lives in
Supabase, but an update should still be treated as a normal in-place app update;
do not delete the app merely to install a new development build. A Personal Team
is sufficient for development-device installation, though its provisioning is
short-lived and Xcode may need to reinstall the app periodically.

TestFlight is a separate, optional distribution path. It requires an active
Apple Developer Program membership, an App Store Connect app record for the
bundle identifier, a distribution signing identity/profile, and a unique higher
build number for every upload. Builds also undergo Apple processing, so
TestFlight is not the immediate-update path for tonight. If those prerequisites
are available later, archive the Release configuration in Xcode, validate it,
upload it to App Store Connect, and use an internal TestFlight group for the
fastest beta updates.

The Vercel companion is intentionally a live, read-only browser experience. It
is responsive on a phone, but it is not an offline PWA and it cannot replace the
native voice/photo capture flow. Its release is complete only after the
production Supabase variables exist, a magic-link login succeeds, day navigation
and history render against live restored data, and the authenticated cleanup
cron has succeeded.
