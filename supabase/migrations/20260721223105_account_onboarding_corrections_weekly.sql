-- Additive multi-user account, onboarding, correction, and weekly-summary
-- architecture. Existing profiles and meal history are preserved.

alter table public.profiles
  add column if not exists display_name text,
  add column if not exists goal_type text not null default 'maintain',
  add column if not exists goal_notes text,
  add column if not exists onboarding_status text not null default 'pending',
  add column if not exists onboarding_completed_at timestamptz,
  add column if not exists weekly_summary_enabled boolean not null default true,
  -- Older development builds wrote these fields from a blocking first-run
  -- screen. New builds ignore them, but retaining the nullable columns lets an
  -- installed old build advance instead of failing its final PATCH.
  add column if not exists ai_consent_version text,
  add column if not exists ai_consented_at timestamptz;

alter table public.profiles
  drop constraint if exists profiles_display_name_length_check,
  drop constraint if exists profiles_goal_type_check,
  drop constraint if exists profiles_goal_notes_length_check,
  drop constraint if exists profiles_onboarding_status_check,
  drop constraint if exists profiles_ai_consent_check,
  add constraint profiles_display_name_length_check
    check (display_name is null or char_length(display_name) between 1 and 80),
  add constraint profiles_goal_type_check
    check (goal_type in ('maintain', 'lose', 'gain')),
  add constraint profiles_goal_notes_length_check
    check (goal_notes is null or char_length(goal_notes) <= 2000),
  add constraint profiles_onboarding_status_check
    check (onboarding_status in ('pending', 'completed', 'skipped')),
  add constraint profiles_ai_consent_check check (
    (ai_consent_version is null and ai_consented_at is null)
    or (
      char_length(ai_consent_version) between 1 and 64
      and ai_consented_at is not null
    )
  );

-- Established users keep their current profile and bypass first-run setup.
-- A populated profile or any meal history is evidence that setup already
-- happened in an earlier build; the existing macro JSON is never rewritten.
update public.profiles as profile
set onboarding_status = 'completed',
    onboarding_completed_at = coalesce(
      profile.onboarding_completed_at,
      profile.updated_at,
      profile.created_at,
      now()
    )
where profile.onboarding_status = 'pending'
  and (
    profile.height_cm is not null
    or profile.weight_kg is not null
    or profile.target_weight_kg is not null
    or nullif(btrim(profile.activity_level), '') is not null
    or exists (
      select 1 from public.entries as entry
      where entry.user_id = profile.user_id
    )
  );

alter table public.entries
  add column if not exists analysis_context text;

alter table public.entries
  drop constraint if exists entries_analysis_context_length_check,
  add constraint entries_analysis_context_length_check
    check (analysis_context is null or char_length(analysis_context) <= 4000);

create table if not exists public.daily_targets (
  user_id uuid not null references auth.users(id) on delete cascade,
  target_day date not null,
  calories_kcal numeric(9,1) not null,
  protein_g numeric(8,1) not null,
  carbs_g numeric(8,1) not null,
  fat_g numeric(8,1) not null,
  source text not null default 'manual',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, target_day),
  constraint daily_targets_values_check check (
    calories_kcal between 500 and 10000
    and protein_g between 0 and 1000
    and carbs_g between 0 and 1500
    and fat_g between 0 and 1000
  ),
  constraint daily_targets_source_check
    check (source in ('onboarding', 'manual', 'imported'))
);

create table if not exists public.onboarding_analyses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  client_request_id uuid not null,
  timezone_snapshot text not null,
  transcript text,
  recommendation jsonb,
  final_values jsonb,
  status text not null default 'analyzing',
  analysis_model text not null,
  provider_response_id text,
  error_message text,
  created_at timestamptz not null default now(),
  applied_at timestamptz,
  constraint onboarding_analyses_user_request_unique
    unique (user_id, client_request_id),
  constraint onboarding_analyses_transcript_length_check
    check (transcript is null or char_length(transcript) between 1 and 30000),
  constraint onboarding_analyses_status_check
    check (status in ('analyzing', 'proposed', 'applied', 'failed')),
  constraint onboarding_analyses_recommendation_object_check
    check (recommendation is null or jsonb_typeof(recommendation) = 'object'),
  constraint onboarding_analyses_final_values_object_check
    check (final_values is null or jsonb_typeof(final_values) = 'object'),
  constraint onboarding_analyses_ready_payload_check check (
    status in ('analyzing', 'failed')
    or (transcript is not null and recommendation is not null)
  )
);

