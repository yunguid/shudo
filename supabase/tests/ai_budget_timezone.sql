-- Project-wide spend and timezone invariants. Keep all fixture mutations in a
-- transaction so this suite can safely run at the end of fresh and legacy
-- schema verification.
begin;

insert into auth.users (id, email)
values
  ('00000000-0000-4000-8000-000000000090', 'budget@example.test'),
  ('00000000-0000-4000-8000-000000000091', 'meal-retry-budget@example.test'),
  ('00000000-0000-4000-8000-000000000092', 'meal-operation-cap@example.test'),
  ('00000000-0000-4000-8000-000000000093', 'meal-project-cap@example.test'),
  ('00000000-0000-4000-8000-000000000094', 'correction-retry-budget@example.test'),
  ('00000000-0000-4000-8000-000000000095', 'non-processing-transition@example.test');

insert into public.beta_signup_allowlist (email, note)
values
  ('budget@example.test', 'AI-budget fixture'),
  ('meal-retry-budget@example.test', 'AI-budget fixture'),
  ('meal-operation-cap@example.test', 'AI-budget fixture'),
  ('meal-project-cap@example.test', 'AI-budget fixture'),
  ('correction-retry-budget@example.test', 'AI-budget fixture'),
  ('non-processing-transition@example.test', 'AI-budget fixture')
on conflict (email) do update set enabled = true;

do $$
declare
  budget_user constant uuid := '00000000-0000-4000-8000-000000000090';
  first_reservation boolean;
  replayed_reservation boolean;
  reservation_count integer;
begin
  if has_table_privilege(
    'anon', 'private.ai_job_usage', 'select'
  ) or has_table_privilege(
    'authenticated', 'private.ai_job_usage', 'select'
  ) or has_table_privilege(
    'service_role', 'private.ai_job_usage', 'select'
  ) then
    raise exception 'private AI usage ledger leaked a Data API grant';
  end if;
  if has_function_privilege(
    'authenticated',
    'private.reserve_ai_job_usage(text, uuid, text, smallint)',
    'execute'
  ) or has_function_privilege(
    'service_role',
    'private.reserve_ai_job_usage(text, uuid, text, smallint)',
    'execute'
  ) then
    raise exception 'AI reservation helper is directly executable by an API role';
  end if;
  if not exists (
    select 1
    from pg_catalog.pg_class as relation
    join pg_catalog.pg_namespace as namespace
      on namespace.oid = relation.relnamespace
    where namespace.nspname = 'private'
      and relation.relname = 'ai_job_usage'
      and relation.relrowsecurity
  ) then
    raise exception 'private AI usage ledger is missing RLS defense in depth';
  end if;

  update private.ai_job_usage
  set reserved_at = pg_catalog.now() - interval '25 hours';

  select private.reserve_ai_job_usage(
    'meal_analysis', budget_user, 'idempotent-request', 1::smallint
  ) into first_reservation;
  select private.reserve_ai_job_usage(
    'meal_analysis', budget_user, 'idempotent-request', 1::smallint
  ) into replayed_reservation;
  select pg_catalog.count(*)
  into reservation_count
  from private.ai_job_usage
  where operation = 'meal_analysis'
    and user_id = budget_user
    and request_key = 'idempotent-request'
    and attempt = 1;
  if not first_reservation or replayed_reservation or reservation_count <> 1 then
    raise exception 'AI reservation idempotency failed';
  end if;

  insert into public.entries (
    user_id, client_request_id, local_day, status
  ) values (
    budget_user,
    '90000000-0000-4000-8000-000000000001',
    '2026-07-21',
    'complete'
  );
  if not exists (
    select 1
    from private.ai_job_usage
    where operation = 'meal_analysis'
      and user_id = budget_user
      and request_key = '90000000-0000-4000-8000-000000000001'
      and attempt = 1
  ) then
    raise exception 'meal creation did not reserve project AI capacity';
  end if;
end;
$$;

do $$
declare
  budget_user constant uuid := '00000000-0000-4000-8000-000000000091';
  request_id constant uuid := '91000000-0000-4000-8000-000000000001';
  entry_id uuid;
  claimed_attempt smallint;
  reservation_count integer;
