-- Deterministic database checks for the additive multi-user/model-backed
-- boundaries. This file is included after fresh_schema's core fixtures.
insert into auth.users (id, email)
values
  ('00000000-0000-4000-8000-000000000003', 'quota@example.test'),
  ('00000000-0000-4000-8000-000000000004', 'lease@example.test');

insert into public.beta_signup_allowlist (email, note)
values
  ('quota@example.test', 'Account-feature fixture'),
  ('lease@example.test', 'Account-feature fixture')
on conflict (email) do update set enabled = true;

do $$
declare
  quota_user constant uuid := '00000000-0000-4000-8000-000000000003';
  consumed_request constant uuid := '30000000-0000-4000-8000-000000000001';
  fixture_index integer;
  rejected boolean := false;
begin
  for fixture_index in 1..30 loop
    insert into public.entries (user_id, client_request_id, local_day, status)
    values (
      quota_user,
      gen_random_uuid(),
      date '2025-01-01' + fixture_index,
      'complete'
    );
  end loop;
  begin
    insert into public.entries (user_id, client_request_id, local_day, status)
    values (quota_user, gen_random_uuid(), '2035-12-31', 'complete');
  exception when raise_exception then
    rejected := sqlerrm = 'entry_daily_quota_exceeded';
  end;
  if not rejected then
    raise exception 'daily capture quota accepted entry 31';
  end if;

  delete from public.entries where user_id = quota_user;
  update private.entry_capture_usage
  set reserved_at = now() - interval '25 hours'
  where user_id = quota_user;

  insert into public.entries (user_id, client_request_id, local_day, status)
  values (quota_user, consumed_request, '2026-12-29', 'complete');
  delete from public.entries
  where user_id = quota_user and client_request_id = consumed_request;
  rejected := false;
  begin
    insert into public.entries (user_id, client_request_id, local_day, status)
    values (quota_user, consumed_request, '2026-12-30', 'complete');
  exception when raise_exception then
    rejected := sqlerrm = 'entry_request_already_consumed';
  end;
  if not rejected then
    raise exception 'deleted capture request id was reusable';
  end if;

  for fixture_index in 1..5 loop
    insert into public.entries (user_id, client_request_id, local_day, status)
    values (quota_user, gen_random_uuid(), '2026-12-30', 'queued');
  end loop;
  rejected := false;
  begin
    insert into public.entries (user_id, client_request_id, local_day, status)
    values (quota_user, gen_random_uuid(), '2026-12-30', 'queued');
  exception when raise_exception then
    rejected := sqlerrm = 'entry_concurrency_quota_exceeded';
  end;
  if not rejected then
    raise exception 'active capture quota accepted entry 6';
  end if;

  delete from public.entries where user_id = quota_user;
  for fixture_index in 1..3 loop
    insert into public.onboarding_analyses (
      user_id, client_request_id, timezone_snapshot, status, analysis_model,
      lease_expires_at
    ) values (
      quota_user, gen_random_uuid(), 'UTC', 'failed', 'gpt-5.6-sol', null
    );
  end loop;
  rejected := false;
  begin
    insert into public.onboarding_analyses (
      user_id, client_request_id, timezone_snapshot, status, analysis_model,
      lease_expires_at
    ) values (
      quota_user, gen_random_uuid(), 'UTC', 'failed', 'gpt-5.6-sol', null
    );
  exception when raise_exception then
    rejected := sqlerrm = 'onboarding_daily_quota_exceeded';
  end;
  if not rejected then
    raise exception 'onboarding quota accepted attempt 4';
  end if;
end;
$$;

do $$
declare
  lease_user constant uuid := '00000000-0000-4000-8000-000000000004';
  first_request constant uuid := '40000000-0000-4000-8000-000000000001';
  second_request constant uuid := '40000000-0000-4000-8000-000000000002';
  claim_count integer;
  claimed_value boolean;
  attempt_value smallint;