create table if not exists public.entry_corrections (
  id uuid primary key default gen_random_uuid(),
  sequence_no bigint generated always as identity,
  user_id uuid not null references auth.users(id) on delete cascade,
  entry_id uuid not null references public.entries(id) on delete cascade,
  context text not null,
  created_at timestamptz not null default now(),
  constraint entry_corrections_context_length_check
    check (char_length(context) between 1 and 4000)
);

create index if not exists entry_corrections_user_entry_sequence_idx
  on public.entry_corrections (user_id, entry_id, sequence_no desc);

create table if not exists public.weekly_summaries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  week_start date not null,
  week_end date generated always as (week_start + 6) stored,
  status text not null default 'generating',
  headline text,
  narrative text,
  repeated_foods jsonb not null default '[]'::jsonb,
  patterns jsonb not null default '[]'::jsonb,
  adherence jsonb not null default '{}'::jsonb,
  suggestions jsonb not null default '[]'::jsonb,
  input_fingerprint text not null,
  generation_attempt smallint not null default 1,
  lease_expires_at timestamptz,
  analysis_model text,
  provider_response_id text,
  error_message text,
  generated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, week_start),
  constraint weekly_summaries_week_start_check
    check (extract(isodow from week_start) = 1),
  constraint weekly_summaries_status_check
    check (status in ('generating', 'complete', 'failed')),
  constraint weekly_summaries_json_shapes_check check (
    jsonb_typeof(repeated_foods) = 'array'
    and jsonb_typeof(patterns) = 'array'
    and jsonb_typeof(adherence) = 'object'
    and jsonb_typeof(suggestions) = 'array'
  ),
  constraint weekly_summaries_attempt_check
    check (generation_attempt between 1 and 20)
);

create index if not exists weekly_summaries_user_generated_idx
  on public.weekly_summaries (user_id, week_start desc)
  where status = 'complete';

-- Public signup must not make model-backed endpoints an unbounded spend path.
-- Advisory locks serialize quota decisions for the same user without blocking
-- other users. Replayed client_request_id values remain idempotent.
create or replace function private.enforce_entry_capture_quota()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shudo-capture:' || new.user_id::text, 0)
  );
  if exists (
    select 1 from public.entries
    where user_id = new.user_id
      and client_request_id = new.client_request_id
  ) then
    return new;
  end if;
  if (
    select count(*) from public.entries
    where user_id = new.user_id and local_day = new.local_day
  ) >= 30 then
    raise exception using
      errcode = 'P0001', message = 'entry_daily_quota_exceeded';
  end if;
  if (
    select count(*) from public.entries
    where user_id = new.user_id
      and status in ('queued', 'transcribing', 'analyzing')
  ) >= 5 then
    raise exception using
      errcode = 'P0001', message = 'entry_concurrency_quota_exceeded';
  end if;
  return new;
end;
$$;

revoke all on function private.enforce_entry_capture_quota()
  from public, anon, authenticated, service_role;
drop trigger if exists entries_enforce_capture_quota on public.entries;
create trigger entries_enforce_capture_quota
before insert on public.entries
for each row execute function private.enforce_entry_capture_quota();

create or replace function private.enforce_onboarding_quota()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shudo-onboarding:' || new.user_id::text, 0)
  );
  if exists (
    select 1 from public.onboarding_analyses
    where user_id = new.user_id
      and client_request_id = new.client_request_id
  ) then
    return new;
  end if;
  if (
    select count(*) from public.onboarding_analyses
    where user_id = new.user_id
      and created_at >= now() - interval '24 hours'
  ) >= 3 then
    raise exception using
      errcode = 'P0001', message = 'onboarding_daily_quota_exceeded';
  end if;
  if exists (
    select 1 from public.onboarding_analyses
    where user_id = new.user_id
      and status = 'analyzing'
  ) then
    raise exception using
      errcode = 'P0001', message = 'onboarding_concurrency_quota_exceeded';
  end if;
  return new;
