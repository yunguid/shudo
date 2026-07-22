-- Friends-beta signup and model-budget admission invariants.
begin;

do $$
begin
  if has_table_privilege(
    'anon', 'public.beta_signup_allowlist', 'select'
  ) or has_table_privilege(
    'authenticated', 'public.beta_signup_allowlist', 'select'
  ) or has_table_privilege(
    'service_role', 'public.beta_signup_allowlist', 'select'
  ) then
    raise exception 'beta email allowlist leaked a Data API grant';
  end if;
  if not has_column_privilege(
    'supabase_auth_admin', 'public.beta_signup_allowlist', 'email', 'select'
  ) or not has_column_privilege(
    'supabase_auth_admin', 'public.beta_signup_allowlist', 'enabled', 'select'
  ) then
    raise exception 'Supabase Auth cannot read the beta email allowlist';
  end if;
  if has_column_privilege(
    'supabase_auth_admin', 'public.beta_signup_allowlist', 'note', 'select'
  ) then
    raise exception 'Supabase Auth can read unnecessary allowlist metadata';
  end if;
  if has_function_privilege(
    'anon', 'public.hook_restrict_shudo_signup(jsonb)', 'execute'
  ) or has_function_privilege(
    'authenticated', 'public.hook_restrict_shudo_signup(jsonb)', 'execute'
  ) or has_function_privilege(
    'service_role', 'public.hook_restrict_shudo_signup(jsonb)', 'execute'
  ) then
    raise exception 'beta signup hook is executable by an app-facing role';
  end if;
  if not has_function_privilege(
    'supabase_auth_admin',
    'public.hook_restrict_shudo_signup(jsonb)',
    'execute'
  ) then
    raise exception 'Supabase Auth cannot execute the beta signup hook';
  end if;
  if not exists (
    select 1
    from pg_catalog.pg_class as relation
    join pg_catalog.pg_namespace as namespace
      on namespace.oid = relation.relnamespace
    where namespace.nspname = 'public'
      and relation.relname = 'beta_signup_allowlist'
      and relation.relrowsecurity
  ) then
    raise exception 'beta email allowlist is missing RLS defense in depth';
  end if;
  if not exists (
    select 1 from public.beta_signup_allowlist
    where email = 'luke@yng.sh' and enabled
  ) then
    raise exception 'audited primary beta owner is missing from the allowlist';
  end if;
end;
$$;

insert into public.beta_signup_allowlist (email)
values
  ('invited@example.test'),
  ('disabled@example.test')
on conflict (email) do update set enabled = true;

update public.beta_signup_allowlist
set enabled = false
where email = 'disabled@example.test';

set local role supabase_auth_admin;

do $$
declare
  allowed_result jsonb;
  rejected_result jsonb;
  disabled_result jsonb;
  missing_result jsonb;
begin
  select public.hook_restrict_shudo_signup(
    '{"user":{"email":"Invited@Example.Test"}}'::jsonb
  ) into allowed_result;
  select public.hook_restrict_shudo_signup(
    '{"user":{"email":"stranger@example.test"}}'::jsonb
  ) into rejected_result;
  select public.hook_restrict_shudo_signup(
    '{"user":{"email":"disabled@example.test"}}'::jsonb
  ) into disabled_result;
  select public.hook_restrict_shudo_signup(
    '{"user":{}}'::jsonb
  ) into missing_result;

  if allowed_result <> '{}'::jsonb then
    raise exception 'allowlisted signup was rejected: %', allowed_result;
  end if;
  if rejected_result #>> '{error,http_code}' <> '403'
    or rejected_result #>> '{error,message}' <> 'This beta is invite-only.' then
    raise exception 'non-allowlisted signup did not fail closed: %',
      rejected_result;
  end if;
  if missing_result #>> '{error,http_code}' <> '403' then
    raise exception 'email-less signup did not fail closed: %', missing_result;
  end if;
  if disabled_result #>> '{error,http_code}' <> '403' then
    raise exception 'disabled beta invite did not fail closed: %',
      disabled_result;
  end if;
end;
$$;

reset role;

do $$
declare
  invited_user constant uuid := '00000000-0000-4000-8000-000000000098';
  uninvited_user constant uuid := '00000000-0000-4000-8000-000000000099';
  rejected boolean := false;