begin
  select count(*), bool_or(claimed), max(generation_attempt)
  into claim_count, claimed_value, attempt_value
  from public.claim_onboarding_analysis(
    lease_user, first_request, 'UTC', 'gpt-5.6-sol'
  );
  if claim_count <> 1 or not claimed_value or attempt_value <> 1 then
    raise exception 'first onboarding lease was not claimed';
  end if;

  select bool_or(claimed) into claimed_value
  from public.claim_onboarding_analysis(
    lease_user, first_request, 'UTC', 'gpt-5.6-sol'
  );
  if claimed_value then
    raise exception 'live onboarding lease was claimed twice';
  end if;

  update public.onboarding_analyses
  set lease_expires_at = now() - interval '1 second'
  where user_id = lease_user and client_request_id = first_request;
  select bool_or(claimed), max(generation_attempt)
  into claimed_value, attempt_value
  from public.claim_onboarding_analysis(
    lease_user, first_request, 'UTC', 'gpt-5.6-sol'
  );
  if not claimed_value or attempt_value <> 2 then
    raise exception 'stale onboarding lease was not reclaimed';
  end if;

  update public.onboarding_analyses
  set lease_expires_at = now() - interval '1 second'
  where user_id = lease_user and client_request_id = first_request;
  select bool_or(claimed) into claimed_value
  from public.claim_onboarding_analysis(
    lease_user, second_request, 'UTC', 'gpt-5.6-sol'
  );
  if not claimed_value then
    raise exception 'expired onboarding row blocked a new request forever';
  end if;
  if not exists (
    select 1 from public.onboarding_analyses
    where user_id = lease_user
      and client_request_id = first_request
      and status = 'failed'
      and lease_expires_at is null
  ) then
    raise exception 'expired onboarding row was not terminalized';
  end if;
end;
$$;

do $$
declare
  owner_id constant uuid := '00000000-0000-4000-8000-000000000001';
  other_id constant uuid := '00000000-0000-4000-8000-000000000002';
  meal_id uuid;
  rollback_meal_id uuid;
  transition text;
  claim_count integer;
  stored_attempt smallint;
  profile_target_day date;
  invalid_target_rejected boolean := false;
