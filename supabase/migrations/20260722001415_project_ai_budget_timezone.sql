-- Put a project-wide circuit breaker in front of model-backed workflows. The
-- per-user limits remain in place; this private ledger protects the shared
-- friend beta if many valid accounts are active at once.
create table private.ai_job_usage (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  operation text not null,
  request_key text not null,
  attempt smallint not null,
  reserved_at timestamptz not null default pg_catalog.now(),
  constraint ai_job_usage_operation_check check (
    operation in (
      'meal_analysis',
      'onboarding',
      'entry_correction',
      'weekly_summary'
    )
  ),
  constraint ai_job_usage_request_key_check check (
    request_key = pg_catalog.btrim(request_key)
    and char_length(request_key) between 1 and 256
  ),
  constraint ai_job_usage_attempt_check check (attempt between 1 and 20)
);

-- user_id becomes null when an account is deleted, preserving anonymous spend
-- history while removing the durable account identifier. Active users retain
-- strict idempotency across retries.
create unique index ai_job_usage_idempotency_idx
  on private.ai_job_usage (operation, user_id, request_key, attempt)
  where user_id is not null;
create index ai_job_usage_user_idx
  on private.ai_job_usage (user_id)
  where user_id is not null;
create index ai_job_usage_reserved_idx
  on private.ai_job_usage (reserved_at desc);
create index ai_job_usage_operation_reserved_idx
  on private.ai_job_usage (operation, reserved_at desc);

alter table private.ai_job_usage enable row level security;
revoke all on table private.ai_job_usage
  from public, anon, authenticated, service_role;

comment on table private.ai_job_usage is
  'Private, durable reservations for Shudo model-backed workflows; rows are never exposed through the Data API.';

create or replace function private.reserve_ai_job_usage(
  p_operation text,
  p_user_id uuid,
  p_request_key text,
  p_attempt smallint
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_operation text := pg_catalog.btrim(coalesce(p_operation, ''));
  normalized_request_key text := pg_catalog.btrim(coalesce(p_request_key, ''));
  operation_limit integer;
  project_limit constant integer := 180;
begin
  operation_limit := case normalized_operation
    when 'meal_analysis' then 100
    when 'onboarding' then 25
    when 'entry_correction' then 60
    when 'weekly_summary' then 25
    else null
  end;
  if operation_limit is null
    or p_user_id is null
    or char_length(normalized_request_key) not between 1 and 256
    or p_attempt not between 1 and 20 then
    raise exception using
      errcode = '22023', message = 'AI job reservation is invalid';
  end if;

  -- Every project reservation shares one transaction lock. The ledger is tiny
  -- at beta scale, and serializing this decision prevents concurrent requests
  -- from crossing either the operation cap or the total rolling cap.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shudo-project-ai-budget-v1', 0)
  );

  if exists (
    select 1
    from private.ai_job_usage as usage
    where usage.operation = normalized_operation
      and usage.user_id = p_user_id
      and usage.request_key = normalized_request_key
      and usage.attempt = p_attempt
  ) then
    return false;
  end if;

  if (
    select pg_catalog.count(*)
    from private.ai_job_usage as usage
    where usage.reserved_at >= pg_catalog.now() - interval '24 hours'
  ) >= project_limit
    or (
      select pg_catalog.count(*)
      from private.ai_job_usage as usage
      where usage.operation = normalized_operation
        and usage.reserved_at >= pg_catalog.now() - interval '24 hours'
    ) >= operation_limit then
    raise exception using
      errcode = 'P0001', message = 'project_ai_budget_exceeded';
  end if;

  insert into private.ai_job_usage (
    user_id,
    operation,
    request_key,
    attempt
  ) values (
    p_user_id,
    normalized_operation,
    normalized_request_key,
    p_attempt
  );
  return true;
end;
$$;

revoke all on function private.reserve_ai_job_usage(text, uuid, text, smallint)
  from public, anon, authenticated, service_role;

-- Preserve the recent workflow history that existed before this migration.
-- Backfills bypass the new reservation function intentionally: deploying a
-- breaker must not fail just because the preceding 24 hours were busy.
insert into private.ai_job_usage (
  user_id, operation, request_key, attempt, reserved_at
)
select
  entry.user_id,
  'meal_analysis',
  entry.client_request_id::text,
  1,
  entry.created_at
from public.entries as entry
on conflict do nothing;

