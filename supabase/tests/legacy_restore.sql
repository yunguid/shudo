\set ON_ERROR_STOP on
\ir bootstrap.sql

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'postgres') then
    create role postgres nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_admin') then
    create role supabase_admin nologin;
  end if;
end;
$$;

-- Reproduce both default-ACL classes in the downloaded dump. The migration
-- resets the postgres app-creator defaults while leaving Supabase's internal
-- supabase_admin defaults under platform ownership.
alter default privileges for role postgres in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on sequences to anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on functions to anon, authenticated, service_role;
alter default privileges for role supabase_admin in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges for role supabase_admin in schema public
  grant all on sequences to anon, authenticated, service_role;
alter default privileges for role supabase_admin in schema public
  grant all on functions to anon, authenticated, service_role;

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  timezone text not null default 'UTC',
  units text not null default 'imperial',
  height_cm numeric(5,2),
  weight_kg numeric(6,2),
  target_weight_kg numeric(6,2),
  goal text not null default 'gain',
  daily_macro_target jsonb not null default '{"calories_kcal":2800,"protein_g":180,"carbs_g":360,"fat_g":72}'::jsonb,
  activity_level text,
  cutoff_time_local time
);

create table public.entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  status text not null default 'pending',
  client_submitted_at timestamptz,
  timezone_snapshot text not null default 'UTC',
  local_day date generated always as ((created_at at time zone timezone_snapshot)::date) stored,
  has_audio boolean default false,
  has_image boolean default false,
  has_text boolean default false,
  raw_text text,
  image_path text,
  audio_path text,
  image_sha256 text,
  dedupe_hash text unique,
  model_output jsonb,
  protein_g numeric(8,2),
  carbs_g numeric(8,2),
  fat_g numeric(8,2),
  calories_kcal numeric(8,2),
  confidence numeric(4,3),
  error_msg text
);

create function public.set_timestamp_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

grant all on function public.set_timestamp_updated_at()
  to anon, authenticated, service_role;

-- The paused project's downloaded backup also contained this public
-- SECURITY DEFINER helper with default/direct Data API execution grants.
create function public.rls_auto_enable()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  null;
end;
$$;

grant execute on function public.rls_auto_enable()
  to anon, authenticated;

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_timestamp_updated_at();

alter table public.profiles enable row level security;
alter table public.entries enable row level security;
create policy entries_delete_own on public.entries for delete using (auth.uid() = user_id);
create policy entries_update_own on public.entries for update using (auth.uid() = user_id);
grant all on public.profiles, public.entries to anon, authenticated;

create policy "read own entry-audio" on storage.objects
for select to authenticated
using (
  bucket_id = 'entry-audio'
  and split_part(name, '/', 1) = 'u_' || (select auth.uid())::text
);

create policy "read own entry-images" on storage.objects
for select to authenticated
using (
  bucket_id = 'entry-images'
  and split_part(name, '/', 1) = 'u_' || (select auth.uid())::text
);

create view public.day_totals as
select user_id, local_day, sum(calories_kcal) as calories_kcal
from public.entries
group by user_id, local_day;

create table public.entry_items (id bigserial primary key, entry_id uuid);
create table public.daily_summaries (id bigserial primary key, user_id uuid);
create table public.macro_plans (id bigserial primary key, user_id uuid);

insert into auth.users (id, email)
values ('00000000-0000-4000-8000-000000000001', 'owner@example.test');

insert into public.profiles (user_id, timezone)
values ('00000000-0000-4000-8000-000000000001', 'America/New_York');