begin
  select id into meal_id from public.entries
  where user_id = owner_id
    and client_request_id = '10000000-0000-4000-8000-000000000001';

  select public.prepare_entry_reanalysis(
    meal_id, other_id, 'Wrong owner must not update this meal.'
  ) into transition;
  if transition <> 'not_found' then
    raise exception 'reanalysis crossed owner boundary: %', transition;
  end if;
  select public.prepare_entry_reanalysis(
    meal_id, owner_id, 'This was two servings, not one.'
  ) into transition;
  if transition <> 'queued' then
    raise exception 'completed meal was not requeued: %', transition;
  end if;
  update public.entries
  set status = 'complete', status_message = 'Ready'
  where id = meal_id;
  select public.prepare_entry_reanalysis(
    meal_id, owner_id, 'Also include the sauce.'
  ) into transition;
  if transition <> 'queued' then
    raise exception 'second correction was not queued: %', transition;
  end if;
  if not exists (
    select 1 from public.entries
    where id = meal_id
      and strpos(analysis_context, 'This was two servings, not one.') > 0
      and strpos(analysis_context, 'Also include the sauce.') > 0
      and strpos(analysis_context, 'Also include the sauce.')
        < strpos(analysis_context, 'This was two servings, not one.')
  ) then
    raise exception 'second correction replaced rather than refined the first';
  end if;
  select public.prepare_entry_reanalysis(
    meal_id, owner_id, 'Duplicate correction while active.'
  ) into transition;
  if transition <> 'busy' then
    raise exception 'active correction was not fenced: %', transition;
  end if;

  update public.entries
  set status = 'complete', status_message = 'Ready', analysis_context = null
  where id = meal_id;
  delete from public.entry_corrections where entry_id = meal_id;

  insert into public.entries (
    user_id,
    client_request_id,
    local_day,
    status,
    status_message,
    title,
    protein_g,
    carbs_g,
    fat_g,
    calories_kcal,
    provider_response_id,
    processed_at
  ) values (
    owner_id,
    '10000000-0000-4000-8000-000000000099',
    '2026-07-19',
    'complete',
    'Ready',
    'Known valid meal',
    42,
    64,
    18,
    586,
    'response-before-correction',
    '2026-07-19 18:00:00+00'
  ) returning id into rollback_meal_id;

  select public.prepare_entry_reanalysis(
    rollback_meal_id, owner_id, 'The correction worker should fail.'
  ) into transition;
  if transition <> 'queued' then
    raise exception 'rollback fixture was not queued: %', transition;
  end if;
  if not exists (
    select 1 from public.entries
    where id = rollback_meal_id
      and provider_response_id = 'response-before-correction'
      and processed_at = '2026-07-19 18:00:00+00'::timestamptz
  ) then
    raise exception 'correction queue discarded prior provider metadata';
  end if;

  update public.entries
  set status = 'failed',
      status_message = 'Worker failed',
      error_message = 'synthetic correction failure'
  where id = rollback_meal_id;
  if not exists (
    select 1 from public.entries
    where id = rollback_meal_id
      and status = 'complete'
      and status_message = 'Correction not applied — previous estimate kept'
      and title = 'Known valid meal'
      and protein_g = 42
      and carbs_g = 64
      and fat_g = 18
      and calories_kcal = 586
      and provider_response_id = 'response-before-correction'
      and error_message = 'synthetic correction failure'
  ) then
    raise exception 'failed correction hid or replaced the prior valid meal';
  end if;
  if not exists (
    select 1 from public.daily_totals
    where user_id = owner_id
      and local_day = '2026-07-19'
      and calories_kcal >= 586
  ) then
    raise exception 'failed correction removed the prior meal from daily totals';
  end if;

  select public.prepare_entry_reanalysis(
    rollback_meal_id, owner_id, 'Exercise exhausted retry recovery.'
  ) into transition;
  if transition <> 'queued' then
    raise exception 'rollback retry fixture was not queued: %', transition;
  end if;
  update public.entries
  set status = 'analyzing',
      processing_attempts = 3,
      lease_expires_at = now() - interval '1 second'
  where id = rollback_meal_id;
  if not public.fail_exhausted_entry_processing(
    rollback_meal_id, owner_id, 3::smallint
  ) then
    raise exception 'exhausted correction retry was not fenced';
  end if;
  if not exists (
    select 1 from public.entries
    where id = rollback_meal_id
      and status = 'complete'
      and status_message = 'Correction not applied — previous estimate kept'
      and calories_kcal = 586
      and provider_response_id = 'response-before-correction'
  ) then
    raise exception 'exhausted correction retry lost prior valid analysis';
  end if;

  select public.prepare_entry_reanalysis(
    meal_id,
    owner_id,
    'first-large-marker-' || repeat('a', 2480)
  ) into transition;
  if transition <> 'queued' then
    raise exception 'first large correction was not queued';
  end if;
  update public.entries set status = 'complete', status_message = 'Ready'
  where id = meal_id;
  select public.prepare_entry_reanalysis(
    meal_id,
    owner_id,
    'second-large-marker-' || repeat('b', 2480)
  ) into transition;
  if transition <> 'queued' then
    raise exception 'second large correction was not queued';
  end if;
  if not exists (
    select 1 from public.entries
    where id = meal_id
      and char_length(analysis_context) = 4000
      and analysis_context like 'second-large-marker-%'
      and strpos(analysis_context, 'first-large-marker-') > 0
  ) then
    raise exception 'bounded large correction history lost newest-first context';
  end if;
  update public.entries
  set status = 'complete', status_message = 'Ready', analysis_context = null
  where id = meal_id;
  delete from public.entry_corrections where entry_id = meal_id;

  update public.profiles
  set timezone = 'UTC',
      daily_macro_target = '{
        "calories_kcal": 2300,
        "protein_g": 170,
        "carbs_g": 260,
        "fat_g": 70
      }'::jsonb
  where user_id = owner_id;
  profile_target_day := (statement_timestamp() at time zone 'UTC')::date;
  if not exists (
    select 1 from public.daily_targets
    where user_id = owner_id
      and target_day = profile_target_day
      and calories_kcal = 2300
      and protein_g = 170
      and carbs_g = 260
      and fat_g = 70
      and source = 'manual'
  ) then
    raise exception 'profile target update did not create its effective-dated snapshot';
  end if;

  begin
    update public.profiles
    set daily_macro_target = '{"calories_kcal":2300,"protein_g":170}'::jsonb
    where user_id = owner_id;
  exception when check_violation then
    invalid_target_rejected := true;
  end;
  if not invalid_target_rejected then
    raise exception 'profile accepted a malformed daily macro target';
  end if;

  if position(
    'pg_advisory_xact_lock' in pg_catalog.pg_get_functiondef(
      'public.claim_weekly_summary(uuid, date)'::regprocedure
    )
  ) = 0 then
    raise exception 'weekly first-claim path is missing its advisory lock';
  end if;

  select count(*) into claim_count
  from public.claim_weekly_summary(owner_id, '2026-07-20');
  if claim_count <> 1 then
    raise exception 'first weekly claim returned % rows', claim_count;
  end if;
  select count(*) into claim_count
  from public.claim_weekly_summary(owner_id, '2026-07-20');
  if claim_count <> 0 then
    raise exception 'live weekly lease was claimed twice';
  end if;
  update public.weekly_summaries
  set status = 'complete', lease_expires_at = null
  where user_id = owner_id and week_start = '2026-07-20';
  select count(*) into claim_count
  from public.claim_weekly_summary(owner_id, '2026-07-20');
  if claim_count <> 0 then
    raise exception 'unchanged weekly summary regenerated';
  end if;
  update public.entries set title = 'Updated meal' where id = meal_id;
  select count(*) into claim_count
  from public.claim_weekly_summary(owner_id, '2026-07-20');
  if claim_count <> 1 then
    raise exception 'changed weekly input retained its fingerprint';
  end if;
  select generation_attempt into stored_attempt
  from public.weekly_summaries
  where user_id = owner_id and week_start = '2026-07-20';
  if stored_attempt <> 1 then
    raise exception 'new fingerprint retained attempt %', stored_attempt;
  end if;

  update public.weekly_summaries
  set status = 'complete', lease_expires_at = null
  where user_id = owner_id and week_start = '2026-07-20';
  update public.profiles set display_name = 'Unrelated edit'
  where user_id = owner_id;
  select count(*) into claim_count
  from public.claim_weekly_summary(owner_id, '2026-07-20');
  if claim_count <> 0 then
    raise exception 'unrelated profile edit spent another weekly generation';
  end if;

  insert into public.daily_targets (
    user_id, target_day, calories_kcal, protein_g, carbs_g, fat_g, source
  ) values (
    owner_id, '2026-07-22', 2500, 185, 290, 75, 'manual'
  )
  on conflict (user_id, target_day) do update
  set calories_kcal = excluded.calories_kcal,
      protein_g = excluded.protein_g,
      carbs_g = excluded.carbs_g,
      fat_g = excluded.fat_g,
      source = excluded.source;
  select count(*) into claim_count
  from public.claim_weekly_summary(owner_id, '2026-07-20');
  if claim_count <> 1 then
    raise exception 'effective target change did not replace the weekly fingerprint';
  end if;
  select generation_attempt into stored_attempt
  from public.weekly_summaries
  where user_id = owner_id and week_start = '2026-07-20';
  if stored_attempt <> 1 then
    raise exception 'target fingerprint change retained attempt %', stored_attempt;
  end if;

  update public.weekly_summaries
  set status = 'failed',
      generation_attempt = 3,
      lease_expires_at = null
  where user_id = owner_id and week_start = '2026-07-20';
  select count(*) into claim_count
  from public.claim_weekly_summary(owner_id, '2026-07-20');
  if claim_count <> 0 then
    raise exception 'weekly attempt limit ignored its cooldown';
  end if;

  execute 'alter table public.weekly_summaries disable trigger weekly_summaries_set_updated_at';
  update public.weekly_summaries
  set updated_at = now() - interval '25 hours'
  where user_id = owner_id and week_start = '2026-07-20';
  execute 'alter table public.weekly_summaries enable trigger weekly_summaries_set_updated_at';
  select count(*) into claim_count
  from public.claim_weekly_summary(owner_id, '2026-07-20');
  if claim_count <> 1 then
    raise exception 'weekly attempt limit never recovered after cooldown';
  end if;
  select generation_attempt into stored_attempt
  from public.weekly_summaries
  where user_id = owner_id and week_start = '2026-07-20';
  if stored_attempt <> 1 then
    raise exception 'weekly cooldown retained attempt %', stored_attempt;
  end if;

  if has_function_privilege(
    'authenticated',
    'public.prepare_entry_reanalysis(uuid, uuid, text)',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'public.apply_onboarding_profile(uuid, uuid, date, jsonb)',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'public.claim_weekly_summary(uuid, date)',
    'execute'
  ) then
    raise exception 'authenticated can bypass a model-backed Edge boundary';
  end if;
  if has_table_privilege('anon', 'public.weekly_summaries', 'select')
    or has_table_privilege('anon', 'public.entry_corrections', 'select') then
    raise exception 'anon can read analysis history';
  end if;
  if has_table_privilege('authenticated', 'public.daily_targets', 'insert')
    or has_table_privilege('authenticated', 'public.daily_targets', 'update')
    or has_table_privilege('authenticated', 'public.daily_targets', 'delete') then
    raise exception 'authenticated can rewrite effective-dated target history';
  end if;
  if not has_table_privilege('authenticated', 'public.daily_targets', 'select')
    or not has_table_privilege(
      'service_role',
      'public.daily_targets',
      'select,insert,update,delete'
    ) then
    raise exception 'target ledger least-privilege grants are incomplete';
  end if;

  delete from public.weekly_summaries
  where user_id = owner_id and week_start = '2026-07-20';
  delete from public.entries where id = rollback_meal_id;
