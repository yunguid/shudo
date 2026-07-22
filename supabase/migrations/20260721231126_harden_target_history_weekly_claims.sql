-- Keep the profile JSON used by current clients while recording an
-- effective-dated target ledger for historical adherence. The private
-- validator makes direct Data API writes obey the same bounds as onboarding.
create or replace function private.daily_macro_target_is_valid(p_target jsonb)
returns boolean
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  calories numeric;
  protein numeric;
  carbs numeric;
  fat numeric;
begin
  if p_target is null or pg_catalog.jsonb_typeof(p_target) <> 'object' then
    return false;
  end if;
  if pg_catalog.jsonb_typeof(p_target->'calories_kcal') is distinct from 'number'
    or pg_catalog.jsonb_typeof(p_target->'protein_g') is distinct from 'number'
    or pg_catalog.jsonb_typeof(p_target->'carbs_g') is distinct from 'number'
    or pg_catalog.jsonb_typeof(p_target->'fat_g') is distinct from 'number' then
    return false;
  end if;

  calories := (p_target->>'calories_kcal')::numeric;
  protein := (p_target->>'protein_g')::numeric;
  carbs := (p_target->>'carbs_g')::numeric;
  fat := (p_target->>'fat_g')::numeric;
  return calories between 500 and 10000
    and protein between 0 and 1000
    and carbs between 0 and 1500
    and fat between 0 and 1000;
exception
  when invalid_text_representation or numeric_value_out_of_range then
    return false;
end;
$$;

revoke all on function private.daily_macro_target_is_valid(jsonb)
  from public, anon, authenticated, service_role;
-- PostgreSQL checks function EXECUTE while enforcing a CHECK constraint for
-- direct Data API writes. The function is immutable/read-only and the private
-- schema itself remains unavailable, so it is not a callable API surface.
grant execute on function private.daily_macro_target_is_valid(jsonb)
  to authenticated, service_role;

alter table public.profiles
  drop constraint if exists profiles_daily_macro_target_check;
alter table public.profiles
  add constraint profiles_daily_macro_target_check
  check (private.daily_macro_target_is_valid(daily_macro_target));

alter table public.profiles
  drop constraint if exists profiles_height_cm_range_check,
  drop constraint if exists profiles_weight_kg_range_check,
  drop constraint if exists profiles_target_weight_kg_range_check,
  add constraint profiles_height_cm_range_check
    check (height_cm is null or height_cm between 50 and 275),
  add constraint profiles_weight_kg_range_check
    check (weight_kg is null or weight_kg between 20 and 500),
  add constraint profiles_target_weight_kg_range_check
    check (target_weight_kg is null or target_weight_kg between 20 and 500);

-- A malformed legacy timezone must not make a target update impossible. The
-- scheduled worker separately skips and reports that profile so it can be
-- repaired; UTC is only the durable fallback for choosing this effective day.
create or replace function private.profile_local_day(
  p_timezone text,
  p_at timestamptz
)
returns date
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  return (
    p_at at time zone coalesce(
      nullif(pg_catalog.btrim(p_timezone), ''),
      'UTC'
    )
  )::date;
exception
  when invalid_parameter_value then
    return (p_at at time zone 'UTC')::date;
end;
$$;

revoke all on function private.profile_local_day(text, timestamptz)
  from public, anon, authenticated, service_role;

