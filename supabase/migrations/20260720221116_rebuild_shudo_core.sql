-- Shudo's complete, reproducible data model.
-- Safe for a fresh Supabase project and additive when applied after restoring the
-- legacy dashboard backup.

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated, service_role;

-- The legacy dashboard dump granted every future postgres-owned public table,
-- sequence, and function to Data API roles. Reset the app creator's defaults
-- before creating replacements; Supabase's internal supabase_admin defaults
-- are platform-managed and deliberately left untouched.
alter default privileges for role postgres in schema public
  revoke all on tables from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke all on sequences from public, anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke all on functions from public, anon, authenticated, service_role;

-- Remove the denormalized legacy surfaces before reshaping restored tables.
drop view if exists public.today_status;
drop view if exists public.day_totals;
drop view if exists public.daily_totals;
drop table if exists public.daily_summaries cascade;
drop table if exists public.macro_plans cascade;
drop table if exists public.entry_items cascade;
drop function if exists public.entries_set_local_date() cascade;
drop function if exists public.local_date_for_user(uuid, timestamptz) cascade;
drop function if exists public.refresh_daily_summaries() cascade;
drop function if exists public.set_timestamp_updated_at() cascade;

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  timezone text not null default 'UTC',
  units text not null default 'imperial',
  daily_macro_target jsonb not null default '{"calories_kcal":2200,"protein_g":150,"carbs_g":250,"fat_g":70}'::jsonb,
  height_cm numeric(6,2),
  weight_kg numeric(6,2),
  target_weight_kg numeric(6,2),
  activity_level text,
  cutoff_time_local time not null default '20:00',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles add column if not exists timezone text not null default 'UTC';
alter table public.profiles add column if not exists units text not null default 'imperial';
alter table public.profiles add column if not exists daily_macro_target jsonb not null default '{"calories_kcal":2200,"protein_g":150,"carbs_g":250,"fat_g":70}'::jsonb;
alter table public.profiles add column if not exists height_cm numeric(6,2);
alter table public.profiles add column if not exists weight_kg numeric(6,2);
alter table public.profiles add column if not exists target_weight_kg numeric(6,2);
alter table public.profiles add column if not exists activity_level text;
alter table public.profiles add column if not exists cutoff_time_local time not null default '20:00';
alter table public.profiles add column if not exists created_at timestamptz not null default now();
alter table public.profiles add column if not exists updated_at timestamptz not null default now();

-- Normalize the legacy profile shape so a restored project and a fresh project
-- finish with the same defaults and constraints.
update public.profiles
set cutoff_time_local = coalesce(cutoff_time_local, '20:00'::time),
    daily_macro_target = coalesce(
      daily_macro_target,
      '{"calories_kcal":2200,"protein_g":150,"carbs_g":250,"fat_g":70}'::jsonb
    );
alter table public.profiles alter column height_cm type numeric(6,2) using height_cm::numeric;
alter table public.profiles alter column cutoff_time_local set default '20:00';
alter table public.profiles alter column cutoff_time_local set not null;
alter table public.profiles alter column daily_macro_target
  set default '{"calories_kcal":2200,"protein_g":150,"carbs_g":250,"fat_g":70}'::jsonb;
alter table public.profiles drop column if exists goal;

create table if not exists public.entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  client_request_id uuid not null default gen_random_uuid(),
  local_day date not null,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  processed_at timestamptz,
  timezone_snapshot text not null default 'UTC',
  status text not null default 'queued',
  status_message text not null default 'Queued',
  title text,
  input_text text,
  transcript text,
  raw_text text,
  intended_image boolean not null default false,
  intended_audio boolean not null default false,
  image_path text,
  audio_path text,
  protein_g numeric(8,1) not null default 0,
  carbs_g numeric(8,1) not null default 0,
  fat_g numeric(8,1) not null default 0,
  calories_kcal numeric(9,1) not null default 0,
  confidence numeric(4,3),
  items jsonb not null default '[]'::jsonb,
  analysis_notes text,
  error_message text,
  processing_attempts smallint not null default 0,
  lease_expires_at timestamptz,
  upload_token uuid,
  provider_response_id text,
  analysis_model text,
  transcription_model text
);

-- Columns required by the new app when this migration follows a legacy restore.
alter table public.entries add column if not exists local_day date;
alter table public.entries add column if not exists client_request_id uuid not null default gen_random_uuid();
-- Keep this nullable until legacy rows are backfilled from their original
-- timestamps. A non-null `now()` default here would rewrite restored history.
alter table public.entries add column if not exists occurred_at timestamptz;
alter table public.entries add column if not exists created_at timestamptz not null default now();
alter table public.entries add column if not exists updated_at timestamptz not null default now();
alter table public.entries add column if not exists processed_at timestamptz;
alter table public.entries add column if not exists timezone_snapshot text not null default 'UTC';
alter table public.entries add column if not exists status text not null default 'queued';
alter table public.entries add column if not exists status_message text not null default 'Queued';
alter table public.entries add column if not exists title text;
alter table public.entries add column if not exists input_text text;
alter table public.entries add column if not exists transcript text;
alter table public.entries add column if not exists raw_text text;
alter table public.entries add column if not exists intended_image boolean;
alter table public.entries add column if not exists intended_audio boolean;
alter table public.entries add column if not exists image_path text;
alter table public.entries add column if not exists audio_path text;
alter table public.entries add column if not exists protein_g numeric(8,1) not null default 0;
alter table public.entries add column if not exists carbs_g numeric(8,1) not null default 0;
alter table public.entries add column if not exists fat_g numeric(8,1) not null default 0;
alter table public.entries add column if not exists calories_kcal numeric(9,1) not null default 0;
alter table public.entries add column if not exists confidence numeric(4,3);
alter table public.entries add column if not exists items jsonb not null default '[]'::jsonb;
alter table public.entries add column if not exists analysis_notes text;
alter table public.entries add column if not exists error_message text;
alter table public.entries add column if not exists processing_attempts smallint not null default 0;
alter table public.entries add column if not exists lease_expires_at timestamptz;
alter table public.entries add column if not exists upload_token uuid;
alter table public.entries add column if not exists provider_response_id text;
alter table public.entries add column if not exists analysis_model text;
alter table public.entries add column if not exists transcription_model text;
-- Temporarily normalize this legacy flag so the data-copy statement below can
-- safely run on both a restored schema and a fresh project. It is dropped once
-- any durable voice transcript has been preserved.
alter table public.entries add column if not exists has_audio boolean;
alter table public.entries add column if not exists has_image boolean;
alter table public.entries add column if not exists error_msg text;
alter table public.entries add column if not exists model_output jsonb;