end;
$$;

revoke all on function private.enforce_onboarding_quota()
  from public, anon, authenticated, service_role;
drop trigger if exists onboarding_analyses_enforce_quota
  on public.onboarding_analyses;
create trigger onboarding_analyses_enforce_quota
before insert on public.onboarding_analyses
for each row execute function private.enforce_onboarding_quota();

drop trigger if exists daily_targets_set_updated_at on public.daily_targets;
create trigger daily_targets_set_updated_at
before update on public.daily_targets
for each row execute function private.set_updated_at();

drop trigger if exists weekly_summaries_set_updated_at on public.weekly_summaries;
create trigger weekly_summaries_set_updated_at
before update on public.weekly_summaries
for each row execute function private.set_updated_at();

alter table public.daily_targets enable row level security;
alter table public.onboarding_analyses enable row level security;
alter table public.entry_corrections enable row level security;
alter table public.weekly_summaries enable row level security;

drop policy if exists daily_targets_select_own on public.daily_targets;
create policy daily_targets_select_own on public.daily_targets
for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists daily_targets_insert_own on public.daily_targets;
create policy daily_targets_insert_own on public.daily_targets
for insert to authenticated
with check ((select auth.uid()) = user_id);

drop policy if exists daily_targets_update_own on public.daily_targets;
create policy daily_targets_update_own on public.daily_targets
for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists daily_targets_delete_own on public.daily_targets;
create policy daily_targets_delete_own on public.daily_targets
for delete to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists onboarding_analyses_select_own on public.onboarding_analyses;
create policy onboarding_analyses_select_own on public.onboarding_analyses
for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists entry_corrections_select_own on public.entry_corrections;
create policy entry_corrections_select_own on public.entry_corrections
for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists weekly_summaries_select_own on public.weekly_summaries;
create policy weekly_summaries_select_own on public.weekly_summaries
for select to authenticated
using ((select auth.uid()) = user_id);

revoke all on public.daily_targets, public.onboarding_analyses,
  public.entry_corrections, public.weekly_summaries
  from public, anon, authenticated, service_role;
grant select, insert, update, delete on public.daily_targets to authenticated;
grant select on public.onboarding_analyses, public.entry_corrections,
  public.weekly_summaries to authenticated;
grant select, insert, update, delete on public.daily_targets,
  public.onboarding_analyses, public.entry_corrections,
  public.weekly_summaries to service_role;

-- The authenticated Edge Function supplies the verified caller UUID. This
-- transaction records the correction and returns the meal to the same fenced
-- processor used for initial analysis.
create or replace function public.prepare_entry_reanalysis(
  p_entry_id uuid,
  p_user_id uuid,
  p_context text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_status text;
  normalized_context text := btrim(coalesce(p_context, ''));
  canonical_context text;
  correction_row record;
  correction_separator constant text := E'\n\nEarlier correction:\n';
  remaining_characters integer;
begin
  if char_length(normalized_context) not between 1 and 4000 then
    raise exception using
      errcode = '22023',
      message = 'Correction context must contain 1 to 4000 characters';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shudo-reanalysis:' || p_user_id::text, 0)
  );
  if (
    select count(*) from public.entry_corrections
    where user_id = p_user_id
      and created_at >= now() - interval '24 hours'
  ) >= 10 then
    return 'quota';
  end if;
  if (
    select count(*) from public.entries
    where user_id = p_user_id
      and status in ('queued', 'transcribing', 'analyzing')
  ) >= 5 then
    return 'capacity';
  end if;

  select entry.status
  into current_status
  from public.entries as entry
  where entry.id = p_entry_id
    and entry.user_id = p_user_id
  for update of entry;

  if not found then
    return 'not_found';
  end if;
  if current_status in ('queued', 'transcribing', 'analyzing', 'deleting') then
    return 'busy';
  end if;
  if current_status <> 'complete' then
    return 'unavailable';
  end if;

  insert into public.entry_corrections (user_id, entry_id, context)
  values (p_user_id, p_entry_id, normalized_context);

  -- Reanalysis is cumulative, newest-first. Preserve the newest correction in
  -- full whenever possible, then use remaining space for earlier context. The
  -- durable audit rows remain complete while the model prompt stays <= 4k.
  canonical_context := '';
  for correction_row in
    select context
    from public.entry_corrections
    where user_id = p_user_id and entry_id = p_entry_id
    order by sequence_no desc
    limit 10
  loop
    if canonical_context = '' then
      canonical_context := left(correction_row.context, 4000);
    else
      remaining_characters := 4000
        - char_length(canonical_context)
        - char_length(correction_separator);
      exit when remaining_characters <= 0;
      canonical_context := canonical_context
        || correction_separator
        || left(correction_row.context, remaining_characters);
    end if;
  end loop;

  update public.entries
  set analysis_context = canonical_context,
      status = 'queued',
      status_message = 'Queued with your correction',
      processing_attempts = 0,
      lease_expires_at = null,
      upload_token = null,
      analysis_preview = null,
      error_message = null,
      provider_response_id = null,
      processed_at = null
  where id = p_entry_id
    and user_id = p_user_id;

  return 'queued';