end;
$$;

-- Current native builds PATCH profiles through the authenticated Data API.
-- The private validator/snapshot trigger must preserve that contract while
-- writing the ledger with elevated trigger privileges.
set role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-4000-8000-000000000001',
  false
);
update public.profiles
set timezone = 'UTC',
    daily_macro_target = '{
      "calories_kcal": 2400,
      "protein_g": 175,
      "carbs_g": 275,
      "fat_g": 72
    }'::jsonb
where user_id = '00000000-0000-4000-8000-000000000001';

do $$
declare
  direct_history_write_denied boolean := false;
  invalid_height_denied boolean := false;
  invalid_weight_denied boolean := false;
  invalid_target_weight_denied boolean := false;
begin
  begin
    update public.profiles set height_cm = 49
    where user_id = '00000000-0000-4000-8000-000000000001';
  exception when check_violation then
    invalid_height_denied := true;
  end;
  begin
    update public.profiles set weight_kg = 501
    where user_id = '00000000-0000-4000-8000-000000000001';
  exception when check_violation then
    invalid_weight_denied := true;
  end;
  begin
    update public.profiles set target_weight_kg = 19
    where user_id = '00000000-0000-4000-8000-000000000001';
  exception when check_violation then
    invalid_target_weight_denied := true;
  end;
  if not invalid_height_denied
    or not invalid_weight_denied
    or not invalid_target_weight_denied then
    raise exception 'authenticated profile PATCH bypassed body measurement bounds';
  end if;

  begin
    insert into public.daily_targets (
      user_id, target_day, calories_kcal, protein_g, carbs_g, fat_g, source
    ) values (
      '00000000-0000-4000-8000-000000000001',
      '2026-01-01',
      9999,
      999,
      999,
      999,
      'manual'
    );
  exception when insufficient_privilege then
    direct_history_write_denied := true;
  end;
  if not direct_history_write_denied then
    raise exception 'authenticated directly inserted target history';
  end if;
end;
$$;
reset role;

do $$
begin
  if not exists (
    select 1 from public.daily_targets
    where user_id = '00000000-0000-4000-8000-000000000001'
      and target_day = (statement_timestamp() at time zone 'UTC')::date
      and calories_kcal = 2400
      and protein_g = 175
      and carbs_g = 275
      and fat_g = 72
      and source = 'manual'
  ) then
    raise exception 'authenticated profile PATCH did not snapshot its target';
  end if;
end;
$$;

delete from auth.users
where id in (
  '00000000-0000-4000-8000-000000000003',
  '00000000-0000-4000-8000-000000000004'
);