insert into public.entries (
  id,
  user_id,
  created_at,
  status,
  has_audio,
  raw_text,
  audio_path,
  model_output,
  protein_g,
  carbs_g,
  fat_g,
  calories_kcal
)
values
  (
    '20000000-0000-4000-8000-000000000001',
    '00000000-0000-4000-8000-000000000001',
    '2026-07-20T16:00:00Z',
    'processing',
    true,
    'Legacy sandwich',
    'u_00000000-0000-4000-8000-000000000001/e_20000000-0000-4000-8000-000000000001/audio_fixture.m4a',
    '{"parsed":{"items":[{"name":"Sandwich","serving_size":"1 sandwich","macros":{"protein_g":20,"carbs_g":35,"fat_g":12},"calories_kcal":328,"confidence":0.88}],"notes":"Legacy estimate"},"raw_json":{"id":"resp_legacy","model":"gpt-5"}}',
    20,
    35,
    12,
    328
  ),
  (
    '20000000-0000-4000-8000-000000000002',
    '00000000-0000-4000-8000-000000000001',
    '2026-07-20T17:00:00Z',
    'pending',
    true,
    null,
    'u_00000000-0000-4000-8000-000000000001/e_20000000-0000-4000-8000-000000000002/audio_fixture.m4a',
    null,
    null,
    null,
    null,
    null
  ),
  (
    '20000000-0000-4000-8000-000000000003',
    '00000000-0000-4000-8000-000000000001',
    '2026-07-20T18:00:00Z',
    'complete',
    true,
    'Duplicate legacy reference',
    'u_00000000-0000-4000-8000-000000000001/e_20000000-0000-4000-8000-000000000001/audio_fixture.m4a',
    null,
    null,
    null,
    null,
    null
  );

\ir ../migrations/20260720221116_rebuild_shudo_core.sql
\ir ../migrations/20260721125035_add_analysis_streaming_preview.sql
\ir ../migrations/20260721222010_restrict_rls_auto_enable_execute.sql
\ir ../migrations/20260721223105_account_onboarding_corrections_weekly.sql
\ir ../migrations/20260721231126_harden_target_history_weekly_claims.sql
\ir ../migrations/20260721234531_add_voice_entry_correction_requests.sql
\ir ../migrations/20260722001415_project_ai_budget_timezone.sql
\ir ../migrations/20260722015329_restrict_beta_signups_to_allowlist.sql
\ir ../migrations/20260722224247_add_private_profile_photos.sql

do $$
declare
  migrated_status text;
  migrated_day date;
  migrated_time timestamptz;
  migrated_items jsonb;
  migrated_notes text;
  migrated_input text;
  migrated_transcript text;
  migrated_audio text;
  migrated_intended_image boolean;
  migrated_intended_audio boolean;
  policy_count integer;