end;
$$;

revoke all on function public.prepare_entry_reanalysis(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.prepare_entry_reanalysis(uuid, uuid, text)
  to service_role;

-- Apply a reviewed onboarding proposal atomically. `p_values` is validated in
-- the Edge Function and constrained again by the destination columns.
create or replace function public.apply_onboarding_profile(
  p_onboarding_id uuid,
  p_user_id uuid,
  p_target_day date,
  p_values jsonb
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  analysis_status text;
begin
  if p_values is null or jsonb_typeof(p_values) <> 'object' then
    raise exception using errcode = '22023', message = 'Profile values must be an object';
  end if;

  select onboarding.status
  into analysis_status
  from public.onboarding_analyses as onboarding
  where onboarding.id = p_onboarding_id
    and onboarding.user_id = p_user_id
  for update of onboarding;

  if not found or analysis_status <> 'proposed' then
    return false;
  end if;

  update public.profiles
  set timezone = p_values->>'timezone',
      display_name = nullif(btrim(p_values->>'display_name'), ''),
      goal_type = p_values->>'goal_type',
      goal_notes = nullif(btrim(p_values->>'goal_notes'), ''),
      height_cm = nullif(p_values->>'height_cm', '')::numeric,
      weight_kg = nullif(p_values->>'weight_kg', '')::numeric,
      target_weight_kg = nullif(p_values->>'target_weight_kg', '')::numeric,
      activity_level = nullif(btrim(p_values->>'activity_level'), ''),
      daily_macro_target = jsonb_build_object(
        'calories_kcal', (p_values->>'calories_kcal')::numeric,
        'protein_g', (p_values->>'protein_g')::numeric,
        'carbs_g', (p_values->>'carbs_g')::numeric,
        'fat_g', (p_values->>'fat_g')::numeric
      ),
      onboarding_status = 'completed',
      onboarding_completed_at = now()
  where user_id = p_user_id;

  if not found then
    return false;
  end if;

  insert into public.daily_targets (
    user_id,
    target_day,
    calories_kcal,
    protein_g,
    carbs_g,
    fat_g,
    source
  ) values (
    p_user_id,
    p_target_day,
    (p_values->>'calories_kcal')::numeric,
    (p_values->>'protein_g')::numeric,
    (p_values->>'carbs_g')::numeric,
    (p_values->>'fat_g')::numeric,
    'onboarding'
  )
  on conflict (user_id, target_day) do update
  set calories_kcal = excluded.calories_kcal,
      protein_g = excluded.protein_g,
      carbs_g = excluded.carbs_g,
      fat_g = excluded.fat_g,
      source = excluded.source;

  update public.onboarding_analyses
  set final_values = p_values,
      status = 'applied',
      applied_at = now()
  where id = p_onboarding_id
    and user_id = p_user_id;

  return true;
end;
$$;

revoke all on function public.apply_onboarding_profile(uuid, uuid, date, jsonb)
  from public, anon, authenticated;
grant execute on function public.apply_onboarding_profile(uuid, uuid, date, jsonb)
  to service_role;

-- Claim one user's completed Monday-Sunday week. A content fingerprint makes
-- repeated scheduled runs no-ops until a profile or meal in that week changes.
create or replace function public.claim_weekly_summary(
  p_user_id uuid,
  p_week_start date
)
returns table(summary_id uuid, input_fingerprint text, generation_attempt smallint)
language plpgsql
security definer
set search_path = ''
as $$
declare
  fingerprint text;
  existing public.weekly_summaries%rowtype;
  entry_count bigint;
begin
  if extract(isodow from p_week_start) <> 1 then
    raise exception using errcode = '22023', message = 'week_start must be a Monday';
  end if;
  if not exists (
    select 1 from public.profiles
    where user_id = p_user_id
      and weekly_summary_enabled
  ) then
    return;
  end if;

  select count(*)
  into entry_count
  from public.entries
  where user_id = p_user_id
    and local_day >= p_week_start
    and local_day < p_week_start + 7
    and status = 'complete';
  if entry_count = 0 then
    return;
  end if;

  select encode(extensions.digest(
    concat_ws('|',
      p_user_id::text,
      p_week_start::text,
      profile.updated_at::text,
      profile.timezone,
      profile.daily_macro_target::text,
      entry_count::text,
      coalesce((
        select string_agg(
          concat_ws('~',
            entry.id::text,
            entry.local_day::text,
            coalesce(entry.title, ''),
            entry.calories_kcal::text,
            entry.protein_g::text,
            entry.carbs_g::text,
            entry.fat_g::text,
            entry.items::text,
            entry.updated_at::text
          ),
          '|' order by entry.id
        )
        from public.entries as entry
        where entry.user_id = p_user_id
          and entry.local_day >= p_week_start
          and entry.local_day < p_week_start + 7
          and entry.status = 'complete'
      ), '')
    ),
    'sha256'
  ), 'hex')
  into fingerprint
  from public.profiles as profile
  where profile.user_id = p_user_id
  ;

  select summary.*
  into existing
  from public.weekly_summaries as summary
  where summary.user_id = p_user_id
    and summary.week_start = p_week_start
  for update of summary;

  if found
    and existing.status = 'complete'
    and existing.input_fingerprint = fingerprint then
    return;
  end if;
  if found
    and existing.status = 'generating'
    and existing.lease_expires_at > now() then
    return;
  end if;
  if found
    and existing.input_fingerprint = fingerprint
    and existing.generation_attempt >= 3 then
    return;
  end if;

  insert into public.weekly_summaries (
    user_id,
    week_start,
    status,
    input_fingerprint,
    generation_attempt,
    lease_expires_at,
    error_message
  ) values (
    p_user_id,
    p_week_start,
    'generating',
    fingerprint,
    1,
    now() + interval '120 seconds',
    null
  )
  on conflict (user_id, week_start) do update
  set status = 'generating',
      input_fingerprint = excluded.input_fingerprint,
      generation_attempt = case
        when public.weekly_summaries.input_fingerprint
          is distinct from excluded.input_fingerprint then 1
        else least(public.weekly_summaries.generation_attempt + 1, 3)
      end,
      lease_expires_at = excluded.lease_expires_at,
      error_message = null
  returning id, public.weekly_summaries.input_fingerprint,
    public.weekly_summaries.generation_attempt
  into summary_id, input_fingerprint, generation_attempt;

  return next;
end;
$$;

revoke all on function public.claim_weekly_summary(uuid, date)
  from public, anon, authenticated;
grant execute on function public.claim_weekly_summary(uuid, date)
  to service_role;

comment on table public.daily_targets is
  'User-owned daily macro targets with historical snapshots for adherence reporting.';
comment on table public.onboarding_analyses is
  'Reviewed voice-onboarding proposals; raw audio is never retained here.';
comment on table public.entry_corrections is
  'Append-only user correction context for meal reanalysis auditability.';
comment on table public.weekly_summaries is
  'Idempotently generated, user-owned Monday-Sunday nutrition summaries.';