insert into private.ai_job_usage (
  user_id, operation, request_key, attempt, reserved_at
)
select
  onboarding.user_id,
  'onboarding',
  onboarding.client_request_id::text,
  attempt_no::smallint,
  onboarding.last_claimed_at
from public.onboarding_analyses as onboarding
cross join lateral pg_catalog.generate_series(
  1,
  onboarding.generation_attempt
) as attempts(attempt_no)
on conflict do nothing;

insert into private.ai_job_usage (
  user_id, operation, request_key, attempt, reserved_at
)
select
  correction.user_id,
  'entry_correction',
  correction.id::text,
  1,
  correction.created_at
from public.entry_corrections as correction
where correction.request_id is null
on conflict do nothing;

insert into private.ai_job_usage (
  user_id, operation, request_key, attempt, reserved_at
)
select
  request.user_id,
  'entry_correction',
  request.client_request_id::text,
  attempt_no::smallint,
  request.last_claimed_at
from public.entry_correction_requests as request
cross join lateral pg_catalog.generate_series(
  1,
  request.generation_attempt
) as attempts(attempt_no)
on conflict do nothing;

insert into private.ai_job_usage (
  user_id, operation, request_key, attempt, reserved_at
)
select
  summary.user_id,
  'weekly_summary',
  summary.week_start::text || ':' || summary.input_fingerprint || ':'
    || summary.updated_at::text,
  attempt_no::smallint,
  summary.updated_at
from public.weekly_summaries as summary
cross join lateral pg_catalog.generate_series(
  1,
  summary.generation_attempt
) as attempts(attempt_no)
on conflict do nothing;

create or replace function private.reserve_entry_ai_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  legacy_correction_id uuid;
begin
  if tg_op = 'INSERT' then
    -- Reserve the first model attempt before the capture is accepted. The first
    -- processing claim reuses this exact key, so dispatch remains idempotent.
    perform private.reserve_ai_job_usage(
      'meal_analysis',
      new.user_id,
      new.client_request_id::text,
      1::smallint
    );
  elsif new.processing_attempts > old.processing_attempts
    and new.status in ('transcribing', 'analyzing') then
    -- Current clients apply corrections without re-queuing the entry. Older
    -- clients use entry_corrections + the original processor, so key those
    -- attempts to the latest durable correction revision instead of colliding
    -- with the entry's original meal-analysis attempts.
    select correction.id
    into legacy_correction_id
    from public.entry_corrections as correction
    where correction.user_id = new.user_id
      and correction.entry_id = new.id
      and correction.request_id is null
    order by correction.sequence_no desc
    limit 1;

    if legacy_correction_id is null then
      perform private.reserve_ai_job_usage(
        'meal_analysis',
        new.user_id,
        new.client_request_id::text,
        new.processing_attempts
      );
    else
      perform private.reserve_ai_job_usage(
        'entry_correction',
        new.user_id,
        legacy_correction_id::text,
        new.processing_attempts
      );
    end if;
  end if;
  return new;
end;
$$;

create or replace function private.reserve_onboarding_ai_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform private.reserve_ai_job_usage(
      'onboarding',
      new.user_id,
      new.client_request_id::text,
      new.generation_attempt
    );
  elsif new.generation_attempt > old.generation_attempt then
    perform private.reserve_ai_job_usage(
      'onboarding',
      new.user_id,
      new.client_request_id::text,
      new.generation_attempt
    );
  end if;
  return new;
end;
$$;

create or replace function private.reserve_correction_request_ai_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform private.reserve_ai_job_usage(
      'entry_correction',
      new.user_id,
      new.client_request_id::text,
      new.generation_attempt
    );
  elsif new.generation_attempt > old.generation_attempt then
    perform private.reserve_ai_job_usage(
      'entry_correction',
      new.user_id,
      new.client_request_id::text,
      new.generation_attempt
    );
  end if;
  return new;
end;
$$;

create or replace function private.reserve_legacy_correction_ai_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.reserve_ai_job_usage(
    'entry_correction',
    new.user_id,
    new.id::text,
    1::smallint
  );
  return new;
end;
$$;