begin
  select status, local_day, occurred_at, items, analysis_notes, input_text,
         transcript, audio_path, intended_image, intended_audio
  into migrated_status, migrated_day, migrated_time, migrated_items,
       migrated_notes, migrated_input, migrated_transcript, migrated_audio,
       migrated_intended_image, migrated_intended_audio
  from public.entries
  where id = '20000000-0000-4000-8000-000000000001';

  if migrated_status <> 'failed' then
    raise exception 'legacy status was not migrated: %', migrated_status;
  end if;
  if migrated_day <> '2026-07-20' then
    raise exception 'legacy local_day was not preserved: %', migrated_day;
  end if;
  if migrated_time <> '2026-07-20T16:00:00Z'::timestamptz then
    raise exception 'legacy occurred_at was not preserved: %', migrated_time;
  end if;
  if migrated_items #>> '{0,name}' <> 'Sandwich' then
    raise exception 'legacy structured items were not preserved: %', migrated_items;
  end if;
  if migrated_notes <> 'Legacy estimate' then
    raise exception 'legacy notes were not preserved: %', migrated_notes;
  end if;
  if migrated_input is not null then
    raise exception 'legacy voice text was duplicated into input_text: %', migrated_input;
  end if;
  if migrated_transcript <> 'Legacy sandwich' then
    raise exception 'legacy voice transcript was not preserved: %', migrated_transcript;
  end if;
  if migrated_audio is not null then
    raise exception 'durably transcribed legacy audio remained attached: %', migrated_audio;
  end if;
  if migrated_intended_image or not migrated_intended_audio then
    raise exception 'legacy attachment intent was not preserved';
  end if;
  if (
    select count(*)
    from private.storage_cleanup_jobs
    where bucket = 'entry-audio'
      and mode = 'object'
      and object_path = 'u_00000000-0000-4000-8000-000000000001/e_20000000-0000-4000-8000-000000000001/audio_fixture.m4a'
  ) <> 1 then
    raise exception 'duplicate legacy audio was not de-duplicated in cleanup';
  end if;
  select status, transcript, audio_path, intended_audio
  into migrated_status, migrated_transcript, migrated_audio,
       migrated_intended_audio
  from public.entries
  where id = '20000000-0000-4000-8000-000000000002';
  if migrated_status <> 'failed'
    or migrated_transcript is not null
    or not migrated_intended_audio
    or migrated_audio is distinct from
      'u_00000000-0000-4000-8000-000000000001/e_20000000-0000-4000-8000-000000000002/audio_fixture.m4a' then
    raise exception 'untranscribed legacy audio was not retained for retry';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'entries'
      and column_name in (
        'model_output',
        'dedupe_hash',
        'has_audio',
        'has_image',
        'error_msg'
      )
  ) then
    raise exception 'legacy entry columns were not removed';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'profiles'
      and column_name = 'goal'
  ) then
    raise exception 'legacy profile goal column was not removed';
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'entries'
      and column_name in ('protein_g', 'carbs_g', 'fat_g', 'calories_kcal')
      and numeric_scale <> 1
  ) then
    raise exception 'legacy macro precision was not normalized';
  end if;
  if has_table_privilege('anon', 'public.entries', 'select') then
    raise exception 'legacy anon grant survived the migration';
  end if;
  if has_table_privilege('authenticated', 'public.entries', 'delete') then
    raise exception 'legacy delete grant survived the migration';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.prepare_entry_resume(uuid, uuid)',
    'execute'
  ) then
    raise exception 'legacy authenticated role can prepare a resume';
  end if;
  if not has_function_privilege(
    'service_role',
    'public.prepare_entry_resume(uuid, uuid)',
    'execute'
  ) then
    raise exception 'service role cannot prepare a restored entry resume';
  end if;
  if to_regprocedure('public.set_timestamp_updated_at()') is not null then
    raise exception 'legacy public timestamp trigger function survived';
  end if;
  if to_regprocedure('public.rls_auto_enable()') is null then
    raise exception 'legacy RLS helper was unexpectedly removed';
  end if;
  if has_function_privilege(
    'anon',
    'public.rls_auto_enable()',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'public.rls_auto_enable()',
    'execute'
  ) then
    raise exception 'legacy SECURITY DEFINER RLS helper retained Data API EXECUTE';
  end if;
  if exists (
    select 1
    from pg_proc as function_meta
    cross join lateral aclexplode(
      coalesce(
        function_meta.proacl,
        acldefault('f', function_meta.proowner)
      )
    ) as privilege
    left join pg_roles as grantee_role
      on grantee_role.oid = privilege.grantee
    where function_meta.oid = 'public.rls_auto_enable()'::regprocedure
      and privilege.privilege_type = 'EXECUTE'
      and (
        privilege.grantee = 0
        or grantee_role.rolname in ('anon', 'authenticated')
      )
  ) then
    raise exception 'legacy SECURITY DEFINER RLS helper retained an explicit EXECUTE ACL';
  end if;
  if has_function_privilege(
    'service_role',
    'private.set_updated_at()',
    'execute'
  ) or has_function_privilege(
    'service_role',
    'private.ensure_entry_local_day()',
    'execute'
  ) then
    raise exception 'service role can execute a private trigger helper';
  end if;
  if has_schema_privilege('service_role', 'private', 'usage') then
    raise exception 'service role unexpectedly has private schema USAGE';
  end if;

  if exists (
    select 1
    from pg_default_acl as defaults
    join pg_namespace as namespace
      on namespace.oid = defaults.defaclnamespace
    join pg_roles as owner_role
      on owner_role.oid = defaults.defaclrole
    cross join lateral aclexplode(defaults.defaclacl) as privilege
    left join pg_roles as grantee_role
      on grantee_role.oid = privilege.grantee
    where namespace.nspname = 'public'
      and owner_role.rolname = 'postgres'
      and defaults.defaclobjtype in ('r', 'S', 'f')
      and (
        privilege.grantee = 0
        or grantee_role.rolname in ('anon', 'authenticated', 'service_role')
      )
  ) then
    raise exception 'restored postgres public default ACL grants survived';
  end if;
  if not exists (
    select 1
    from pg_default_acl as defaults
    join pg_namespace as namespace
      on namespace.oid = defaults.defaclnamespace
    join pg_roles as owner_role
      on owner_role.oid = defaults.defaclrole
    cross join lateral aclexplode(defaults.defaclacl) as privilege
    left join pg_roles as grantee_role
      on grantee_role.oid = privilege.grantee
    where namespace.nspname = 'public'
      and owner_role.rolname = 'supabase_admin'
      and defaults.defaclobjtype in ('r', 'S', 'f')
      and grantee_role.rolname = 'authenticated'
  ) then
    raise exception 'internal supabase_admin defaults were unexpectedly mutated';
  end if;

  if not has_table_privilege(
    'authenticated',
    'public.daily_totals',
    'select'
  ) or not has_table_privilege(
    'service_role',
    'public.daily_totals',
    'select'
  ) or has_table_privilege(
    'anon',
    'public.daily_totals',
    'select'
  ) or has_table_privilege(
    'authenticated',
    'public.daily_totals',
    'insert'
  ) or has_table_privilege(
    'service_role',
    'public.daily_totals',
    'update'
  ) then
    raise exception 'daily_totals grants were not reduced to SELECT';
  end if;

  if exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname in (
        'read own entry-audio',
        'read own entry-images',
        'meal_audio_select_own'
      )
  ) then
    raise exception 'a legacy/raw-audio Storage SELECT policy survived';
  end if;
  select count(*)
  into policy_count
  from pg_policies
  where schemaname = 'storage'
    and tablename = 'objects'
    and policyname = 'meal_images_select_own'
    and cmd = 'SELECT';
  if policy_count <> 1 then
    raise exception 'restored image access does not have one replacement policy';
  end if;