begin
  insert into auth.users (id, email)
  values
    (invited_user, 'invited@example.test'),
    (uninvited_user, 'stranger@example.test');

  perform private.reserve_ai_job_usage(
    'meal_analysis', invited_user, 'invited-budget-check', 1::smallint
  );
  if not exists (
    select 1
    from private.ai_job_usage
    where user_id = invited_user
      and request_key = 'invited-budget-check'
  ) then
    raise exception 'allowlisted user could not reserve AI capacity';
  end if;

  begin
    perform private.reserve_ai_job_usage(
      'meal_analysis', uninvited_user, 'uninvited-budget-check', 1::smallint
    );
  exception when raise_exception then
    rejected := sqlerrm = 'beta_access_required';
  end;
  if not rejected then
    raise exception 'non-allowlisted account reserved shared AI capacity';
  end if;
  if exists (
    select 1
    from private.ai_job_usage
    where user_id = uninvited_user
      and request_key = 'uninvited-budget-check'
  ) then
    raise exception 'rejected beta reservation left a usage row behind';
  end if;
end;
$$;

-- Seed every durable model-work table while this account is admitted, revoke
-- it, then prove each insert/retry trigger rejects atomically. These statements
-- mirror the service-role writes made by the authenticated Edge Functions; the
-- user_id always belongs to a real auth.users row.
do $$
declare
  revoked_user constant uuid := '00000000-0000-4000-8000-000000000097';
  seed_entry constant uuid := '97000000-0000-4000-8000-000000000001';
  seed_entry_request constant uuid := '97100000-0000-4000-8000-000000000001';
  rejected_entry constant uuid := '97000000-0000-4000-8000-000000000011';
  rejected_entry_request constant uuid := '97100000-0000-4000-8000-000000000011';
  seed_onboarding constant uuid := '97000000-0000-4000-8000-000000000002';
  seed_onboarding_request constant uuid := '97200000-0000-4000-8000-000000000001';
  rejected_onboarding constant uuid := '97000000-0000-4000-8000-000000000012';
  rejected_onboarding_request constant uuid := '97200000-0000-4000-8000-000000000011';
  seed_correction_request constant uuid := '97000000-0000-4000-8000-000000000003';
  seed_correction_client_request constant uuid := '97300000-0000-4000-8000-000000000001';
  rejected_correction_request constant uuid := '97000000-0000-4000-8000-000000000013';
  rejected_correction_client_request constant uuid := '97300000-0000-4000-8000-000000000011';
  rejected_legacy_correction constant uuid := '97000000-0000-4000-8000-000000000014';
  seed_weekly_summary constant uuid := '97000000-0000-4000-8000-000000000004';
  rejected_weekly_summary constant uuid := '97000000-0000-4000-8000-000000000015';
  baseline_usage integer;
  final_usage integer;
  rejected boolean;