create or replace function private.snapshot_profile_daily_target()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  effective_day date;
begin
  if tg_op = 'UPDATE'
    and new.daily_macro_target is not distinct from old.daily_macro_target then
    return new;
  end if;
  if not private.daily_macro_target_is_valid(new.daily_macro_target) then
    raise exception using
      errcode = '22023',
      message = 'daily_macro_target is invalid';
  end if;

  effective_day := private.profile_local_day(
    new.timezone,
    pg_catalog.statement_timestamp()
  );
  insert into public.daily_targets (
    user_id,
    target_day,
    calories_kcal,
    protein_g,
    carbs_g,
    fat_g,
    source
  ) values (
    new.user_id,
    effective_day,
    (new.daily_macro_target->>'calories_kcal')::numeric,
    (new.daily_macro_target->>'protein_g')::numeric,
    (new.daily_macro_target->>'carbs_g')::numeric,
    (new.daily_macro_target->>'fat_g')::numeric,
    'manual'
  )
  on conflict (user_id, target_day) do update
  set calories_kcal = excluded.calories_kcal,
      protein_g = excluded.protein_g,
      carbs_g = excluded.carbs_g,
      fat_g = excluded.fat_g,
      source = excluded.source
  where (
    public.daily_targets.calories_kcal,
    public.daily_targets.protein_g,
    public.daily_targets.carbs_g,
    public.daily_targets.fat_g,
    public.daily_targets.source
  ) is distinct from (
    excluded.calories_kcal,
    excluded.protein_g,
    excluded.carbs_g,
    excluded.fat_g,
    excluded.source
  );
  return new;
end;
$$;

revoke all on function private.snapshot_profile_daily_target()
  from public, anon, authenticated, service_role;

drop trigger if exists profiles_snapshot_daily_target on public.profiles;
create trigger profiles_snapshot_daily_target
after insert or update of daily_macro_target on public.profiles
for each row execute function private.snapshot_profile_daily_target();

-- Historical targets are derived data, not a client-editable table. Current
-- native builds update profiles, and the trigger above is the only unprivileged
-- write path. This prevents backdating/deleting history to corrupt adherence
-- or force unnecessary weekly model generations.
drop policy if exists daily_targets_insert_own on public.daily_targets;
drop policy if exists daily_targets_update_own on public.daily_targets;
drop policy if exists daily_targets_delete_own on public.daily_targets;
revoke insert, update, delete on public.daily_targets from authenticated;
grant select on public.daily_targets to authenticated;

-- Existing users have no reconstructable target-change ledger. Seed their
-- current target from their first retained meal day (or today locally when
-- they have no meals) so every future weekly calculation has a stable base.
insert into public.daily_targets (
  user_id,
  target_day,
  calories_kcal,
  protein_g,
  carbs_g,
  fat_g,
  source
)
select
  profile.user_id,
  coalesce(
    (
      select pg_catalog.min(entry.local_day)
      from public.entries as entry
      where entry.user_id = profile.user_id
    ),
    private.profile_local_day(profile.timezone, pg_catalog.statement_timestamp())
  ),
  (profile.daily_macro_target->>'calories_kcal')::numeric,
  (profile.daily_macro_target->>'protein_g')::numeric,
  (profile.daily_macro_target->>'carbs_g')::numeric,
  (profile.daily_macro_target->>'fat_g')::numeric,
  'imported'
from public.profiles as profile
on conflict (user_id, target_day) do nothing;

-- Capture spend is reserved against server time in a private ledger. It is
-- deliberately independent of the user-selected meal day and survives meal
-- deletion, closing both ways a client could reset the model-spend counter.
create table if not exists private.entry_capture_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  client_request_id uuid not null,
  reserved_at timestamptz not null default now(),
  primary key (user_id, client_request_id)
);

create index if not exists entry_capture_usage_user_reserved_idx
  on private.entry_capture_usage (user_id, reserved_at desc);

revoke all on table private.entry_capture_usage
  from public, anon, authenticated, service_role;