create or replace function private.reserve_weekly_summary_ai_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    perform private.reserve_ai_job_usage(
      'weekly_summary',
      new.user_id,
      new.week_start::text || ':' || new.input_fingerprint || ':'
        || new.updated_at::text,
      new.generation_attempt
    );
  elsif new.status = 'generating'
    and (
      old.status is distinct from new.status
      or old.generation_attempt is distinct from new.generation_attempt
      or old.input_fingerprint is distinct from new.input_fingerprint
    ) then
    perform private.reserve_ai_job_usage(
      'weekly_summary',
      new.user_id,
      new.week_start::text || ':' || new.input_fingerprint || ':'
        || new.updated_at::text,
      new.generation_attempt
    );
  end if;
  return new;
end;
$$;

revoke all on function private.reserve_entry_ai_job()
  from public, anon, authenticated, service_role;
revoke all on function private.reserve_onboarding_ai_job()
  from public, anon, authenticated, service_role;
revoke all on function private.reserve_correction_request_ai_job()
  from public, anon, authenticated, service_role;
revoke all on function private.reserve_legacy_correction_ai_job()
  from public, anon, authenticated, service_role;
revoke all on function private.reserve_weekly_summary_ai_job()
  from public, anon, authenticated, service_role;

drop trigger if exists entries_reserve_ai_job on public.entries;
create trigger entries_reserve_ai_job
after insert on public.entries
for each row execute function private.reserve_entry_ai_job();

-- The reservation runs inside claim_entry_processing's UPDATE transaction.
-- Exceeding either project cap raises before that claim can commit, so no worker
-- can reach a provider call without a durable reservation for this exact try.
drop trigger if exists entries_reserve_processing_ai_job on public.entries;
create trigger entries_reserve_processing_ai_job
after update of processing_attempts on public.entries
for each row execute function private.reserve_entry_ai_job();

drop trigger if exists onboarding_analyses_reserve_ai_job
  on public.onboarding_analyses;
create trigger onboarding_analyses_reserve_ai_job
after insert or update of generation_attempt on public.onboarding_analyses
for each row execute function private.reserve_onboarding_ai_job();

drop trigger if exists entry_correction_requests_reserve_ai_job
  on public.entry_correction_requests;
create trigger entry_correction_requests_reserve_ai_job
after insert or update of generation_attempt
on public.entry_correction_requests
for each row execute function private.reserve_correction_request_ai_job();

drop trigger if exists entry_corrections_reserve_ai_job
  on public.entry_corrections;
create trigger entry_corrections_reserve_ai_job
after insert on public.entry_corrections
for each row
when (new.request_id is null)
execute function private.reserve_legacy_correction_ai_job();

drop trigger if exists weekly_summaries_reserve_ai_job
  on public.weekly_summaries;
create trigger weekly_summaries_reserve_ai_job
after insert or update of status, generation_attempt, input_fingerprint
on public.weekly_summaries
for each row execute function private.reserve_weekly_summary_ai_job();

-- Store only valid canonical/linked IANA zone identifiers (plus UTC/GMT). This is
-- enforced inside Postgres as well as in the clients so malformed direct Data
-- API writes cannot poison local-day and weekly-summary calculations.
create or replace function private.profile_timezone_is_valid(p_timezone text)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select p_timezone is not null
    and p_timezone = pg_catalog.btrim(p_timezone)
    and (
      p_timezone in ('UTC', 'GMT')
      or (
        p_timezone ~ '^[A-Za-z_+-]+(/[A-Za-z0-9_+.-]+)+$'
        and p_timezone not like 'posix/%'
        and p_timezone not like 'right/%'
      )
    )
    and exists (
      select 1
      from pg_catalog.pg_timezone_names as timezone
      where timezone.name = p_timezone
    );
$$;

revoke all on function private.profile_timezone_is_valid(text)
  from public, anon, authenticated, service_role;

-- A legacy backup may contain a malformed identifier. UTC is the only safe
-- repair because the original intended zone cannot be inferred.
update public.profiles
set timezone = 'UTC'
where not private.profile_timezone_is_valid(timezone);

create or replace function private.enforce_profile_timezone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not private.profile_timezone_is_valid(new.timezone) then
    raise exception using
      errcode = '22023', message = 'profile_timezone_invalid';
  end if;
  return new;
end;
$$;

revoke all on function private.enforce_profile_timezone()
  from public, anon, authenticated, service_role;

drop trigger if exists profiles_enforce_timezone on public.profiles;
create trigger profiles_enforce_timezone
before insert or update of timezone on public.profiles
for each row execute function private.enforce_profile_timezone();