-- The legacy backup generated local_day from created_at. Historical logging now
-- requires an explicitly editable day selected by the user.
alter table public.entries alter column local_day drop expression if exists;

-- Flatten the small amount of useful legacy data into the durable columns above,
-- then remove flags and raw provider blobs that the rebuilt app no longer uses.
alter table public.entries drop constraint if exists entries_status_check;

update public.entries
set status = case status
  when 'pending' then 'failed'
  when 'processing' then 'failed'
  when 'error' then 'failed'
  else status
end;

update public.entries
set occurred_at = coalesce(occurred_at, created_at, now()),
    local_day = coalesce(
      local_day,
      (coalesce(occurred_at, created_at, now()) at time zone coalesce(timezone_snapshot, 'UTC'))::date
    ),
    title = coalesce(nullif(title, ''), nullif(split_part(coalesce(raw_text, ''), E'\n', 1), ''), 'Meal'),
    input_text = coalesce(
      nullif(input_text, ''),
      case
        when not coalesce(has_audio, false) then nullif(raw_text, '')
      end
    ),
    transcript = coalesce(
      nullif(transcript, ''),
      case
        when coalesce(has_audio, false) then nullif(raw_text, '')
      end
    ),
    intended_image = coalesce(intended_image, false)
      or coalesce(has_image, false)
      or image_path is not null,
    intended_audio = coalesce(intended_audio, false)
      or coalesce(has_audio, false)
      or audio_path is not null
      or nullif(btrim(transcript), '') is not null,
    error_message = coalesce(
      error_message,
      error_msg,
      case
        when status = 'failed'
          then 'This meal did not finish before the old project paused. Delete it or log it again.'
      end
    ),
    protein_g = coalesce(protein_g, 0),
    carbs_g = coalesce(carbs_g, 0),
    fat_g = coalesce(fat_g, 0),
    calories_kcal = coalesce(calories_kcal, 0),
    items = case
      when jsonb_typeof(model_output #> '{parsed,items}') = 'array' then (
        select coalesce(
          jsonb_agg(
            jsonb_build_object(
              'name', coalesce(nullif(legacy_item ->> 'name', ''), 'Meal item'),
              'amount', coalesce(
                nullif(legacy_item ->> 'serving_size', ''),
                nullif(concat_ws(' ', legacy_item ->> 'quantity', legacy_item ->> 'unit'), ''),
                'Estimated serving'
              ),
              'protein_g', coalesce((legacy_item #>> '{macros,protein_g}')::numeric, 0),
              'carbs_g', coalesce(
                (legacy_item #>> '{macros,carbs_g}')::numeric,
                (legacy_item #>> '{macros,carbohydrates_g}')::numeric,
                0
              ),
              'fat_g', coalesce((legacy_item #>> '{macros,fat_g}')::numeric, 0),
              'calories_kcal', coalesce(
                (legacy_item ->> 'calories_kcal')::numeric,
                (legacy_item #>> '{macros,calories_kcal}')::numeric,
                0
              ),
              'confidence', coalesce((legacy_item ->> 'confidence')::numeric, confidence, 0.5)
            )
          ),
          '[]'::jsonb
        )
        from jsonb_array_elements(model_output #> '{parsed,items}') as legacy_item
      )
      else items
    end,
    analysis_notes = coalesce(
      nullif(analysis_notes, ''),
      nullif(model_output #>> '{parsed,notes}', '')
    ),
    provider_response_id = coalesce(
      provider_response_id,
      nullif(model_output #>> '{raw_json,id}', '')
    ),
    analysis_model = coalesce(
      analysis_model,
      nullif(model_output #>> '{raw_json,model}', '')
    ),
    status_message = case
      when status = 'complete' then 'Ready'
      when status = 'failed' then 'Needs attention'
      else coalesce(nullif(status_message, ''), 'Queued')
    end
where true;

alter table public.entries drop column if exists error_msg;
alter table public.entries drop column if exists client_submitted_at;
alter table public.entries drop column if exists has_audio;
alter table public.entries drop column if exists has_image;
alter table public.entries drop column if exists has_text;
alter table public.entries drop column if exists image_sha256;
alter table public.entries drop column if exists dedupe_hash;
alter table public.entries drop column if exists model_output;

alter table public.entries alter column local_day set not null;
alter table public.entries alter column intended_image set default false;
alter table public.entries alter column intended_image set not null;
alter table public.entries alter column intended_audio set default false;
alter table public.entries alter column intended_audio set not null;
alter table public.entries alter column occurred_at set default now();
alter table public.entries alter column occurred_at set not null;
alter table public.entries alter column status set default 'queued';
alter table public.entries alter column protein_g type numeric(8,1) using protein_g::numeric;
alter table public.entries alter column protein_g set default 0;
alter table public.entries alter column protein_g set not null;
alter table public.entries alter column carbs_g type numeric(8,1) using carbs_g::numeric;
alter table public.entries alter column carbs_g set default 0;
alter table public.entries alter column carbs_g set not null;
alter table public.entries alter column fat_g type numeric(8,1) using fat_g::numeric;
alter table public.entries alter column fat_g set default 0;
alter table public.entries alter column fat_g set not null;
alter table public.entries alter column calories_kcal type numeric(9,1) using calories_kcal::numeric;
alter table public.entries alter column calories_kcal set default 0;
alter table public.entries alter column calories_kcal set not null;

alter table public.entries
  add constraint entries_status_check
  check (status in ('queued', 'transcribing', 'analyzing', 'complete', 'failed', 'deleting'));

alter table public.entries drop constraint if exists entries_processing_attempts_range;
alter table public.entries
  add constraint entries_processing_attempts_range
  check (processing_attempts between 0 and 3);

alter table public.entries drop constraint if exists entries_macros_nonnegative;
alter table public.entries
  add constraint entries_macros_nonnegative
  check (protein_g >= 0 and carbs_g >= 0 and fat_g >= 0 and calories_kcal >= 0);

alter table public.entries drop constraint if exists entries_confidence_range;
alter table public.entries
  add constraint entries_confidence_range
  check (confidence is null or (confidence >= 0 and confidence <= 1));

alter table public.profiles drop constraint if exists profiles_units_check;
alter table public.profiles
  add constraint profiles_units_check check (units in ('imperial', 'metric'));

alter table public.profiles drop constraint if exists profiles_activity_level_check;
alter table public.profiles
  add constraint profiles_activity_level_check
  check (
    activity_level is null
    or activity_level in ('sedentary', 'light', 'moderate', 'active', 'extra_active')
  );

create index if not exists entries_user_day_occurred_idx
  on public.entries (user_id, local_day, occurred_at desc, id desc);

create unique index if not exists entries_user_client_request_idx
  on public.entries (user_id, client_request_id);

create index if not exists entries_user_inflight_idx
  on public.entries (user_id, updated_at desc)
  where status in ('queued', 'transcribing', 'analyzing');

-- Storage is external to Postgres, so object deletion cannot participate in the
-- transaction that detaches or deletes an entry. Keep the intent in a private,
-- durable outbox and let the service-role cleanup worker perform the remote
-- operation after commit.
create table if not exists private.storage_cleanup_jobs (
  id uuid primary key default gen_random_uuid(),
  bucket text not null,
  mode text not null,
  object_path text not null,
  not_before timestamptz not null default now(),
  attempts integer not null default 0,
  lease_token uuid,
  lease_expires_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint storage_cleanup_jobs_bucket_check
    check (bucket in ('entry-images', 'entry-audio')),
  constraint storage_cleanup_jobs_mode_check
    check (mode in ('object', 'prefix')),
  constraint storage_cleanup_jobs_path_check
    check (
      object_path = btrim(object_path)
      and object_path <> ''
      and left(object_path, 1) <> '/'
      and object_path !~ '(^|/)\.\.(/|$)'
      and (
        (mode = 'prefix' and right(object_path, 1) = '/')
        or (mode = 'object' and right(object_path, 1) <> '/')
      )
    ),
  constraint storage_cleanup_jobs_attempts_check check (attempts >= 0),
  constraint storage_cleanup_jobs_lease_check
    check ((lease_token is null) = (lease_expires_at is null))
);

create unique index if not exists storage_cleanup_jobs_target_idx
  on private.storage_cleanup_jobs (bucket, mode, object_path);

create index if not exists storage_cleanup_jobs_due_idx
  on private.storage_cleanup_jobs (not_before, created_at)
  where lease_token is null;

create index if not exists storage_cleanup_jobs_expired_lease_idx
  on private.storage_cleanup_jobs (lease_expires_at, not_before, created_at)
  where lease_token is not null;

revoke all on table private.storage_cleanup_jobs
  from public, anon, authenticated, service_role;

create or replace function private.enqueue_storage_cleanup_job(
  p_bucket text,
  p_mode text,
  p_object_path text,
  p_not_before timestamptz default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  queued_id uuid;
begin
  if p_bucket not in ('entry-images', 'entry-audio') then
    raise exception using
      errcode = '22023',
      message = 'Unsupported Storage cleanup bucket';
  end if;
  if p_mode not in ('object', 'prefix') then
    raise exception using
      errcode = '22023',
      message = 'Unsupported Storage cleanup mode';
  end if;
  if p_object_path is null
    or p_object_path = ''
    or p_object_path <> btrim(p_object_path)
    or left(p_object_path, 1) = '/'
    or p_object_path ~ '(^|/)\.\.(/|$)'
    or (p_mode = 'prefix' and right(p_object_path, 1) <> '/')
    or (p_mode = 'object' and right(p_object_path, 1) = '/') then
    raise exception using
      errcode = '22023',
      message = 'Invalid Storage cleanup path';
  end if;

  insert into private.storage_cleanup_jobs as cleanup_job (
    bucket,
    mode,
    object_path,
    not_before
  )
  values (
    p_bucket,
    p_mode,
    p_object_path,
    coalesce(p_not_before, now())
  )
  on conflict (bucket, mode, object_path) do update
  set not_before = least(cleanup_job.not_before, excluded.not_before),
      updated_at = now()
  returning cleanup_job.id into queued_id;

  return queued_id;
end;
$$;

revoke all on function private.enqueue_storage_cleanup_job(text, text, text, timestamptz)
  from public, anon, authenticated, service_role;

drop function if exists public.enqueue_storage_cleanup(text, text, text, timestamptz);
create function public.enqueue_storage_cleanup(
  p_bucket text,
  p_mode text,
  p_object_path text,
  p_not_before timestamptz default null
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select private.enqueue_storage_cleanup_job(
    p_bucket,
    p_mode,
    p_object_path,
    p_not_before
  );
$$;

revoke all on function public.enqueue_storage_cleanup(text, text, text, timestamptz)
  from public, anon, authenticated;
grant execute on function public.enqueue_storage_cleanup(text, text, text, timestamptz)
  to service_role;

drop function if exists public.claim_storage_cleanup(integer, integer);
create function public.claim_storage_cleanup(
  p_limit integer default 10,
  p_lease_seconds integer default 120
)
returns table (
  id uuid,
  bucket text,
  mode text,
  object_path text,
  lease_token uuid,
  attempts integer
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception using
      errcode = '22023',
      message = 'Cleanup claim limit must be between 1 and 100';
  end if;
  if p_lease_seconds is null or p_lease_seconds < 30 or p_lease_seconds > 300 then
    raise exception using
      errcode = '22023',
      message = 'Cleanup lease must be between 30 and 300 seconds';
  end if;

  return query
  with eligible as (
    select cleanup_job.id as job_id
    from private.storage_cleanup_jobs as cleanup_job
    where cleanup_job.not_before <= now()
      and (
        (
          cleanup_job.lease_token is null
          and cleanup_job.lease_expires_at is null
        )
        or (
          cleanup_job.lease_token is not null
          and cleanup_job.lease_expires_at < now()
        )
      )
    order by cleanup_job.not_before, cleanup_job.created_at, cleanup_job.id
    for update of cleanup_job skip locked
    limit p_limit
  ), claimed as (
    update private.storage_cleanup_jobs as cleanup_job
    set lease_token = gen_random_uuid(),
        lease_expires_at = now() + make_interval(secs => p_lease_seconds),
        attempts = cleanup_job.attempts + 1,
        updated_at = now()
    from eligible
    where cleanup_job.id = eligible.job_id
    returning
      cleanup_job.id as claimed_id,
      cleanup_job.bucket as claimed_bucket,
      cleanup_job.mode as claimed_mode,
      cleanup_job.object_path as claimed_object_path,
      cleanup_job.lease_token as claimed_lease_token,
      cleanup_job.attempts as claimed_attempts
  )
  select
    claimed.claimed_id,
    claimed.claimed_bucket,
    claimed.claimed_mode,
    claimed.claimed_object_path,
    claimed.claimed_lease_token,
    claimed.claimed_attempts
  from claimed;
end;
$$;

revoke all on function public.claim_storage_cleanup(integer, integer)
  from public, anon, authenticated;
grant execute on function public.claim_storage_cleanup(integer, integer)
  to service_role;

drop function if exists public.complete_storage_cleanup(uuid, uuid);
create function public.complete_storage_cleanup(
  p_job_id uuid,
  p_lease_token uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  removed_count integer;
begin
  delete from private.storage_cleanup_jobs
  where id = p_job_id
    and lease_token = p_lease_token;
  get diagnostics removed_count = row_count;
  return removed_count = 1;
end;
$$;

revoke all on function public.complete_storage_cleanup(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.complete_storage_cleanup(uuid, uuid)
  to service_role;

drop function if exists public.fail_storage_cleanup(uuid, uuid, text);
create function public.fail_storage_cleanup(
  p_job_id uuid,
  p_lease_token uuid,
  p_error_message text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  failed_count integer;
begin
  update private.storage_cleanup_jobs as cleanup_job
  set not_before = now() + make_interval(
        secs => least(
          3600,
          (
            15 * power(
              2::numeric,
              least(greatest(cleanup_job.attempts - 1, 0), 8)
            )
          )::integer
        )
      ),
      lease_token = null,
      lease_expires_at = null,
      last_error = left(
        coalesce(nullif(btrim(p_error_message), ''), 'Storage cleanup failed'),
        500
      ),
      updated_at = now()
  where cleanup_job.id = p_job_id
    and cleanup_job.lease_token = p_lease_token;
  get diagnostics failed_count = row_count;
  return failed_count = 1;
end;
$$;

revoke all on function public.fail_storage_cleanup(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.fail_storage_cleanup(uuid, uuid, text)
  to service_role;

-- Legacy captures kept their raw recording even after the transcript or final
-- nutrition result was durable. Preserve raw_text as transcript above, then
-- atomically detach those no-longer-needed recordings into the cleanup outbox.
-- Audio without any durable text/result stays attached so it can be retried.
with detachable_audio as materialized (
  select entry.id, entry.audio_path
  from public.entries as entry
  where entry.audio_path is not null
    and (
      entry.status = 'complete'
      or nullif(btrim(entry.transcript), '') is not null
    )
  for update of entry
), queued_audio as (
  insert into private.storage_cleanup_jobs as cleanup_job (
    bucket,
    mode,
    object_path,
    not_before
  )
  select
    'entry-audio',
    'object',
    distinct_paths.audio_path,
    now()
  from (
    select distinct detachable_audio.audio_path
    from detachable_audio
  ) as distinct_paths
  on conflict (bucket, mode, object_path) do update
  set not_before = least(cleanup_job.not_before, excluded.not_before),
      updated_at = now()
  returning object_path
)
update public.entries as entry
set audio_path = null
from detachable_audio
where entry.id = detachable_audio.id
  and exists (
    select 1
    from queued_audio
    where queued_audio.object_path = detachable_audio.audio_path
  );

create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function private.set_updated_at()
  from public, anon, authenticated, service_role;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function private.set_updated_at();

drop trigger if exists entries_set_updated_at on public.entries;
create trigger entries_set_updated_at
before update on public.entries
for each row execute function private.set_updated_at();

create or replace function private.ensure_entry_local_day()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.occurred_at is null then
    new.occurred_at = now();
  end if;
  if new.local_day is null then
    new.local_day = (new.occurred_at at time zone coalesce(new.timezone_snapshot, 'UTC'))::date;
  end if;
  return new;
end;
$$;

revoke all on function private.ensure_entry_local_day()
  from public, anon, authenticated, service_role;

drop trigger if exists entries_ensure_local_day on public.entries;
create trigger entries_ensure_local_day
before insert on public.entries
for each row execute function private.ensure_entry_local_day();

create or replace function private.enqueue_entry_upload_prefixes(
  p_user_id uuid,
  p_entry_id uuid,
  p_upload_token uuid,
  p_not_before timestamptz
)
returns void
language plpgsql
set search_path = ''
as $$
declare
  stale_prefix text;
begin
  stale_prefix := p_user_id::text || '/' || p_entry_id::text || '/'
    || p_upload_token::text || '/';
  perform private.enqueue_storage_cleanup_job(
    'entry-images',
    'prefix',
    stale_prefix,
    p_not_before
  );
  perform private.enqueue_storage_cleanup_job(
    'entry-audio',
    'prefix',
    stale_prefix,
    p_not_before
  );
end;
$$;

revoke all on function private.enqueue_entry_upload_prefixes(uuid, uuid, uuid, timestamptz)
  from public, anon, authenticated, service_role;

-- Reserve a queued/failed entry while its request body is being copied into
-- private Storage. A replacement claim fences the old worker and durably
-- schedules its token-scoped staging prefix for cleanup after a grace period.
drop function if exists public.claim_entry_upload(uuid, uuid);
create function public.claim_entry_upload(
  p_entry_id uuid,
  p_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  stale_token uuid;
  claimed_token uuid;
begin
  select entry.upload_token
  into stale_token
  from public.entries as entry
  where entry.id = p_entry_id
    and entry.user_id = p_user_id
    and entry.processing_attempts < 3
    and entry.status in ('queued', 'failed')
    and coalesce(entry.lease_expires_at, '-infinity'::timestamptz) < now()
  for update of entry;

  if not found then
    return null;
  end if;

  if stale_token is not null then
    perform private.enqueue_entry_upload_prefixes(
      p_user_id,
      p_entry_id,
      stale_token,
      now() + interval '5 minutes'
    );
  end if;

  claimed_token := gen_random_uuid();
  update public.entries
  set upload_token = claimed_token,
      lease_expires_at = now() + interval '60 seconds',
      status = 'queued',
      status_message = 'Uploading',
      error_message = null
  where id = p_entry_id
    and user_id = p_user_id;

  return claimed_token;
end;
$$;

revoke all on function public.claim_entry_upload(uuid, uuid) from public, anon, authenticated;
grant execute on function public.claim_entry_upload(uuid, uuid) to service_role;

-- Publish the paths only for the current upload token. Replaced live objects
-- are detached and enqueued in the same transaction, so a failed remote delete
-- can never strand an object without durable retry state.
drop function if exists public.publish_entry_upload(uuid, uuid, uuid, date, text, text, text, text);
create function public.publish_entry_upload(
  p_entry_id uuid,
  p_user_id uuid,
  p_upload_token uuid,
  p_local_day date,
  p_timezone_snapshot text,
  p_input_text text,
  p_image_path text,
  p_audio_path text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  entry_row public.entries%rowtype;
  upload_prefix text;
begin
  select entry.*
  into entry_row
  from public.entries as entry
  where entry.id = p_entry_id
    and entry.user_id = p_user_id
    and entry.status = 'queued'
    and entry.upload_token = p_upload_token
  for update of entry;

  if not found then
    return false;
  end if;
  if p_local_day is null
    or p_timezone_snapshot is null
    or btrim(p_timezone_snapshot) = '' then
    raise exception using
      errcode = '22023',
      message = 'Upload publication requires a day and timezone';
  end if;

  upload_prefix := p_user_id::text || '/' || p_entry_id::text || '/'
    || p_upload_token::text || '/';
  if p_image_path is not null
    and p_image_path is distinct from entry_row.image_path
    and left(p_image_path, length(upload_prefix)) <> upload_prefix then
    raise exception using
      errcode = '22023',
      message = 'Image path is outside the active upload prefix';
  end if;
  if p_audio_path is not null
    and p_audio_path is distinct from entry_row.audio_path
    and left(p_audio_path, length(upload_prefix)) <> upload_prefix then
    raise exception using
      errcode = '22023',
      message = 'Audio path is outside the active upload prefix';
  end if;
  if entry_row.intended_image <> (p_image_path is not null) then
    raise exception using
      errcode = '22023',
      message = 'Published image does not match the original capture';
  end if;
  if entry_row.intended_audio
    and p_audio_path is null
    and nullif(btrim(entry_row.transcript), '') is null then
    raise exception using
      errcode = '22023',
      message = 'Published audio does not match the original capture';
  end if;
  if not entry_row.intended_audio and p_audio_path is not null then
    raise exception using
      errcode = '22023',
      message = 'Published audio does not match the original capture';
  end if;

  if entry_row.image_path is not null
    and entry_row.image_path is distinct from p_image_path then
    perform private.enqueue_storage_cleanup_job(
      'entry-images',
      'object',
      entry_row.image_path,
      now()
    );
  end if;
  if entry_row.audio_path is not null
    and entry_row.audio_path is distinct from p_audio_path then
    perform private.enqueue_storage_cleanup_job(
      'entry-audio',
      'object',
      entry_row.audio_path,
      now()
    );
  end if;

  update public.entries
  set local_day = p_local_day,
      timezone_snapshot = p_timezone_snapshot,
      input_text = p_input_text,
      raw_text = p_input_text,
      transcript = case
        when p_audio_path is distinct from entry_row.audio_path then null
        else entry_row.transcript
      end,
      image_path = p_image_path,
      audio_path = p_audio_path,
      status = 'queued',
      status_message = 'Queued',
      error_message = null,
      lease_expires_at = null,
      upload_token = null,
      transcription_model = case
        when p_audio_path is distinct from entry_row.audio_path then null
        else entry_row.transcription_model
      end
  where id = p_entry_id
    and user_id = p_user_id
    and upload_token = p_upload_token;

  return true;
end;
$$;

revoke all on function public.publish_entry_upload(uuid, uuid, uuid, date, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.publish_entry_upload(uuid, uuid, uuid, date, text, text, text, text)
  to service_role;

-- A caught upload error is allowed to terminalize the still-current token even
-- before its lease expires. Token-scoped staging is retained for five minutes
-- so a losing request cannot race an in-flight Storage write.
drop function if exists public.fail_entry_upload(uuid, uuid, uuid, text);
create function public.fail_entry_upload(
  p_entry_id uuid,
  p_user_id uuid,
  p_upload_token uuid,
  p_error_message text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  locked_id uuid;
begin
  select entry.id
  into locked_id
  from public.entries as entry
  where entry.id = p_entry_id
    and entry.user_id = p_user_id
    and entry.status = 'queued'
    and entry.upload_token = p_upload_token
  for update of entry;

  if not found then
    return false;
  end if;

  perform private.enqueue_entry_upload_prefixes(
    p_user_id,
    p_entry_id,
    p_upload_token,
    now() + interval '5 minutes'
  );
  update public.entries
  set status = 'failed',
      status_message = 'Upload interrupted',
      error_message = left(
        coalesce(nullif(btrim(p_error_message), ''), 'Upload failed'),
        500
      ),
      lease_expires_at = null,
      upload_token = null
  where id = locked_id;

  return true;
end;
$$;

revoke all on function public.fail_entry_upload(uuid, uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.fail_entry_upload(uuid, uuid, uuid, text)
  to service_role;

-- Repair transitions use database time and compare-and-set tokens so a client
-- with a skewed clock cannot terminate a live upload or final processing try.
drop function if exists public.fail_stale_entry_upload(uuid, uuid, uuid);
create function public.fail_stale_entry_upload(
  p_entry_id uuid,
  p_user_id uuid,
  p_upload_token uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  locked_id uuid;
begin
  select entry.id
  into locked_id
  from public.entries as entry
  where entry.id = p_entry_id
    and entry.user_id = p_user_id
    and entry.status = 'queued'
    and entry.upload_token = p_upload_token
    and coalesce(entry.lease_expires_at, '-infinity'::timestamptz) < now()
  for update of entry;

  if not found then
    return false;
  end if;

  perform private.enqueue_entry_upload_prefixes(
    p_user_id,
    p_entry_id,
    p_upload_token,
    now() + interval '5 minutes'
  );
  update public.entries
  set status = 'failed',
      status_message = 'Upload interrupted',
      error_message = 'The upload was interrupted. Return to the capture and send it again.',
      lease_expires_at = null,
      upload_token = null
  where id = locked_id;

  return true;
end;
$$;

revoke all on function public.fail_stale_entry_upload(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.fail_stale_entry_upload(uuid, uuid, uuid) to service_role;

-- A worker can stop after inserting the capture intent but before acquiring an
-- upload token. Once that no-token row is old enough that the original request
-- cannot still be healthy, terminalize it so it cannot be processed without
-- its promised media and the user can delete it. Setting the retry budget to
-- its maximum also fences a severely delayed original worker.
drop function if exists public.fail_stale_incomplete_entry(uuid, uuid);
create function public.fail_stale_incomplete_entry(
  p_entry_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  failed_id uuid;
begin
  update public.entries as entry
  set status = 'failed',
      status_message = 'Attachment upload incomplete',
      error_message = 'The original attachment upload did not finish. Delete this meal and log it again.',
      processing_attempts = 3,
      lease_expires_at = null
  where entry.id = p_entry_id
    and entry.user_id = p_user_id
    and entry.status = 'queued'
    and entry.upload_token is null
    and entry.created_at < now() - interval '120 seconds'
    and (
      (entry.intended_image and entry.image_path is null)
      or (
        entry.intended_audio
        and entry.audio_path is null
        and nullif(btrim(entry.transcript), '') is null
      )
    )
  returning entry.id into failed_id;

  return failed_id is not null;
end;
$$;

revoke all on function public.fail_stale_incomplete_entry(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.fail_stale_incomplete_entry(uuid, uuid)
  to service_role;

-- Once transcription is durable, detach the raw recording under the exact
-- processing-attempt fence and enqueue its deletion in the same transaction.
drop function if exists public.detach_entry_audio(uuid, uuid, smallint, text);
create function public.detach_entry_audio(
  p_entry_id uuid,
  p_user_id uuid,
  p_processing_attempt smallint,
  p_audio_path text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  locked_id uuid;
begin
  select entry.id
  into locked_id
  from public.entries as entry
  where entry.id = p_entry_id
    and entry.user_id = p_user_id
    and entry.processing_attempts = p_processing_attempt
    and entry.upload_token is null
    and entry.status in ('transcribing', 'analyzing')
    and nullif(btrim(entry.transcript), '') is not null
    and entry.audio_path = p_audio_path
  for update of entry;

  if not found then
    return false;
  end if;

  perform private.enqueue_storage_cleanup_job(
    'entry-audio',
    'object',
    p_audio_path,
    now()
  );
  update public.entries
  set audio_path = null
  where id = locked_id;

  return true;
end;
$$;

revoke all on function public.detach_entry_audio(uuid, uuid, smallint, text)
  from public, anon, authenticated;
grant execute on function public.detach_entry_audio(uuid, uuid, smallint, text)
  to service_role;

-- Entry deletion is a single database transaction: detach all exact media into
-- the durable cleanup outbox, then remove the row. Queue jobs deliberately have
-- no foreign key to entries and therefore survive the delete.
drop function if exists public.delete_entry_with_cleanup(uuid, uuid);
create function public.delete_entry_with_cleanup(
  p_entry_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  entry_row public.entries%rowtype;
begin
  select entry.*
  into entry_row
  from public.entries as entry
  where entry.id = p_entry_id
    and entry.user_id = p_user_id
    and entry.status in ('complete', 'failed', 'deleting')
  for update of entry;

  if not found then
    return false;
  end if;

  if entry_row.image_path is not null then
    perform private.enqueue_storage_cleanup_job(
      'entry-images',
      'object',
      entry_row.image_path,
      now()
    );
  end if;
  if entry_row.audio_path is not null then
    perform private.enqueue_storage_cleanup_job(
      'entry-audio',
      'object',
      entry_row.audio_path,
      now()
    );
  end if;
  if entry_row.upload_token is not null then
    perform private.enqueue_entry_upload_prefixes(
      p_user_id,
      p_entry_id,
      entry_row.upload_token,
      now() + interval '5 minutes'
    );
  end if;

  delete from public.entries
  where id = entry_row.id;
  return true;
end;
$$;

revoke all on function public.delete_entry_with_cleanup(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.delete_entry_with_cleanup(uuid, uuid)
  to service_role;

-- Move a terminal, retryable entry back to queued before dispatching another
-- worker. The database transition is the fence: a live upload/processing lease,
-- replacement state, exhausted retry budget, or different owner all return
-- false without mutating the row.
drop function if exists public.prepare_entry_resume(uuid, uuid);
create function public.prepare_entry_resume(
  p_entry_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  queued_id uuid;
begin
  update public.entries as entry
  set status = 'queued',
      status_message = 'Queued',
      error_message = null,
      lease_expires_at = null
  where entry.id = p_entry_id
    and entry.user_id = p_user_id
    and entry.status = 'failed'
    and entry.processing_attempts < 3
    and entry.upload_token is null
    and (not entry.intended_image or entry.image_path is not null)
    and (
      not entry.intended_audio
      or entry.audio_path is not null
      or nullif(btrim(entry.transcript), '') is not null
    )
    and coalesce(
      entry.lease_expires_at,
      '-infinity'::timestamptz
    ) < now()
  returning entry.id into queued_id;

  return queued_id is not null;
end;
$$;

revoke all on function public.prepare_entry_resume(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.prepare_entry_resume(uuid, uuid)
  to service_role;

-- Atomic lease acquisition makes processing resumable after a worker stops.
-- Only the service role can call this RPC; users go through resume_entry.
drop function if exists public.claim_entry_processing(uuid, uuid);
create function public.claim_entry_processing(
  p_entry_id uuid,
  p_user_id uuid
)
returns smallint
language plpgsql
security definer
set search_path = ''
as $$
declare
  claimed_attempt smallint;
begin
  update public.entries
  set processing_attempts = processing_attempts + 1,
      lease_expires_at = now() + interval '135 seconds',
      status = case
        when audio_path is not null and transcript is null then 'transcribing'
        else 'analyzing'
      end,
      status_message = case
        when audio_path is not null and transcript is null then 'Listening to your note'
        else 'Estimating your meal'
      end,
      error_message = null
  where id = p_entry_id
    and user_id = p_user_id
    and processing_attempts < 3
    and upload_token is null
    and (not intended_image or image_path is not null)
    and (
      not intended_audio
      or audio_path is not null
      or nullif(btrim(transcript), '') is not null
    )
    and (
      (
        status in ('queued', 'failed')
        and coalesce(lease_expires_at, '-infinity'::timestamptz) < now()
      )
      or (
        status in ('transcribing', 'analyzing')
        and coalesce(lease_expires_at, '-infinity'::timestamptz) < now()
      )
    )
  returning processing_attempts into claimed_attempt;

  return claimed_attempt;
end;
$$;

revoke all on function public.claim_entry_processing(uuid, uuid) from public, anon, authenticated;
grant execute on function public.claim_entry_processing(uuid, uuid) to service_role;

create or replace function public.fail_exhausted_entry_processing(
  p_entry_id uuid,
  p_user_id uuid,
  p_processing_attempt smallint
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  repaired_id uuid;
begin
  update public.entries
  set status = 'failed',
      status_message = 'Retry limit reached',
      error_message = 'This meal could not be recovered. Delete it and log it again.',
      lease_expires_at = null
  where id = p_entry_id
    and user_id = p_user_id
    and processing_attempts = p_processing_attempt
    and processing_attempts >= 3
    and upload_token is null
    and status in ('queued', 'transcribing', 'analyzing')
    and coalesce(lease_expires_at, '-infinity'::timestamptz) < now()
  returning id into repaired_id;

  return repaired_id is not null;
end;
$$;

revoke all on function public.fail_exhausted_entry_processing(uuid, uuid, smallint) from public, anon, authenticated;
grant execute on function public.fail_exhausted_entry_processing(uuid, uuid, smallint) to service_role;

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (user_id)
  values (new.id)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

revoke execute on function private.handle_new_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function private.handle_new_user();

insert into public.profiles (user_id)
select id from auth.users
on conflict (user_id) do nothing;

alter table public.profiles enable row level security;
alter table public.entries enable row level security;

drop policy if exists "select own profile" on public.profiles;
drop policy if exists "insert own profile" on public.profiles;
drop policy if exists "update own profile" on public.profiles;
drop policy if exists "own profile" on public.profiles;
drop policy if exists "insert self profile" on public.profiles;
drop policy if exists "update self profile" on public.profiles;
drop policy if exists "select own entries" on public.entries;
drop policy if exists "insert own entries" on public.entries;
drop policy if exists "own entries" on public.entries;

drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own on public.profiles
for insert to authenticated
with check ((select auth.uid()) = user_id);

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists entries_select_own on public.entries;
create policy entries_select_own on public.entries
for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists entries_insert_own on public.entries;
create policy entries_insert_own on public.entries
for insert to authenticated
with check ((select auth.uid()) = user_id);

drop policy if exists entries_update_own on public.entries;

drop policy if exists entries_delete_own on public.entries;

-- New projects no longer expose SQL-created tables to Data API roles by
-- default. Edge Functions use service_role, which bypasses RLS but still needs
-- ordinary table privileges.
grant usage on schema public to authenticated, service_role;
revoke all on public.profiles from authenticated;
grant select, insert, update on public.profiles to authenticated;
revoke all on public.entries from authenticated;
grant select on public.entries to authenticated;
grant select, insert, update, delete on public.profiles, public.entries to service_role;
revoke all on public.profiles, public.entries from anon;

create view public.daily_totals
with (security_invoker = true)
as
select
  user_id,
  local_day,
  round(sum(protein_g), 1) as protein_g,
  round(sum(carbs_g), 1) as carbs_g,
  round(sum(fat_g), 1) as fat_g,
  round(sum(calories_kcal), 1) as calories_kcal,
  count(*)::bigint as entry_count
from public.entries
where status = 'complete'
group by user_id, local_day;

revoke all on public.daily_totals
  from public, anon, authenticated, service_role;
grant select on public.daily_totals to authenticated, service_role;

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'entries'
  ) then
    alter publication supabase_realtime add table public.entries;
  end if;
end;
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('entry-images', 'entry-images', false, 6291456, array['image/jpeg', 'image/png', 'image/webp']),
  ('entry-audio', 'entry-audio', false, 26214400, array['audio/mp4', 'audio/x-m4a', 'audio/m4a', 'audio/aac', 'audio/mpeg', 'audio/wav'])
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "read own entry-audio" on storage.objects;
drop policy if exists "read own entry-images" on storage.objects;

drop policy if exists meal_images_select_own on storage.objects;
create policy meal_images_select_own on storage.objects
for select to authenticated
using (
  bucket_id = 'entry-images'
  and (
    (storage.foldername(name))[1] = (select auth.uid())::text
    or (storage.foldername(name))[1] = 'u_' || (select auth.uid())::text
  )
);

drop policy if exists meal_images_insert_own on storage.objects;
drop policy if exists meal_images_update_own on storage.objects;
drop policy if exists meal_images_delete_own on storage.objects;

drop policy if exists meal_audio_select_own on storage.objects;

drop policy if exists meal_audio_insert_own on storage.objects;
drop policy if exists meal_audio_update_own on storage.objects;
drop policy if exists meal_audio_delete_own on storage.objects;

-- Remove the policies attached to the abandoned legacy `entries` bucket. The
-- bucket itself remains untouched so a separately restored storage backup can
-- still be inspected if one is ever recovered.
drop policy if exists "entries read own" on storage.objects;
drop policy if exists "entries write own" on storage.objects;
drop policy if exists "entries update own" on storage.objects;
drop policy if exists "entries delete own" on storage.objects;

comment on table public.entries is 'One durable meal capture, including processing state and normalized nutrition output.';
comment on column public.entries.local_day is 'The user-selected calendar day; never inferred from the server timezone.';
comment on column public.entries.items is 'Small structured nutrition items only; raw provider responses are intentionally not stored here.';