begin
  insert into auth.users (id, email)
  values (revoked_user, 'revoked-beta@example.test');
  insert into public.beta_signup_allowlist (email, note)
  values ('revoked-beta@example.test', 'Trigger rollback fixture');

  insert into public.entries (
    id, user_id, client_request_id, local_day, status, title
  ) values (
    seed_entry, revoked_user, seed_entry_request, '2026-07-20',
    'complete', 'Seed meal'
  );
  insert into public.onboarding_analyses (
    id, user_id, client_request_id, timezone_snapshot, status,
    analysis_model, lease_expires_at
  ) values (
    seed_onboarding, revoked_user, seed_onboarding_request, 'UTC', 'failed',
    'gpt-5.6-sol', null
  );
  insert into public.entry_correction_requests (
    id, user_id, entry_id, client_request_id, status, correction_text,
    lease_expires_at
  ) values (
    seed_correction_request, revoked_user, seed_entry,
    seed_correction_client_request, 'failed', 'Seed correction', null
  );
  insert into public.weekly_summaries (
    id, user_id, week_start, status, input_fingerprint
  ) values (
    seed_weekly_summary, revoked_user, '2026-07-13', 'complete',
    'seed-fingerprint'
  );

  select pg_catalog.count(*) into baseline_usage
  from private.ai_job_usage
  where user_id = revoked_user;
  if baseline_usage <> 4 then
    raise exception 'model-work seed rows did not exercise all four reservation tables';
  end if;

  delete from public.beta_signup_allowlist
  where email = 'revoked-beta@example.test';

  rejected := false;
  begin
    insert into public.entries (
      id, user_id, client_request_id, local_day, status
    ) values (
      rejected_entry, revoked_user, rejected_entry_request,
      '2026-07-21', 'queued'
    );
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'beta_access_required' then
      raise;
    end if;
    rejected := true;
  end;
  if not rejected then
    raise exception 'unallowlisted meal insert bypassed beta admission';
  end if;

  rejected := false;
  begin
    insert into public.onboarding_analyses (
      id, user_id, client_request_id, timezone_snapshot, status,
      analysis_model
    ) values (
      rejected_onboarding, revoked_user, rejected_onboarding_request,
      'UTC', 'analyzing', 'gpt-5.6-sol'
    );
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'beta_access_required' then
      raise;
    end if;
    rejected := true;
  end;
  if not rejected then
    raise exception 'unallowlisted onboarding insert bypassed beta admission';
  end if;

  rejected := false;
  begin
    insert into public.entry_correction_requests (
      id, user_id, entry_id, client_request_id
    ) values (
      rejected_correction_request, revoked_user, seed_entry,
      rejected_correction_client_request
    );
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'beta_access_required' then
      raise;
    end if;
    rejected := true;
  end;
  if not rejected then
    raise exception 'unallowlisted correction request bypassed beta admission';
  end if;

  rejected := false;
  begin
    insert into public.entry_corrections (
      id, user_id, entry_id, context
    ) values (
      rejected_legacy_correction, revoked_user, seed_entry,
      'Legacy correction should be rejected'
    );
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'beta_access_required' then
      raise;
    end if;
    rejected := true;
  end;
  if not rejected then
    raise exception 'unallowlisted legacy correction bypassed beta admission';
  end if;

  rejected := false;
  begin
    insert into public.weekly_summaries (
      id, user_id, week_start, status, input_fingerprint
    ) values (
      rejected_weekly_summary, revoked_user, '2026-07-20', 'generating',
      'rejected-fingerprint'
    );
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'beta_access_required' then
      raise;
    end if;
    rejected := true;
  end;
  if not rejected then
    raise exception 'unallowlisted weekly summary insert bypassed beta admission';
  end if;

  rejected := false;
  begin
    update public.entries
    set status = 'transcribing', processing_attempts = 2
    where id = seed_entry;
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'beta_access_required' then
      raise;
    end if;
    rejected := true;
  end;
  if not rejected then
    raise exception 'unallowlisted meal retry bypassed beta admission';
  end if;

  rejected := false;
  begin
    update public.onboarding_analyses
    set status = 'analyzing', generation_attempt = 2,
        lease_expires_at = pg_catalog.now() + interval '135 seconds'
    where id = seed_onboarding;
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'beta_access_required' then
      raise;
    end if;
    rejected := true;
  end;
  if not rejected then
    raise exception 'unallowlisted onboarding retry bypassed beta admission';
  end if;

  rejected := false;
  begin
    update public.entry_correction_requests
    set status = 'processing', generation_attempt = 2,
        lease_expires_at = pg_catalog.now() + interval '135 seconds',
        error_message = null
    where id = seed_correction_request;
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'beta_access_required' then
      raise;
    end if;
    rejected := true;
  end;
  if not rejected then
    raise exception 'unallowlisted correction retry bypassed beta admission';
  end if;

  rejected := false;
  begin
    update public.weekly_summaries
    set status = 'generating', generation_attempt = 2,
        input_fingerprint = 'retry-fingerprint'
    where id = seed_weekly_summary;
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'beta_access_required' then
      raise;
    end if;
    rejected := true;
  end;
  if not rejected then
    raise exception 'unallowlisted weekly retry bypassed beta admission';
  end if;

  select pg_catalog.count(*) into final_usage
  from private.ai_job_usage
  where user_id = revoked_user;
  if final_usage <> baseline_usage then
    raise exception 'rejected model work retained an AI reservation';
  end if;
  if exists (
    select 1 from private.entry_capture_usage
    where user_id = revoked_user
      and client_request_id = rejected_entry_request
  ) then
    raise exception 'rejected meal retained a capture reservation';
  end if;
  if exists (select 1 from public.entries where id = rejected_entry)
    or exists (
      select 1 from public.onboarding_analyses
      where id = rejected_onboarding
    )
    or exists (
      select 1 from public.entry_correction_requests
      where id = rejected_correction_request
    )
    or exists (
      select 1 from public.entry_corrections
      where id = rejected_legacy_correction
    )
    or exists (
      select 1 from public.weekly_summaries
      where id = rejected_weekly_summary
    ) then
    raise exception 'rejected model work retained a business row';
  end if;
  if not exists (
    select 1 from public.entries
    where id = seed_entry and status = 'complete' and processing_attempts = 0
  ) or not exists (
    select 1 from public.onboarding_analyses
    where id = seed_onboarding and status = 'failed' and generation_attempt = 1
  ) or not exists (
    select 1 from public.entry_correction_requests
    where id = seed_correction_request
      and status = 'failed' and generation_attempt = 1
  ) or not exists (
    select 1 from public.weekly_summaries
    where id = seed_weekly_summary and status = 'complete'
      and generation_attempt = 1 and input_fingerprint = 'seed-fingerprint'
  ) then
    raise exception 'rejected model retry mutated its existing business row';
  end if;
end;
$$;

rollback;