end;
$$;

\ir ai_budget_timezone.sql

\ir beta_signup_allowlist.sql

\ir voice_corrections.sql

\ir profile_photos.sql

insert into storage.objects (bucket_id, name)
values
  (
    'entry-images',
    'u_00000000-0000-4000-8000-000000000001/e_legacy/photo.jpg'
  ),
  (
    'entry-audio',
    'u_00000000-0000-4000-8000-000000000001/e_legacy/voice.m4a'
  );

set role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-4000-8000-000000000001',
  false
);

do $$
declare
  visible_images integer;
  visible_audio integer;
begin
  select count(*)
  into visible_images
  from storage.objects
  where bucket_id = 'entry-images';
  select count(*)
  into visible_audio
  from storage.objects
  where bucket_id = 'entry-audio';

  if visible_images <> 1 then
    raise exception 'legacy owner image is not visible: %', visible_images;
  end if;
  if visible_audio <> 0 then
    raise exception 'legacy raw audio is still visible: %', visible_audio;
  end if;
end;
$$;

reset role;

do $$
declare
  restored_target jsonb;
  restored_status text;
begin
  select daily_macro_target, onboarding_status
  into restored_target, restored_status
  from public.profiles
  where user_id = '00000000-0000-4000-8000-000000000001';

  if restored_target <> '{"calories_kcal":2800,"protein_g":180,"carbs_g":360,"fat_g":72}'::jsonb then
    raise exception 'legacy macro target was overwritten: %', restored_target;
  end if;
  if restored_status <> 'completed' then
    raise exception 'established legacy user was forced through onboarding: %', restored_status;
  end if;
  if not exists (
    select 1 from public.daily_targets
    where user_id = '00000000-0000-4000-8000-000000000001'
      and target_day = '2026-07-20'
      and calories_kcal = 2800
      and protein_g = 180
      and carbs_g = 360
      and fat_g = 72
      and source = 'imported'
  ) then
    raise exception 'legacy macro target was not backfilled from its first meal day';
  end if;
end;
$$;