insert into private.entry_capture_usage (
  user_id,
  client_request_id,
  reserved_at
)
select entry.user_id, entry.client_request_id, entry.created_at
from public.entries as entry
on conflict (user_id, client_request_id) do nothing;

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
    select 1 from private.entry_capture_usage as usage
    where usage.user_id = new.user_id
      and usage.client_request_id = new.client_request_id
  ) then
    if exists (
      select 1 from public.entries as entry
      where entry.user_id = new.user_id
        and entry.client_request_id = new.client_request_id
    ) then
      return new;
    end if;
    raise exception using
      errcode = 'P0001', message = 'entry_request_already_consumed';
  end if;

  if (
    select pg_catalog.count(*) from private.entry_capture_usage as usage
    where usage.user_id = new.user_id
      and usage.reserved_at >= pg_catalog.now() - interval '24 hours'
  ) >= 30 then
    raise exception using
      errcode = 'P0001', message = 'entry_daily_quota_exceeded';
  end if;
  if (
    select pg_catalog.count(*) from public.entries
    where user_id = new.user_id
      and status in ('queued', 'transcribing', 'analyzing')
  ) >= 5 then
    raise exception using
      errcode = 'P0001', message = 'entry_concurrency_quota_exceeded';
  end if;

  insert into private.entry_capture_usage (user_id, client_request_id)
  values (new.user_id, new.client_request_id);
  return new;
end;
$$;

revoke all on function private.enforce_entry_capture_quota()
  from public, anon, authenticated, service_role;

-- A correction is a candidate revision of an already valid meal. Keep the
-- prior provider metadata while it runs and automatically restore visibility
-- if any processing failure path (including exhausted leases) tries to make
-- that prior revision terminally failed.
create or replace function private.preserve_entry_reanalysis_revision()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if old.status = 'complete'
    and new.status = 'queued'
    and new.analysis_context is not null then
    new.provider_response_id := old.provider_response_id;
    new.processed_at := old.processed_at;
  elsif new.status = 'failed'
    and old.status in ('queued', 'transcribing', 'analyzing')
    and old.analysis_context is not null then
    new.status := 'complete';
    new.status_message := 'Correction not applied — previous estimate kept';
    new.analysis_preview := null;
    new.lease_expires_at := null;
    new.upload_token := null;
  end if;
  return new;
end;
$$;

revoke all on function private.preserve_entry_reanalysis_revision()
  from public, anon, authenticated, service_role;

drop trigger if exists entries_preserve_reanalysis_revision on public.entries;
create trigger entries_preserve_reanalysis_revision
before update of status on public.entries
for each row execute function private.preserve_entry_reanalysis_revision();

-- Onboarding claims use a renewable, fenced lease. Defaults keep the previous
-- direct-insert function compatible during deployment; the new RPC below is
-- the canonical path and can reclaim an interrupted request safely.
alter table public.onboarding_analyses
  add column if not exists generation_attempt smallint not null default 1,
  add column if not exists last_claimed_at timestamptz not null default now(),
  add column if not exists lease_expires_at timestamptz;

update public.onboarding_analyses
set lease_expires_at = coalesce(
  lease_expires_at,
  created_at + interval '135 seconds'
)
where status = 'analyzing';

update public.onboarding_analyses
set lease_expires_at = null
where status <> 'analyzing';

alter table public.onboarding_analyses
  drop constraint if exists onboarding_analyses_generation_attempt_check,
  drop constraint if exists onboarding_analyses_lease_state_check,
  add constraint onboarding_analyses_generation_attempt_check
    check (generation_attempt between 1 and 3),
  add constraint onboarding_analyses_lease_state_check check (
    (status = 'analyzing' and lease_expires_at is not null)
    or (status <> 'analyzing' and lease_expires_at is null)
  );

alter table public.onboarding_analyses
  alter column lease_expires_at set default (now() + interval '135 seconds');

create index if not exists onboarding_analyses_user_claimed_idx
  on public.onboarding_analyses (user_id, last_claimed_at desc);

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
  if coalesce((
    select pg_catalog.sum(onboarding.generation_attempt)
    from public.onboarding_analyses as onboarding
    where onboarding.user_id = new.user_id
      and onboarding.last_claimed_at >= pg_catalog.now() - interval '24 hours'
  ), 0) >= 3 then
    raise exception using
      errcode = 'P0001', message = 'onboarding_daily_quota_exceeded';
  end if;
  if exists (
    select 1 from public.onboarding_analyses
    where user_id = new.user_id
      and status = 'analyzing'
      and lease_expires_at > pg_catalog.now()
  ) then
    raise exception using
      errcode = 'P0001', message = 'onboarding_concurrency_quota_exceeded';
  end if;
  return new;