begin
  update private.ai_job_usage
  set reserved_at = pg_catalog.now() - interval '25 hours';

  insert into public.entries (
    user_id, client_request_id, local_day, status
  ) values (
    budget_user, request_id, '2026-07-21', 'queued'
  ) returning id into entry_id;

  select public.claim_entry_processing(entry_id, budget_user)
  into claimed_attempt;
  if claimed_attempt <> 1 then
    raise exception 'first meal processing claim returned attempt %', claimed_attempt;
  end if;
  select pg_catalog.count(*) into reservation_count
  from private.ai_job_usage
  where operation = 'meal_analysis'
    and user_id = budget_user
    and request_key = request_id::text;
  if reservation_count <> 1 then
    raise exception 'first meal claim duplicated its creation reservation';
  end if;

  -- An active lease is an idempotent no-op and must not spend another slot.
  select public.claim_entry_processing(entry_id, budget_user)
  into claimed_attempt;
  if claimed_attempt is not null then
    raise exception 'active meal lease was unexpectedly replaced';
  end if;
  select pg_catalog.count(*) into reservation_count
  from private.ai_job_usage
  where operation = 'meal_analysis'
    and user_id = budget_user
    and request_key = request_id::text;
  if reservation_count <> 1 then
    raise exception 'active meal lease consumed another AI reservation';
  end if;

  update public.entries
  set lease_expires_at = pg_catalog.now() - interval '1 second'
  where id = entry_id;
  select public.claim_entry_processing(entry_id, budget_user)
  into claimed_attempt;
  if claimed_attempt <> 2 then
    raise exception 'second meal processing claim returned attempt %', claimed_attempt;
  end if;

  update public.entries
  set lease_expires_at = pg_catalog.now() - interval '1 second'
  where id = entry_id;
  select public.claim_entry_processing(entry_id, budget_user)
  into claimed_attempt;
  if claimed_attempt <> 3 then
    raise exception 'third meal processing claim returned attempt %', claimed_attempt;
  end if;

  select pg_catalog.count(*) into reservation_count
  from private.ai_job_usage
  where operation = 'meal_analysis'
    and user_id = budget_user
    and request_key = request_id::text
    and attempt in (1, 2, 3);
  if reservation_count <> 3 then
    raise exception 'meal retries did not reserve attempts 1, 2, and 3';
  end if;
end;
$$;

do $$
declare
  budget_user constant uuid := '00000000-0000-4000-8000-000000000092';
  request_id constant uuid := '92000000-0000-4000-8000-000000000001';
  entry_id uuid;
  fixture_index integer;
  claimed_attempt smallint;
  stored_attempt smallint;
  rejected boolean := false;
begin
  update private.ai_job_usage
  set reserved_at = pg_catalog.now() - interval '25 hours';

  insert into public.entries (
    user_id, client_request_id, local_day, status
  ) values (
    budget_user, request_id, '2026-07-21', 'queued'
  ) returning id into entry_id;
  select public.claim_entry_processing(entry_id, budget_user)
  into claimed_attempt;
  if claimed_attempt <> 1 then
    raise exception 'operation-cap fixture could not claim attempt 1';
  end if;
  update public.entries
  set lease_expires_at = pg_catalog.now() - interval '1 second'
  where id = entry_id;

  for fixture_index in 1..99 loop
    insert into private.ai_job_usage (
      user_id, operation, request_key, attempt
    ) values (
      null,
      'meal_analysis',
      'meal-operation-cap-' || fixture_index::text,
      1
    );
  end loop;

  begin
    perform public.claim_entry_processing(entry_id, budget_user);
  exception when raise_exception then
    rejected := sqlerrm = 'project_ai_budget_exceeded';
  end;
  select processing_attempts into stored_attempt
  from public.entries
  where id = entry_id;
  if not rejected or stored_attempt <> 1 then
    raise exception 'meal operation cap did not prevent processing claim 2';
  end if;
  if exists (
    select 1 from private.ai_job_usage
    where operation = 'meal_analysis'
      and user_id = budget_user
      and request_key = request_id::text
      and attempt = 2
  ) then
    raise exception 'rejected operation-cap claim retained an AI reservation';
  end if;
end;
$$;

do $$
declare
  budget_user constant uuid := '00000000-0000-4000-8000-000000000093';
  request_id constant uuid := '93000000-0000-4000-8000-000000000001';
  entry_id uuid;
  fixture_index integer;
  claimed_attempt smallint;
  stored_attempt smallint;
  rejected boolean := false;
begin
  update private.ai_job_usage
  set reserved_at = pg_catalog.now() - interval '25 hours';

  insert into public.entries (
    user_id, client_request_id, local_day, status
  ) values (
    budget_user, request_id, '2026-07-21', 'queued'
  ) returning id into entry_id;
  select public.claim_entry_processing(entry_id, budget_user)
  into claimed_attempt;
  if claimed_attempt <> 1 then
    raise exception 'project-cap fixture could not claim attempt 1';
  end if;
  update public.entries
  set lease_expires_at = pg_catalog.now() - interval '1 second'
  where id = entry_id;

  for fixture_index in 1..179 loop
    insert into private.ai_job_usage (
      user_id, operation, request_key, attempt
    ) values (
      null,
      'weekly_summary',
      'meal-project-cap-' || fixture_index::text,
      1
    );
  end loop;

  begin
    perform public.claim_entry_processing(entry_id, budget_user);
  exception when raise_exception then
    rejected := sqlerrm = 'project_ai_budget_exceeded';
  end;
  select processing_attempts into stored_attempt
  from public.entries
  where id = entry_id;
  if not rejected or stored_attempt <> 1 then
    raise exception 'project AI cap did not prevent meal processing claim 2';
  end if;
  if exists (
    select 1 from private.ai_job_usage
    where operation = 'meal_analysis'
      and user_id = budget_user
      and request_key = request_id::text
      and attempt = 2
  ) then
    raise exception 'rejected project-cap claim retained an AI reservation';
  end if;
end;
$$;

do $$
declare
  budget_user constant uuid := '00000000-0000-4000-8000-000000000094';
  request_id constant uuid := '94000000-0000-4000-8000-000000000001';
  target_entry_id uuid;
  correction_id uuid;
  transition text;
  claimed_attempt smallint;
  reservation_count integer;
begin
  update private.ai_job_usage
  set reserved_at = pg_catalog.now() - interval '25 hours';

  insert into public.entries (
    user_id, client_request_id, local_day, status,
    title, calories_kcal, protein_g, carbs_g, fat_g
  ) values (
    budget_user, request_id, '2026-07-21', 'complete',
    'Original meal', 500, 30, 50, 20
  ) returning id into target_entry_id;

  select public.prepare_entry_reanalysis(
    target_entry_id,
    budget_user,
    'Add the steak that was missing.'
  ) into transition;
  if transition <> 'queued' then
    raise exception 'legacy correction was not queued: %', transition;
  end if;
  select correction.id into correction_id
  from public.entry_corrections as correction
  where correction.entry_id = target_entry_id
    and correction.user_id = budget_user
    and correction.request_id is null
  order by correction.sequence_no desc
  limit 1;

  select public.claim_entry_processing(target_entry_id, budget_user)
  into claimed_attempt;
  if claimed_attempt <> 1 then
    raise exception 'first correction processing claim returned attempt %', claimed_attempt;
  end if;
  update public.entries
  set lease_expires_at = pg_catalog.now() - interval '1 second'
  where id = target_entry_id;
  select public.claim_entry_processing(target_entry_id, budget_user)
  into claimed_attempt;
  if claimed_attempt <> 2 then
    raise exception 'second correction processing claim returned attempt %', claimed_attempt;
  end if;
  update public.entries
  set lease_expires_at = pg_catalog.now() - interval '1 second'
  where id = target_entry_id;
  select public.claim_entry_processing(target_entry_id, budget_user)
  into claimed_attempt;
  if claimed_attempt <> 3 then
    raise exception 'third correction processing claim returned attempt %', claimed_attempt;
  end if;

  select pg_catalog.count(*) into reservation_count
  from private.ai_job_usage
  where operation = 'entry_correction'
    and user_id = budget_user
    and request_key = correction_id::text
    and attempt in (1, 2, 3);
  if reservation_count <> 3 then
    raise exception 'legacy correction retries did not reserve attempts 1, 2, and 3';
  end if;
end;
$$;

do $$
declare
  budget_user constant uuid := '00000000-0000-4000-8000-000000000095';
  request_id constant uuid := '95000000-0000-4000-8000-000000000001';
  entry_id uuid;
  fixture_index integer;
  repaired boolean;
  stored_attempt smallint;