end;
$$;

revoke all on function private.enforce_onboarding_quota()
  from public, anon, authenticated, service_role;

create or replace function public.claim_onboarding_analysis(
  p_user_id uuid,
  p_client_request_id uuid,
  p_timezone_snapshot text,
  p_analysis_model text
)
returns table(
  onboarding_id uuid,
  transcript text,
  timezone_snapshot text,
  recommendation jsonb,
  final_values jsonb,
  status text,
  generation_attempt smallint,
  lease_expires_at timestamptz,
  claimed boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing public.onboarding_analyses%rowtype;
  recent_attempts bigint;
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shudo-onboarding:' || p_user_id::text, 0)
  );

  update public.onboarding_analyses as stale
  set status = 'failed',
      lease_expires_at = null,
      error_message = 'Onboarding attempt expired before it finished'
  where stale.user_id = p_user_id
    and stale.client_request_id <> p_client_request_id
    and stale.status = 'analyzing'
    and stale.lease_expires_at <= pg_catalog.now();

  select onboarding.*
  into existing
  from public.onboarding_analyses as onboarding
  where onboarding.user_id = p_user_id
    and onboarding.client_request_id = p_client_request_id
  for update of onboarding;

  if found then
    if existing.status <> 'analyzing' then
      return query select
        existing.id, existing.transcript, existing.timezone_snapshot,
        existing.recommendation, existing.final_values, existing.status,
        existing.generation_attempt, existing.lease_expires_at, false;
      return;
    end if;
    if existing.lease_expires_at > pg_catalog.now() then
      return query select
        existing.id, existing.transcript, existing.timezone_snapshot,
        existing.recommendation, existing.final_values, existing.status,
        existing.generation_attempt, existing.lease_expires_at, false;
      return;
    end if;
    if existing.generation_attempt >= 3 then
      update public.onboarding_analyses
      set status = 'failed',
          lease_expires_at = null,
          error_message = 'Onboarding retry limit reached'
      where id = existing.id;
      return query select
        existing.id, existing.transcript, existing.timezone_snapshot,
        existing.recommendation, existing.final_values, 'failed'::text,
        existing.generation_attempt, null::timestamptz, false;
      return;
    end if;
  end if;

  select coalesce(pg_catalog.sum(onboarding.generation_attempt), 0)
  into recent_attempts
  from public.onboarding_analyses as onboarding
  where onboarding.user_id = p_user_id
    and onboarding.last_claimed_at >= pg_catalog.now() - interval '24 hours';
  if recent_attempts >= 3 then
    raise exception using
      errcode = 'P0001', message = 'onboarding_daily_quota_exceeded';
  end if;
  if exists (
    select 1 from public.onboarding_analyses as active
    where active.user_id = p_user_id
      and active.status = 'analyzing'
      and active.lease_expires_at > pg_catalog.now()
      and active.client_request_id <> p_client_request_id
  ) then
    raise exception using
      errcode = 'P0001', message = 'onboarding_concurrency_quota_exceeded';
  end if;

  if existing.id is not null then
    update public.onboarding_analyses as onboarding
    set transcript = null,
        timezone_snapshot = p_timezone_snapshot,
        recommendation = null,
        final_values = null,
        status = 'analyzing',
        generation_attempt = onboarding.generation_attempt + 1,
        last_claimed_at = pg_catalog.now(),
        lease_expires_at = pg_catalog.now() + interval '135 seconds',
        provider_response_id = null,
        error_message = null,
        applied_at = null,
        analysis_model = p_analysis_model
    where onboarding.id = existing.id
    returning onboarding.id, onboarding.transcript,
      onboarding.timezone_snapshot, onboarding.recommendation,
      onboarding.final_values, onboarding.status,
      onboarding.generation_attempt, onboarding.lease_expires_at, true
    into onboarding_id, transcript, timezone_snapshot, recommendation,
      final_values, status, generation_attempt, lease_expires_at, claimed;
  else
    insert into public.onboarding_analyses (
      user_id,
      client_request_id,
      timezone_snapshot,
      status,
      analysis_model,
      generation_attempt,
      last_claimed_at,
      lease_expires_at
    ) values (
      p_user_id,
      p_client_request_id,
      p_timezone_snapshot,
      'analyzing',
      p_analysis_model,
      1,
      pg_catalog.now(),
      pg_catalog.now() + interval '135 seconds'
    )
    returning id, public.onboarding_analyses.transcript,
      public.onboarding_analyses.timezone_snapshot,
      public.onboarding_analyses.recommendation,
      public.onboarding_analyses.final_values,
      public.onboarding_analyses.status,
      public.onboarding_analyses.generation_attempt,
      public.onboarding_analyses.lease_expires_at, true
    into onboarding_id, transcript, timezone_snapshot, recommendation,
      final_values, status, generation_attempt, lease_expires_at, claimed;
  end if;

  return next;