begin
  update private.ai_job_usage
  set reserved_at = pg_catalog.now() - interval '25 hours';

  insert into public.entries (
    user_id,
    client_request_id,
    local_day,
    status,
    intended_image,
    occurred_at,
    created_at
  ) values (
    budget_user,
    request_id,
    '2026-07-21',
    'queued',
    true,
    pg_catalog.now() - interval '10 minutes',
    pg_catalog.now() - interval '10 minutes'
  ) returning id into entry_id;

  for fixture_index in 1..99 loop
    insert into private.ai_job_usage (
      user_id, operation, request_key, attempt
    ) values (
      null,
      'meal_analysis',
      'non-processing-cap-' || fixture_index::text,
      1
    );
  end loop;

  select public.fail_stale_incomplete_entry(entry_id, budget_user)
  into repaired;
  select processing_attempts into stored_attempt
  from public.entries
  where id = entry_id;
  if not repaired or stored_attempt <> 3 then
    raise exception 'non-processing repair was incorrectly blocked by the AI cap';
  end if;
  if exists (
    select 1 from private.ai_job_usage
    where operation = 'meal_analysis'
      and user_id = budget_user
      and request_key = request_id::text
      and attempt = 3
  ) then
    raise exception 'non-processing repair consumed an AI reservation';
  end if;
end;
$$;

do $$
declare
  budget_user constant uuid := '00000000-0000-4000-8000-000000000090';
  fixture_index integer;
  rejected boolean := false;
begin
  update private.ai_job_usage
  set reserved_at = pg_catalog.now() - interval '25 hours';
  for fixture_index in 1..25 loop
    insert into private.ai_job_usage (
      user_id, operation, request_key, attempt
    ) values (
      null,
      'weekly_summary',
      'operation-cap-' || fixture_index::text,
      1
    );
  end loop;

  begin
    perform private.reserve_ai_job_usage(
      'weekly_summary', budget_user, 'operation-cap-rejected', 1::smallint
    );
  exception when raise_exception then
    rejected := sqlerrm = 'project_ai_budget_exceeded';
  end;
  if not rejected then
    raise exception 'weekly operation cap accepted reservation 26';
  end if;
end;
$$;

do $$
declare
  budget_user constant uuid := '00000000-0000-4000-8000-000000000090';
  fixture_index integer;
  accepted boolean;
  replayed boolean;
  rejected boolean := false;
begin
  update private.ai_job_usage
  set reserved_at = pg_catalog.now() - interval '25 hours';
  for fixture_index in 1..179 loop
    insert into private.ai_job_usage (
      user_id, operation, request_key, attempt
    ) values (
      null,
      'meal_analysis',
      'project-cap-' || fixture_index::text,
      1
    );
  end loop;

  select private.reserve_ai_job_usage(
    'weekly_summary', budget_user, 'project-cap-last-slot', 1::smallint
  ) into accepted;
  select private.reserve_ai_job_usage(
    'weekly_summary', budget_user, 'project-cap-last-slot', 1::smallint
  ) into replayed;
  begin
    perform private.reserve_ai_job_usage(
      'weekly_summary', budget_user, 'project-cap-rejected', 1::smallint
    );
  exception when raise_exception then
    rejected := sqlerrm = 'project_ai_budget_exceeded';
  end;
  if not accepted or replayed or not rejected then
    raise exception 'project AI cap or full-budget idempotency failed';
  end if;
end;
$$;

do $$
declare
  budget_user constant uuid := '00000000-0000-4000-8000-000000000090';
  rejected boolean := false;
  stored_timezone text;
begin
  update public.profiles
  set timezone = 'America/New_York'
  where user_id = budget_user;

  begin
    update public.profiles
    set timezone = 'Mars/Olympus_Mons'
    where user_id = budget_user;
  exception when invalid_parameter_value then
    rejected := sqlerrm = 'profile_timezone_invalid';
  end;
  select timezone into stored_timezone
  from public.profiles
  where user_id = budget_user;
  if not rejected or stored_timezone <> 'America/New_York' then
    raise exception 'invalid profile timezone was stored or mutated valid data';
  end if;
  if private.profile_timezone_is_valid('PST')
    or not private.profile_timezone_is_valid('Etc/GMT+5')
    or not private.profile_timezone_is_valid('GMT') then
    raise exception 'profile timezone validator accepted an abbreviation or rejected IANA data';
  end if;
end;
$$;

rollback;