end;
$$;

revoke all on function public.claim_onboarding_analysis(uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.claim_onboarding_analysis(uuid, uuid, text, text)
  to service_role;

-- The absent-row path is protected by a transaction-scoped advisory lock.
-- The target portion of the fingerprint includes only the target effective at
-- the start of this week and changes within it, avoiding unrelated profile
-- edits and later target changes from spending another model call.
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
  first_target_day date;
begin
  if extract(isodow from p_week_start) <> 1 then
    raise exception using errcode = '22023', message = 'week_start must be a Monday';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'shudo-weekly:' || p_user_id::text || ':' || p_week_start::text,
      0
    )
  );

  if not exists (
    select 1 from public.profiles
    where user_id = p_user_id
      and weekly_summary_enabled
  ) then
    return;
  end if;

  select pg_catalog.count(*)
  into entry_count
  from public.entries
  where user_id = p_user_id
    and local_day >= p_week_start
    and local_day < p_week_start + 7
    and status = 'complete';
  if entry_count = 0 then
    return;
  end if;

  select pg_catalog.max(target.target_day)
  into first_target_day
  from public.daily_targets as target
  where target.user_id = p_user_id
    and target.target_day <= p_week_start;
  first_target_day := coalesce(first_target_day, p_week_start);

  select pg_catalog.encode(extensions.digest(
    pg_catalog.concat_ws('|',
      p_user_id::text,
      p_week_start::text,
      entry_count::text,
      coalesce((
        select pg_catalog.string_agg(
          pg_catalog.concat_ws('~',
            target.target_day::text,
            target.calories_kcal::text,
            target.protein_g::text,
            target.carbs_g::text,
            target.fat_g::text
          ),
          '|' order by target.target_day
        )
        from public.daily_targets as target
        where target.user_id = p_user_id
          and target.target_day >= first_target_day
          and target.target_day < p_week_start + 7
      ), 'fallback~' || profile.daily_macro_target::text),
      coalesce((
        select pg_catalog.string_agg(
          pg_catalog.concat_ws('~',
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
  where profile.user_id = p_user_id;

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
    and existing.lease_expires_at > pg_catalog.now() then
    return;
  end if;
  if found
    and existing.input_fingerprint = fingerprint
    and existing.generation_attempt >= 3
    and existing.updated_at > pg_catalog.now() - interval '24 hours' then
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
    pg_catalog.now() + interval '120 seconds',
    null
  )
  on conflict (user_id, week_start) do update
  set status = 'generating',
      input_fingerprint = excluded.input_fingerprint,
      generation_attempt = case
        when public.weekly_summaries.input_fingerprint
          is distinct from excluded.input_fingerprint then 1
        when public.weekly_summaries.generation_attempt >= 3 then 1
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
