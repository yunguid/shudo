-- Shudo 2.0 coach schema invariants: exposure, fenced runs, pooled budgets,
-- the coach thread, activities, body check-ins, memory, digests, training
-- plans, device context, Storage, housekeeping, and account cascade. Every
-- fixture lives inside one transaction (so now() is fixed) and is rolled back,
-- which lets this suite run unchanged in the fresh and legacy harnesses.
begin;

insert into auth.users (id, email)
values
  ('00000000-0000-4000-8000-0000000000c1', 'coach-one@example.test'),
  ('00000000-0000-4000-8000-0000000000c2', 'coach-two@example.test');

insert into public.beta_signup_allowlist (email, note)
values
  ('coach-one@example.test', 'Shudo 2.0 fixture'),
  ('coach-two@example.test', 'Shudo 2.0 fixture')
on conflict (email) do update set enabled = true;

-- Start every budget assertion from an empty rolling window.
update private.ai_job_usage
set reserved_at = pg_catalog.now() - interval '25 hours';

-- 1. Profile defaults are conservative: coach off, every opt-in off.
do $$
declare
  profile_row public.profiles%rowtype;
begin
  select * into profile_row
  from public.profiles
  where user_id = '00000000-0000-4000-8000-0000000000c1';
  if profile_row.coach_enabled
    or profile_row.coach_intensity <> 'locked_in'
    or profile_row.coach_profanity <> 'mild'
    or profile_row.quiet_hours_start <> '23:00'::time
    or profile_row.quiet_hours_end <> '07:00'::time
    or profile_row.location_recs_enabled
    or profile_row.physique_ai_review_enabled
    or profile_row.goal_date is not null
    or profile_row.goal_start_weight_kg is not null then
    raise exception 'new profile coach defaults are not conservative';
  end if;

  begin
    update public.profiles set coach_profanity = 'filthy'
    where user_id = '00000000-0000-4000-8000-0000000000c1';
    raise exception 'profanity check accepted an unknown level';
  exception when check_violation then
    null;
  end;
  begin
    update public.profiles
    set quiet_hours_start = '22:00', quiet_hours_end = '22:00'
    where user_id = '00000000-0000-4000-8000-0000000000c1';
    raise exception 'quiet hours accepted an empty window';
  exception when check_violation then
    null;
  end;
end;
$$;

-- 2. Exposure: tables, columns, functions, bucket, publication.
do $$
declare
  new_tables constant text[] := array[
    'public.activities', 'public.coach_messages', 'public.coach_memory',
    'public.coach_memory_revisions', 'public.day_digests',
    'public.training_plans', 'public.device_snapshots'
  ];
  server_written_tables constant text[] := array[
    'public.activities', 'public.coach_messages', 'public.coach_memory',
    'public.coach_memory_revisions', 'public.day_digests',
    'public.training_plans'
  ];
  rpc_signatures constant text[] := array[
    'public.claim_coach_run(uuid, text, date, text, text, timestamptz, text, integer)',
    'public.get_coach_runs(uuid, uuid, date, text, integer)',
    'public.complete_coach_run(uuid, uuid, text, jsonb, jsonb, text[], text, text)',
    'public.fail_coach_run(uuid, uuid, text, boolean)',
    'public.post_user_coach_message(uuid, uuid, date, text, text, jsonb, text)',
    'public.upsert_streaming_coach_message(uuid, uuid, uuid, text, jsonb, boolean, text, text)',
    'public.post_coach_message(uuid, text, text, jsonb, date, text, boolean, timestamptz, text, uuid, uuid, uuid, text)',
    'public.save_day_digest(uuid, uuid, jsonb)',
    'public.save_activity_analysis(uuid, uuid, uuid, jsonb)',
    'public.save_body_review(uuid, uuid, uuid, jsonb, text)',
    'public.save_coach_memory(uuid, integer, text, jsonb, text, text, uuid, uuid, uuid)',
    'public.save_training_plan_draft(uuid, jsonb, text, text, text, text, uuid, uuid)',
    'public.activate_training_plan(uuid, uuid)',
    'public.discard_training_plan_draft(uuid, uuid)',
    'public.record_ai_provider_call(uuid, text, text, text, integer, integer, integer, integer, integer, bigint, text, uuid, text, smallint, text, integer)',
    'public.run_coach_housekeeping()'
  ];
  private_signatures constant text[] := array[
    'private.coach_housekeeping()',
    'private.coach_run_matches(uuid, uuid, uuid, text)',
    'private.reserve_coach_run_ai_job()',
    'private.enforce_coach_message_links()',
    'private.guard_coach_message_read()',
    'private.enforce_activity_capture()',
    'private.enqueue_activity_media_cleanup()',
    'private.reserve_ai_job_usage(text, uuid, text, smallint)',
    'private.enqueue_storage_cleanup_job(text, text, text, timestamptz)'
  ];
  table_name text;
  signature text;
  api_role text;
begin
  foreach table_name in array new_tables loop
    if has_table_privilege('anon', table_name, 'select')
      or has_table_privilege('anon', table_name, 'insert')
      or has_table_privilege('anon', table_name, 'update')
      or has_table_privilege('anon', table_name, 'delete') then
      raise exception 'anon has a privilege on %', table_name;
    end if;
    if not has_table_privilege('authenticated', table_name, 'select') then
      raise exception 'authenticated cannot read its own %', table_name;
    end if;
    if not has_table_privilege(
      'service_role', table_name, 'select,insert,update,delete'
    ) then
      raise exception 'service_role is missing privileges on %', table_name;
    end if;
  end loop;

  foreach table_name in array server_written_tables loop
    if has_table_privilege('authenticated', table_name, 'insert')
      or has_table_privilege('authenticated', table_name, 'update') then
      raise exception 'authenticated can write server-owned %', table_name;
    end if;
  end loop;
  if has_table_privilege('authenticated', 'public.coach_messages', 'delete')
    or has_table_privilege('authenticated', 'public.training_plans', 'delete')
    or has_table_privilege('authenticated', 'public.coach_memory', 'delete') then
    raise exception 'authenticated can delete server-owned coach rows';
  end if;
  if not has_table_privilege('authenticated', 'public.activities', 'delete') then
    raise exception 'owners cannot delete their own activities';
  end if;

  if not has_column_privilege('authenticated', 'public.coach_messages', 'read_at', 'update')
    or has_column_privilege('authenticated', 'public.coach_messages', 'body', 'update')
    or has_column_privilege('authenticated', 'public.coach_messages', 'status', 'update')
    or has_column_privilege('authenticated', 'public.coach_messages', 'payload', 'update')
    or has_column_privilege('authenticated', 'public.coach_messages', 'deliver_at', 'update') then
    raise exception 'coach_messages client columns are not exactly read_at';
  end if;

  if has_table_privilege('authenticated', 'public.weight_checkins', 'insert')
    or has_table_privilege('authenticated', 'public.weight_checkins', 'update')
    or has_column_privilege('authenticated', 'public.weight_checkins', 'coach_review', 'update')
    or has_column_privilege('authenticated', 'public.weight_checkins', 'coach_review', 'insert')
    or has_column_privilege('authenticated', 'public.weight_checkins', 'coach_reviewed_at', 'update')
    or has_column_privilege('authenticated', 'public.weight_checkins', 'coach_reviewed_photo_path', 'update')
    or not has_column_privilege('authenticated', 'public.weight_checkins', 'progress_photo_path', 'update')
    or not has_column_privilege('authenticated', 'public.weight_checkins', 'weight_kg', 'insert')
    or not has_column_privilege('authenticated', 'public.weight_checkins', 'note', 'insert')
    or not has_column_privilege('authenticated', 'public.weight_checkins', 'photo_pose', 'update') then
    raise exception 'weight_checkins column grants are wrong';
  end if;

  if has_column_privilege('authenticated', 'public.activities', 'status', 'insert')
    or has_column_privilege('authenticated', 'public.activities', 'title', 'update') then
    raise exception 'clients can write activities directly';
  end if;

  if not has_column_privilege('authenticated', 'public.device_snapshots', 'nearby', 'update')
    or not has_column_privilege('authenticated', 'public.device_snapshots', 'timezone', 'insert')
    or has_column_privilege('authenticated', 'public.device_snapshots', 'created_at', 'update')
    or has_column_privilege('authenticated', 'public.device_snapshots', 'updated_at', 'insert') then
    raise exception 'device_snapshots column grants are wrong';
  end if;

  if not has_column_privilege('authenticated', 'public.profiles', 'coach_enabled', 'update')
    or not has_column_privilege('authenticated', 'public.profiles', 'coach_intensity', 'update')
    or not has_column_privilege('authenticated', 'public.profiles', 'coach_profanity', 'update')
    or not has_column_privilege('authenticated', 'public.profiles', 'quiet_hours_start', 'update')
    or not has_column_privilege('authenticated', 'public.profiles', 'physique_ai_review_enabled', 'update')
    or not has_column_privilege('authenticated', 'public.profiles', 'goal_start_weight_kg', 'update') then
    raise exception 'profile coach settings are not client-updatable';
  end if;

  if has_schema_privilege('service_role', 'private', 'usage') then
    raise exception 'service role unexpectedly has private schema USAGE';
  end if;
  foreach table_name in array array['private.coach_runs', 'private.ai_provider_calls'] loop
    foreach api_role in array array['anon', 'authenticated', 'service_role'] loop
      if has_table_privilege(api_role, table_name, 'select')
        or has_table_privilege(api_role, table_name, 'insert')
        or has_table_privilege(api_role, table_name, 'update')
        or has_table_privilege(api_role, table_name, 'delete') then
        raise exception '% leaked a % grant', table_name, api_role;
      end if;
    end loop;
    if not exists (
      select 1
      from pg_catalog.pg_class as relation
      where relation.oid = table_name::regclass and relation.relrowsecurity
    ) then
      raise exception '% is missing RLS defense in depth', table_name;
    end if;
  end loop;

  foreach signature in array rpc_signatures loop
    if has_function_privilege('anon', signature, 'execute')
      or has_function_privilege('authenticated', signature, 'execute') then
      raise exception 'coach RPC leaked EXECUTE: %', signature;
    end if;
    if not has_function_privilege('service_role', signature, 'execute') then
      raise exception 'service role cannot execute %', signature;
    end if;
  end loop;
  foreach signature in array private_signatures loop
    foreach api_role in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(api_role, signature, 'execute') then
        raise exception '% can execute private helper %', api_role, signature;
      end if;
    end loop;
  end loop;

  if not exists (
    select 1 from storage.buckets
    where id = 'coach-media'
      and public = false
      and file_size_limit = 6291456
      and allowed_mime_types = array['image/jpeg']
  ) then
    raise exception 'private coach-media bucket is missing or unsafe';
  end if;
  if exists (
    select 1 from pg_catalog.pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname like 'coach_media_%'
      and cmd in ('UPDATE', 'DELETE')
  ) then
    raise exception 'clients can modify or delete coach-media objects';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'coach_messages'
  ) then
    raise exception 'coach_messages is missing from the Realtime publication';
  end if;
end;
$$;

-- 3. Platform-wide sweeps: every public table has RLS, no public table is
--    reachable by anon, and no SECURITY DEFINER function is callable by anon.
do $$
declare
  offender text;
begin
  select pg_catalog.string_agg(relation.relname, ', ')
  into offender
  from pg_catalog.pg_class as relation
  join pg_catalog.pg_namespace as namespace
    on namespace.oid = relation.relnamespace
  where namespace.nspname = 'public'
    and relation.relkind in ('r', 'p')
    and not relation.relrowsecurity;
  if offender is not null then
    raise exception 'public tables without RLS: %', offender;
  end if;

  select pg_catalog.string_agg(relation.relname, ', ')
  into offender
  from pg_catalog.pg_class as relation
  join pg_catalog.pg_namespace as namespace
    on namespace.oid = relation.relnamespace
  where namespace.nspname in ('public', 'private')
    and relation.relkind in ('r', 'p', 'v', 'm')
    and (
      has_table_privilege('anon', relation.oid, 'select')
      or has_table_privilege('anon', relation.oid, 'insert')
      or has_table_privilege('anon', relation.oid, 'update')
      or has_table_privilege('anon', relation.oid, 'delete')
    );
  if offender is not null then
    raise exception 'tables reachable by anon: %', offender;
  end if;

  select pg_catalog.string_agg(procedure.oid::regprocedure::text, ', ')
  into offender
  from pg_catalog.pg_proc as procedure
  join pg_catalog.pg_namespace as namespace
    on namespace.oid = procedure.pronamespace
  where namespace.nspname in ('public', 'private')
    and procedure.prosecdef
    and has_function_privilege('anon', procedure.oid, 'execute');
  if offender is not null then
    raise exception 'SECURITY DEFINER functions executable by anon: %', offender;
  end if;

  select pg_catalog.string_agg(procedure.oid::regprocedure::text, ', ')
  into offender
  from pg_catalog.pg_proc as procedure
  join pg_catalog.pg_namespace as namespace
    on namespace.oid = procedure.pronamespace
  where namespace.nspname in ('public', 'private')
    and procedure.prosecdef
    and not exists (
      select 1
      from pg_catalog.unnest(coalesce(procedure.proconfig, array[]::text[]))
        as setting(value)
      where setting.value like 'search_path=%'
    );
  if offender is not null then
    raise exception 'SECURITY DEFINER functions without a pinned search_path: %', offender;
  end if;
end;
$$;

-- 4. Fenced run ledger: gates, claims, leases, retries, stale writers.
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-8000-0000000000c1';
  claim jsonb;
  first_token uuid;
  second_token uuid;
  checkpoint_run_id uuid;
  completion jsonb;
  stored_count integer;
  scheduled_count integer;
  superseded_count integer;
  raised boolean;
  attempt_no integer;
begin
  claim := public.claim_coach_run(
    owner_id, 'coach_checkpoint', '2026-10-06', 'morning', 'schedule'
  );
  if claim->>'status' <> 'disabled' then
    raise exception 'checkpoint claim ignored the coach switch: %', claim;
  end if;
  if exists (select 1 from private.coach_runs where user_id = owner_id) then
    raise exception 'a disabled claim created a run';
  end if;

  update public.profiles set coach_enabled = true where user_id = owner_id;

  claim := public.claim_coach_run(
    owner_id, 'coach_checkpoint', '2026-10-06', 'morning', 'schedule',
    null, 'fingerprint-a'
  );
  if claim->>'status' <> 'claimed' or (claim->>'generation_attempt')::integer <> 1 then
    raise exception 'first checkpoint claim failed: %', claim;
  end if;
  checkpoint_run_id := (claim->>'run_id')::uuid;
  first_token := (claim->>'claim_token')::uuid;
  if not exists (
    select 1 from private.ai_job_usage
    where operation = 'coach_checkpoint'
      and user_id = owner_id
      and request_key = '2026-10-06:morning'
      and attempt = 1
  ) then
    raise exception 'checkpoint claim did not reserve AI capacity';
  end if;

  claim := public.claim_coach_run(owner_id, 'coach_checkpoint', '2026-10-06', 'morning');
  if claim->>'status' <> 'running' or (claim->>'run_id')::uuid <> checkpoint_run_id
    or claim ? 'claim_token' then
    raise exception 'live lease was not reported as running: %', claim;
  end if;
  select count(*) into stored_count from private.ai_job_usage
  where operation = 'coach_checkpoint' and user_id = owner_id;
  if stored_count <> 1 then
    raise exception 'a live lease consumed another reservation';
  end if;

  update private.coach_runs
  set lease_expires_at = pg_catalog.now() - interval '1 second'
  where id = checkpoint_run_id;
  claim := public.claim_coach_run(owner_id, 'coach_checkpoint', '2026-10-06', 'morning');
  second_token := (claim->>'claim_token')::uuid;
  if claim->>'status' <> 'reclaimed'
    or (claim->>'generation_attempt')::integer <> 2
    or second_token = first_token then
    raise exception 'expired lease was not reclaimed with a new token: %', claim;
  end if;
  if not exists (
    select 1 from private.ai_job_usage
    where operation = 'coach_checkpoint'
      and user_id = owner_id
      and request_key = '2026-10-06:morning'
      and attempt = 2
  ) then
    raise exception 'reclaimed attempt did not reserve AI capacity';
  end if;

  completion := public.complete_coach_run(
    checkpoint_run_id, first_token, 'complete', '{}'::jsonb,
    '[{"kind":"checkpoint","body":"Stale worker text."}]'::jsonb
  );
  if completion->>'status' <> 'stale' then
    raise exception 'a stale token completed the run: %', completion;
  end if;
  if exists (select 1 from public.coach_messages where run_id = checkpoint_run_id) then
    raise exception 'a stale completion posted a message';
  end if;

  completion := public.complete_coach_run(
    checkpoint_run_id, second_token, 'complete', '{"slots":2}'::jsonb,
    pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'kind', 'plan',
        'body', 'Morning. Protein first today.',
        'payload', pg_catalog.jsonb_build_object('theme', 'protein')
      ),
      pg_catalog.jsonb_build_object(
        'kind', 'checkpoint',
        'body', 'Lunch: chicken and rice. Hit 50g.',
        'slot_key', 'lunch',
        'deliver_at', pg_catalog.now() + interval '2 hours',
        'payload', pg_catalog.jsonb_build_object('push_body', 'Lunch: hit 50g protein.')
      )
    ),
    null, 'claude-sonnet-5-5', 'msg_fixture'
  );
  if completion->>'status' <> 'complete'
    or pg_catalog.jsonb_array_length(completion->'message_ids') <> 2 then
    raise exception 'fenced completion failed: %', completion;
  end if;
  if not exists (
    select 1 from public.coach_messages
    where run_id = checkpoint_run_id and kind = 'plan' and status = 'delivered'
      and not notify and deliver_at = pg_catalog.now()
  ) or not exists (
    select 1 from public.coach_messages
    where run_id = checkpoint_run_id and slot_key = 'lunch' and status = 'scheduled'
      and notify and payload->>'push_body' = 'Lunch: hit 50g protein.'
  ) then
    raise exception 'completion did not split delivered and scheduled messages';
  end if;

  claim := public.claim_coach_run(owner_id, 'coach_checkpoint', '2026-10-06', 'morning');
  if claim->>'status' <> 'complete' then
    raise exception 'completed run was claimable again: %', claim;
  end if;
  completion := public.complete_coach_run(
    checkpoint_run_id, second_token, 'complete', '{}'::jsonb, '[]'::jsonb
  );
  if completion->>'status' <> 'stale' then
    raise exception 'a completed run accepted a second completion';
  end if;

  -- A newer plan replaces the still-future slot instead of stacking.
  claim := public.claim_coach_run(
    owner_id, 'coach_checkpoint', '2026-10-06', 'plan:fingerprint-b'
  );
  completion := public.complete_coach_run(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'complete', '{}'::jsonb,
    pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'kind', 'checkpoint',
        'body', 'Lunch moved: get 45g in by 1.',
        'slot_key', 'lunch',
        'deliver_at', pg_catalog.now() + interval '3 hours'
      ),
      pg_catalog.jsonb_build_object(
        'kind', 'plan',
        'body', 'Tomorrow: lift day.',
        'slot_key', 'wake',
        'local_day', '2026-10-07',
        'deliver_at', pg_catalog.now() + interval '20 hours'
      )
    )
  );
  select
    count(*) filter (where status = 'scheduled'),
    count(*) filter (where status = 'superseded')
  into scheduled_count, superseded_count
  from public.coach_messages
  where user_id = owner_id and slot_key = 'lunch';
  if completion->>'superseded' <> '1' or scheduled_count <> 1 or superseded_count <> 1 then
    raise exception 'slot supersede left % scheduled / % superseded (%)',
      scheduled_count, superseded_count, completion;
  end if;
  if not exists (
    select 1 from public.coach_messages
    where user_id = owner_id and slot_key = 'lunch' and status = 'superseded'
      and superseded_at is not null and body = 'Lunch: chicken and rice. Hit 50g.'
  ) then
    raise exception 'the older slot message was not the one superseded';
  end if;

  -- Explicit supersede: bare slots mean the run's day; dated refs are exact.
  claim := public.claim_coach_run(owner_id, 'coach_checkpoint', '2026-10-06', 'evening');
  completion := public.complete_coach_run(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'skipped', '{}'::jsonb,
    '[]'::jsonb, array['lunch', '2026-10-07:wake']
  );
  if completion->>'status' <> 'skipped' or completion->>'superseded' <> '2' then
    raise exception 'explicit supersede failed: %', completion;
  end if;
  if exists (
    select 1 from public.coach_messages
    where user_id = owner_id and status = 'scheduled'
  ) then
    raise exception 'explicitly superseded slots are still scheduled';
  end if;

  -- Guardrails on the batch itself.
  claim := public.claim_coach_run(owner_id, 'coach_checkpoint', '2026-10-06', 'afternoon');
  raised := false;
  begin
    perform public.complete_coach_run(
      (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'complete', '{}'::jsonb,
      pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'kind', 'checkpoint', 'body', 'Too far out.',
        'deliver_at', pg_catalog.now() + interval '37 hours'
      ))
    );
  exception when invalid_parameter_value then
    raised := true;
  end;
  if not raised then
    raise exception 'a message 37 hours ahead was accepted';
  end if;
  raised := false;
  begin
    perform public.complete_coach_run(
      (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'complete', '{}'::jsonb,
      pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'kind', 'checkpoint', 'body', 'Too long a push.',
        'payload', pg_catalog.jsonb_build_object('push_body', pg_catalog.repeat('x', 151))
      ))
    );
  exception when check_violation then
    raised := true;
  end;
  if not raised then
    raise exception 'a 151-character push body was accepted';
  end if;
  raised := false;
  begin
    perform public.complete_coach_run(
      (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'complete', '{}'::jsonb,
      '[{"kind":"photo","body":"Coach cannot send user kinds."}]'::jsonb
    );
  exception when check_violation then
    raised := true;
  end;
  if not raised then
    raise exception 'a coach message accepted a user-only kind';
  end if;

  -- Key validation and normalization.
  raised := false;
  begin
    perform public.claim_coach_run(owner_id, 'coach_reply', '2026-10-06', 'reply:not-a-uuid');
  exception when invalid_parameter_value then
    raised := true;
  end;
  if not raised then
    raise exception 'a malformed reply key was accepted';
  end if;
  raised := false;
  begin
    perform public.claim_coach_run(owner_id, 'day_digest', '2026-10-05', 'nightly');
  exception when invalid_parameter_value then
    raised := true;
  end;
  if not raised then
    raise exception 'a digest run accepted a key other than digest';
  end if;
  claim := public.claim_coach_run(
    owner_id, 'coach_reply', '2026-10-06',
    'reply:ABCDEF01-2345-4678-89AB-CDEF01234567'
  );
  if claim->>'checkpoint_key' <> 'reply:abcdef01-2345-4678-89ab-cdef01234567' then
    raise exception 'uppercase UUID keys were not normalized: %', claim;
  end if;
  claim := public.claim_coach_run(
    owner_id, 'coach_reply', '2026-10-06',
    'reply:abcdef01-2345-4678-89ab-cdef01234567'
  );
  if claim->>'status' <> 'running' then
    raise exception 'a lowercase replay did not find the normalized run: %', claim;
  end if;

  -- One key never changes operation.
  claim := public.claim_coach_run(owner_id, 'nearby_research', '2026-10-06', 'evening');
  if claim->>'status' <> 'conflict' then
    raise exception 'a key was reused across operations: %', claim;
  end if;

  -- Retry budget: three attempts, then exhausted; non-retryable stops at once.
  claim := public.claim_coach_run(owner_id, 'nearby_research', '2026-10-06', 'nearby:retry');
  for attempt_no in 1..3 loop
    if (claim->>'generation_attempt')::integer <> attempt_no then
      raise exception 'retry attempt % was numbered %', attempt_no, claim;
    end if;
    if public.fail_coach_run(
      (claim->>'run_id')::uuid, gen_random_uuid(), 'wrong token'
    ) then
      raise exception 'fail_coach_run accepted a wrong token';
    end if;
    if not public.fail_coach_run(
      (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'provider timeout'
    ) then
      raise exception 'fail_coach_run rejected the live token';
    end if;
    claim := public.claim_coach_run(owner_id, 'nearby_research', '2026-10-06', 'nearby:retry');
  end loop;
  if claim->>'status' <> 'exhausted' then
    raise exception 'a fourth attempt was allowed: %', claim;
  end if;

  claim := public.claim_coach_run(owner_id, 'training_plan', '2026-10-06', 'plan_build');
  perform public.fail_coach_run(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'refused', false
  );
  claim := public.claim_coach_run(owner_id, 'training_plan', '2026-10-06', 'plan_build');
  if claim->>'status' <> 'exhausted' then
    raise exception 'a non-retryable failure was reclaimed: %', claim;
  end if;

  -- Physique photos reach a model only after the explicit opt-in.
  claim := public.claim_coach_run(owner_id, 'body_review', '2026-10-06', 'body_review:weekly');
  if claim->>'status' <> 'disabled' then
    raise exception 'body review ignored the physique opt-in: %', claim;
  end if;

  -- At most four live runs per user.
  update private.coach_runs
  set status = 'complete', lease_expires_at = null, completed_at = pg_catalog.now()
  where user_id = owner_id and status = 'running';
  for attempt_no in 1..4 loop
    claim := public.claim_coach_run(
      owner_id, 'coach_checkpoint', '2026-10-06', 'capacity_' || attempt_no::text
    );
    if claim->>'status' <> 'claimed' then
      raise exception 'capacity fixture % was not claimed: %', attempt_no, claim;
    end if;
  end loop;
  claim := public.claim_coach_run(owner_id, 'coach_checkpoint', '2026-10-06', 'capacity_5');
  if claim->>'status' <> 'capacity' then
    raise exception 'a fifth live run was admitted: %', claim;
  end if;
  update private.coach_runs
  set status = 'complete', lease_expires_at = null, completed_at = pg_catalog.now()
  where user_id = owner_id and status = 'running';

  if pg_catalog.jsonb_array_length(public.get_coach_runs(
    owner_id, null, '2026-10-06', 'coach_checkpoint', 100
  )) < 8 or public.get_coach_runs(owner_id, checkpoint_run_id)->0->>'status' <> 'complete'
    or public.get_coach_runs(owner_id, checkpoint_run_id)->0 ? 'claim_token'
    or public.get_coach_runs(
      '00000000-0000-4000-8000-0000000000c2', checkpoint_run_id
    ) <> '[]'::jsonb then
    raise exception 'get_coach_runs did not return owner-scoped runs without tokens';
  end if;
end;
$$;

-- 5. User messages, streaming replies, interruption, and reclaim cleanup.
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-8000-0000000000c1';
  request_id constant uuid := 'c1000000-0000-4000-8000-000000000001';
  second_request_id constant uuid := 'c1000000-0000-4000-8000-000000000002';
  streamed_id constant uuid := 'c1500000-0000-4000-8000-000000000001';
  interrupted_id constant uuid := 'c1500000-0000-4000-8000-000000000002';
  result jsonb;
  user_message_id uuid;
  claim jsonb;
  message_row public.coach_messages%rowtype;
begin
  result := public.post_user_coach_message(
    owner_id, request_id, '2026-10-06', 'text', '  Had three eggs and toast  '
  );
  if result->>'status' <> 'created' or result->'message'->>'body' <> 'Had three eggs and toast'
    or result->'message'->>'role' <> 'user' or result->'message'->>'read_at' is null then
    raise exception 'user message was not created as a read user row: %', result;
  end if;
  user_message_id := (result->>'message_id')::uuid;
  result := public.post_user_coach_message(
    owner_id, request_id, '2026-10-06', 'text', 'Had three eggs and toast'
  );
  if result->>'status' <> 'existing' or (result->>'message_id')::uuid <> user_message_id then
    raise exception 'a replayed user message was not idempotent: %', result;
  end if;
  result := public.post_user_coach_message(
    owner_id, request_id, '2026-10-06', 'text', 'Different text'
  );
  if result->>'status' <> 'conflict' then
    raise exception 'a reused request id with new text was accepted: %', result;
  end if;
  result := public.post_user_coach_message(
    owner_id, 'c1000000-0000-4000-8000-000000000003', '2026-10-06', 'text', 'Gym pic',
    '{}'::jsonb,
    '00000000-0000-4000-8000-0000000000c1/2026-10-06/chat-11111111-2222-4333-8444-555555555555.jpg'
  );
  if result->'message'->>'kind' <> 'photo' then
    raise exception 'a message with a photo was not stored as a photo: %', result;
  end if;
  begin
    perform public.post_user_coach_message(
      owner_id, 'c1000000-0000-4000-8000-000000000004', '2026-10-06', 'text', 'x',
      '{}'::jsonb,
      '00000000-0000-4000-8000-0000000000c2/2026-10-06/chat-11111111-2222-4333-8444-555555555555.jpg'
    );
    raise exception 'a chat attachment in another user''s folder was accepted';
  exception when check_violation then
    null;
  end;

  claim := public.claim_coach_run(
    owner_id, 'coach_reply', '2026-10-06', 'reply:' || request_id::text, 'user'
  );
  if claim->>'status' <> 'claimed' then
    raise exception 'reply run was not claimed: %', claim;
  end if;

  result := public.upsert_streaming_coach_message(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, streamed_id, 'Solid ',
    '{}'::jsonb, false
  );
  if result->>'status' <> 'saved' or not (result->>'created')::boolean then
    raise exception 'first streamed chunk was not saved: %', result;
  end if;
  result := public.upsert_streaming_coach_message(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, streamed_id,
    'Solid start. Get 40g at lunch.', '{}'::jsonb, false
  );
  select * into message_row from public.coach_messages where id = streamed_id;
  if result->>'status' <> 'saved' or (result->>'created')::boolean
    or message_row.body <> 'Solid start. Get 40g at lunch.'
    or message_row.payload->>'streaming' <> 'true'
    or message_row.reply_to_id <> user_message_id
    or message_row.run_id <> (claim->>'run_id')::uuid
    or message_row.status <> 'delivered'
    or message_row.role <> 'coach' then
    raise exception 'streaming row has the wrong shape: %', pg_catalog.to_jsonb(message_row);
  end if;

  result := public.upsert_streaming_coach_message(
    (claim->>'run_id')::uuid, gen_random_uuid(), streamed_id, 'Hijacked', '{}'::jsonb, true
  );
  if result->>'status' <> 'stale' then
    raise exception 'a wrong token streamed into the reply: %', result;
  end if;

  result := public.complete_coach_run(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'complete',
    '{}'::jsonb, '[]'::jsonb, null, 'claude-sonnet-5-5'
  );
  select * into message_row from public.coach_messages where id = streamed_id;
  if result->>'status' <> 'complete' or message_row.payload ? 'streaming'
    or message_row.body <> 'Solid start. Get 40g at lunch.' then
    raise exception 'completion did not finalize the streamed reply';
  end if;
  result := public.upsert_streaming_coach_message(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, streamed_id, 'Late', '{}'::jsonb, true
  );
  if result->>'status' <> 'stale' then
    raise exception 'a completed run kept streaming: %', result;
  end if;

  -- A run that dies mid-stream keeps readable text marked interrupted; its
  -- reclaim hides the earlier attempt's output.
  perform public.post_user_coach_message(
    owner_id, second_request_id, '2026-10-06', 'text', 'What should I eat tonight?'
  );
  claim := public.claim_coach_run(
    owner_id, 'coach_reply', '2026-10-06', 'reply:' || second_request_id::text, 'user'
  );
  perform public.upsert_streaming_coach_message(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, interrupted_id,
    'Steak and potatoes, because ', '{}'::jsonb, false
  );
  if not public.fail_coach_run(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'stream dropped'
  ) then
    raise exception 'live reply run could not fail';
  end if;
  select * into message_row from public.coach_messages where id = interrupted_id;
  if message_row.payload ? 'streaming'
    or message_row.payload->>'interrupted' <> 'true'
    or message_row.body <> 'Steak and potatoes, because'
    or message_row.status <> 'delivered' then
    raise exception 'a failed stream was not marked interrupted: %', pg_catalog.to_jsonb(message_row);
  end if;
  claim := public.claim_coach_run(
    owner_id, 'coach_reply', '2026-10-06', 'reply:' || second_request_id::text, 'user'
  );
  select * into message_row from public.coach_messages where id = interrupted_id;
  if claim->>'status' <> 'reclaimed' or message_row.status <> 'superseded' then
    raise exception 'reclaim did not hide the earlier attempt''s output';
  end if;
  result := public.upsert_streaming_coach_message(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, interrupted_id,
    'Retry text', '{}'::jsonb, false
  );
  if result->>'status' <> 'conflict' then
    raise exception 'a new attempt wrote into a superseded message: %', result;
  end if;
  perform public.fail_coach_run(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'fixture cleanup'
  );

  -- Out-of-run posts are idempotent per dedupe key.
  result := public.post_coach_message(
    owner_id, 'recap', 'Week 3 is in.', '{"kind":"week","summary_id":"x"}'::jsonb,
    '2026-10-06', 'weekly:2026-09-28'
  );
  if result->>'status' <> 'created'
    or public.post_coach_message(
      owner_id, 'recap', 'Week 3 is in.', '{}'::jsonb, '2026-10-06', 'weekly:2026-09-28'
    )->>'message_id' <> result->>'message_id' then
    raise exception 'post_coach_message is not idempotent: %', result;
  end if;
end;
$$;

-- 6. Pooled AI budgets and the coach spend breaker.
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-8000-0000000000c1';
  fixture_index integer;
  rejected boolean;
  claim jsonb;
  recorded_id uuid;
  run_row private.coach_runs%rowtype;
begin
  -- A full capture pool leaves the coach pool untouched, and vice versa.
  update private.ai_job_usage set reserved_at = pg_catalog.now() - interval '25 hours';
  for fixture_index in 1..180 loop
    insert into private.ai_job_usage (user_id, operation, request_key, attempt)
    values (
      null,
      case when fixture_index <= 90 then 'meal_analysis' else 'entry_correction' end,
      'capture-pool-' || fixture_index::text,
      1
    );
  end loop;
  rejected := false;
  begin
    perform private.reserve_ai_job_usage('onboarding', owner_id, 'capture-full', 1::smallint);
  exception when raise_exception then
    rejected := sqlerrm = 'project_ai_budget_exceeded';
  end;
  if not rejected then
    raise exception 'capture pool accepted reservation 181';
  end if;
  if not private.reserve_ai_job_usage('coach_reply', owner_id, 'coach-free', 1::smallint) then
    raise exception 'a full capture pool blocked the coach pool';
  end if;

  update private.ai_job_usage set reserved_at = pg_catalog.now() - interval '25 hours';
  for fixture_index in 1..400 loop
    insert into private.ai_job_usage (user_id, operation, request_key, attempt)
    values (
      null,
      case
        when fixture_index <= 150 then 'coach_reply'
        when fixture_index <= 300 then 'coach_checkpoint'
        when fixture_index <= 360 then 'activity_analysis'
        else 'nearby_research'
      end,
      'coach-pool-' || fixture_index::text,
      1
    );
  end loop;
  rejected := false;
  begin
    perform private.reserve_ai_job_usage('training_plan', owner_id, 'coach-full', 1::smallint);
  exception when raise_exception then
    rejected := sqlerrm = 'project_ai_budget_exceeded';
  end;
  if not rejected then
    raise exception 'coach pool accepted reservation 401';
  end if;
  claim := public.claim_coach_run(owner_id, 'training_plan', '2026-10-06', 'pool_full');
  if claim->>'status' <> 'quota' or claim->>'reason' <> 'project_ai_budget_exceeded'
    or exists (
      select 1 from private.coach_runs
      where user_id = owner_id and checkpoint_key = 'pool_full'
    ) then
    raise exception 'a pool-exhausted claim was not reported as quota: %', claim;
  end if;
  if not private.reserve_ai_job_usage('meal_analysis', owner_id, 'meal-free', 1::smallint) then
    raise exception 'a full coach pool blocked meal capture';
  end if;

  -- Per-operation caps still apply inside the coach pool.
  update private.ai_job_usage set reserved_at = pg_catalog.now() - interval '25 hours';
  for fixture_index in 1..12 loop
    insert into private.ai_job_usage (user_id, operation, request_key, attempt)
    values (null, 'day_digest', 'digest-cap-' || fixture_index::text, 1);
  end loop;
  rejected := false;
  begin
    perform private.reserve_ai_job_usage('day_digest', owner_id, 'digest-13', 1::smallint);
  exception when raise_exception then
    rejected := sqlerrm = 'project_ai_budget_exceeded';
  end;
  if not rejected then
    raise exception 'day_digest accepted reservation 13';
  end if;

  -- Cost ledger linkage, then the rolling spend breaker.
  update private.ai_job_usage set reserved_at = pg_catalog.now() - interval '25 hours';
  claim := public.claim_coach_run(owner_id, 'coach_checkpoint', '2026-10-06', 'spend_probe');
  recorded_id := public.record_ai_provider_call(
    owner_id, 'coach_checkpoint', 'coach_plan', 'claude-sonnet-5-5',
    1200, 300, 8000, 0, 0, 7000::bigint, '2026-10-06',
    (claim->>'run_id')::uuid
  );
  select * into run_row from private.coach_runs where id = (claim->>'run_id')::uuid;
  if not exists (
    select 1
    from private.ai_provider_calls as call
    join private.ai_job_usage as usage on usage.id = call.usage_id
    where call.id = recorded_id
      and call.run_id = run_row.id
      and usage.request_key = '2026-10-06:spend_probe'
      and usage.attempt = 1
      and call.cost_usd_micros = 7000
  ) then
    raise exception 'provider call was not linked to its run reservation';
  end if;
  begin
    perform public.record_ai_provider_call(
      owner_id, 'coach_checkpoint', 'Not A Workload!', 'claude-sonnet-5-5',
      1, 1, 0, 0, 0, 1::bigint, '2026-10-06'
    );
    raise exception 'an invalid workload label was recorded';
  exception when check_violation then
    null;
  end;

  insert into private.ai_provider_calls (
    user_id, operation, workload, model, cost_usd_micros, pricing_version
  ) values (
    null, 'day_digest', 'fixture', 'claude-fable-5-1', 25000000, 'fixture'
  );
  rejected := false;
  begin
    perform private.reserve_ai_job_usage('coach_reply', owner_id, 'spend-capped', 1::smallint);
  exception when raise_exception then
    rejected := sqlerrm = 'project_ai_spend_exceeded';
  end;
  if not rejected then
    raise exception 'the coach spend breaker did not trip at $25';
  end if;
  claim := public.claim_coach_run(owner_id, 'coach_checkpoint', '2026-10-06', 'spend_capped');
  if claim->>'status' <> 'quota' or claim->>'reason' <> 'project_ai_spend_exceeded' then
    raise exception 'a spend-capped claim was not reported as quota: %', claim;
  end if;
  if not private.reserve_ai_job_usage('meal_analysis', owner_id, 'meal-after-spend', 1::smallint) then
    raise exception 'coach spend blocked meal capture';
  end if;
  delete from private.ai_provider_calls where workload = 'fixture';
  update private.ai_job_usage set reserved_at = pg_catalog.now() - interval '25 hours';
end;
$$;

-- 7. Thread RLS: own rows only, read_at is the only client write, clamped
--    and monotonic, and only for visible rows.
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c2', true);

do $$
begin
  if exists (select 1 from public.coach_messages)
    or exists (select 1 from public.coach_memory)
    or exists (select 1 from public.training_plans)
    or exists (select 1 from public.activities)
    or exists (select 1 from public.day_digests) then
    raise exception 'another user''s coach rows are visible';
  end if;
  update public.coach_messages set read_at = pg_catalog.now();
  if found then
    raise exception 'a user marked another user''s messages read';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c1', true);

do $$
declare
  visible_unread integer;
  touched integer;
  stored_read_at timestamptz;
begin
  select count(*) into visible_unread
  from public.coach_messages
  where role = 'coach' and read_at is null
    and status <> 'superseded' and deliver_at <= pg_catalog.now();
  if visible_unread < 3 then
    raise exception 'thread fixture has too few visible coach rows: %', visible_unread;
  end if;

  update public.coach_messages
  set read_at = pg_catalog.now() + interval '1 day'
  where role = 'coach';
  get diagnostics touched = row_count;
  if touched <> visible_unread then
    raise exception 'mark-read touched % rows; % were visible', touched, visible_unread;
  end if;
  if exists (
    select 1 from public.coach_messages
    where role = 'coach' and (status = 'superseded' or deliver_at > pg_catalog.now())
      and read_at is not null
  ) then
    raise exception 'hidden or future rows were marked read';
  end if;
  select max(read_at) into stored_read_at from public.coach_messages where role = 'coach';
  if stored_read_at <> pg_catalog.now() then
    raise exception 'read_at was not clamped to now(): %', stored_read_at;
  end if;

  update public.coach_messages set read_at = '2020-01-01' where role = 'coach';
  if exists (
    select 1 from public.coach_messages where role = 'coach' and read_at = '2020-01-01'
  ) then
    raise exception 'read_at was rewound';
  end if;

  begin
    update public.coach_messages set body = 'edited' where role = 'coach';
    raise exception 'a client edited a coach message body';
  exception when insufficient_privilege then
    null;
  end;
  begin
    insert into public.coach_messages (user_id, role, kind, body, local_day, client_request_id)
    values (
      '00000000-0000-4000-8000-0000000000c1', 'user', 'text', 'forged',
      '2026-10-06', gen_random_uuid()
    );
    raise exception 'a client inserted a coach message';
  exception when insufficient_privilege then
    null;
  end;
end;
$$;

reset role;

-- 8. Activities: server-written, owner-deletable, fenced analysis, durable
--    photo cleanup, and capture quotas.
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-8000-0000000000c1';
  activity_id uuid;
  second_activity_id uuid;
  claim jsonb;
  saved text;
  rejected boolean;
  fixture_index integer;
begin
  insert into public.activities (
    user_id, client_request_id, local_day, status, source, title, input_text,
    speech_engine
  ) values (
    owner_id, 'ac000000-0000-4000-8000-000000000001', '2026-10-06', 'processing',
    'voice', 'Workout', 'Bench 185 for 5x5, then rows', 'apple.speech_transcriber'
  ) returning id into activity_id;

  claim := public.claim_coach_run(
    owner_id, 'activity_analysis', '2026-10-06', 'activity:' || activity_id::text, 'event'
  );
  saved := public.save_activity_analysis(
    (claim->>'run_id')::uuid, gen_random_uuid(), activity_id, '{"title":"Upper"}'::jsonb
  );
  if saved <> 'stale' then
    raise exception 'activity analysis accepted a wrong token: %', saved;
  end if;
  saved := public.save_activity_analysis(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, gen_random_uuid(),
    '{"title":"Upper"}'::jsonb
  );
  if saved <> 'stale' then
    raise exception 'activity analysis accepted a different activity: %', saved;
  end if;
  saved := public.save_activity_analysis(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, activity_id,
    pg_catalog.jsonb_build_object(
      'kind', 'strength', 'title', 'Upper A', 'duration_min', 62,
      'active_kcal', 310.4, 'intensity', 'hard', 'rpe', 8.5, 'confidence', 0.9,
      'model', 'claude-sonnet-5-5',
      'details', pg_catalog.jsonb_build_object(
        'exercises', pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
          'name', 'Barbell bench press',
          'sets', pg_catalog.jsonb_build_array(
            pg_catalog.jsonb_build_object('reps', 5, 'weight', 185, 'unit', 'lb')
          )
        )),
        'prs', '[]'::jsonb,
        'burn_method', 'met'
      )
    )
  );
  if saved <> 'saved' or not exists (
    select 1 from public.activities
    where id = activity_id and status = 'complete' and kind = 'strength'
      and title = 'Upper A' and processed_at is not null
      and details->>'burn_method' = 'met'
  ) then
    raise exception 'fenced activity analysis was not saved: %', saved;
  end if;
  perform public.complete_coach_run(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'complete',
    pg_catalog.jsonb_build_object('activity_id', activity_id)
  );

  -- A non-retryable analysis failure fails the activity immediately.
  insert into public.activities (
    user_id, client_request_id, local_day, status, source, title
  ) values (
    owner_id, 'ac000000-0000-4000-8000-000000000002', '2026-10-06', 'processing',
    'text', 'Workout'
  ) returning id into second_activity_id;
  claim := public.claim_coach_run(
    owner_id, 'activity_analysis', '2026-10-06', 'activity:' || second_activity_id::text
  );
  perform public.fail_coach_run(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'unreadable', false
  );
  if not exists (
    select 1 from public.activities
    where id = second_activity_id and status = 'failed' and error_message is not null
  ) then
    raise exception 'a terminal analysis failure left the activity processing';
  end if;

  -- Concurrency quota: three in flight at most.
  for fixture_index in 1..3 loop
    insert into public.activities (
      user_id, client_request_id, local_day, status, source, title
    ) values (
      owner_id, gen_random_uuid(), '2026-10-06', 'processing', 'text', 'Workout'
    );
  end loop;
  rejected := false;
  begin
    insert into public.activities (
      user_id, client_request_id, local_day, status, source, title
    ) values (
      owner_id, gen_random_uuid(), '2026-10-06', 'processing', 'text', 'Workout'
    );
  exception when raise_exception then
    rejected := sqlerrm = 'activity_concurrency_quota_exceeded';
  end;
  if not rejected then
    raise exception 'a fourth concurrent activity was accepted';
  end if;

  update public.activities
  set image_path = owner_id::text
    || '/2026-10-06/activity-22222222-3333-4444-8555-666666666666.jpg'
  where id = activity_id;
  begin
    update public.activities
    set image_path = '00000000-0000-4000-8000-0000000000c2/2026-10-06/activity-22222222-3333-4444-8555-666666666666.jpg'
    where id = activity_id;
    raise exception 'an activity photo in another user''s folder was accepted';
  exception when check_violation then
    null;
  end;
end;
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c1', true);

do $$
declare
  deleted integer;
begin
  begin
    insert into public.activities (user_id, client_request_id, local_day, title)
    values (
      '00000000-0000-4000-8000-0000000000c1', gen_random_uuid(), '2026-10-06', 'Run'
    );
    raise exception 'a client inserted an activity directly';
  exception when insufficient_privilege then
    null;
  end;
  begin
    update public.activities set title = 'Edited';
    raise exception 'a client edited an activity directly';
  exception when insufficient_privilege then
    null;
  end;

  delete from public.activities where status = 'processing';
  get diagnostics deleted = row_count;
  if deleted <> 0 then
    raise exception 'an in-flight activity was deletable';
  end if;
  delete from public.activities where title = 'Upper A';
  get diagnostics deleted = row_count;
  if deleted <> 1 then
    raise exception 'the owner could not delete a finished activity';
  end if;
end;
$$;

reset role;

do $$
begin
  if not exists (
    select 1 from private.storage_cleanup_jobs
    where bucket = 'coach-media'
      and mode = 'object'
      and object_path = '00000000-0000-4000-8000-0000000000c1/2026-10-06/activity-22222222-3333-4444-8555-666666666666.jpg'
  ) then
    raise exception 'deleting an activity did not queue its photo for cleanup';
  end if;
  if private.enqueue_storage_cleanup_job(
    'weight-checkin-photos', 'object',
    '00000000-0000-4000-8000-0000000000c1/2026-10-06/progress-x.jpg'
  ) is null then
    raise exception 'weight-checkin-photos is not an allowed cleanup bucket';
  end if;
  begin
    perform private.enqueue_storage_cleanup_job('profile-photos', 'object', 'a/b.jpg');
    raise exception 'an unlisted cleanup bucket was accepted';
  exception when invalid_parameter_value then
    null;
  end;
end;
$$;

-- 9. Body check-ins: photo-only days, observation check, server-only review.
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c1', true);

do $$
begin
  insert into public.weight_checkins (
    user_id, local_day, progress_photo_path, photo_pose, note, photo_captured_at
  ) values (
    '00000000-0000-4000-8000-0000000000c1', '2026-10-06',
    '00000000-0000-4000-8000-0000000000c1/2026-10-06/progress-33333333-4444-4555-8666-777777777777.jpg',
    'front_relaxed', 'Morning, fasted', pg_catalog.now()
  );
  begin
    insert into public.weight_checkins (user_id, local_day, note)
    values ('00000000-0000-4000-8000-0000000000c1', '2026-10-05', 'Nothing logged');
    raise exception 'a check-in without weight or photo was accepted';
  exception when check_violation then
    null;
  end;
  -- The pre-2.0 weigh-in upsert still works under column grants.
  insert into public.weight_checkins (user_id, local_day, weight_kg)
  values ('00000000-0000-4000-8000-0000000000c1', '2026-10-06', 73.7)
  on conflict (user_id, local_day) do update set weight_kg = excluded.weight_kg;
  if not exists (
    select 1 from public.weight_checkins
    where local_day = '2026-10-06' and weight_kg = 73.7
      and progress_photo_path is not null
  ) then
    raise exception 'weigh-in upsert lost the photo or the weight';
  end if;
  begin
    update public.weight_checkins
    set coach_review = '{"headline":"forged"}'::jsonb,
        coach_reviewed_at = pg_catalog.now(),
        coach_reviewed_photo_path = progress_photo_path;
    raise exception 'a client wrote a coach review';
  exception when insufficient_privilege then
    null;
  end;
end;
$$;

reset role;

do $$
declare
  owner_id constant uuid := '00000000-0000-4000-8000-0000000000c1';
  checkin_id uuid;
  claim jsonb;
  saved text;
begin
  select id into checkin_id from public.weight_checkins
  where user_id = owner_id and local_day = '2026-10-06';
  update public.profiles set physique_ai_review_enabled = true where user_id = owner_id;
  claim := public.claim_coach_run(
    owner_id, 'body_review', '2026-10-06', 'body_review:33333333-4444-4555-8666-777777777777'
  );
  if claim->>'status' <> 'claimed' then
    raise exception 'opted-in body review was not claimed: %', claim;
  end if;
  saved := public.save_body_review(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, checkin_id,
    '{"photo_path":"00000000-0000-4000-8000-0000000000c1/2026-10-06/progress-00000000-0000-4000-8000-000000000000.jpg","headline":"x"}'::jsonb,
    'claude-opus-5-5'
  );
  if saved <> 'stale' then
    raise exception 'a review landed on a replaced photo: %', saved;
  end if;
  saved := public.save_body_review(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, checkin_id,
    pg_catalog.jsonb_build_object(
      'photo_path', owner_id::text
        || '/2026-10-06/progress-33333333-4444-4555-8666-777777777777.jpg',
      'headline', 'Shoulders filling out.',
      'observations', '[]'::jsonb,
      'bulk_quality', 'on_track'
    ),
    'claude-opus-5-5'
  );
  if saved <> 'saved' or not exists (
    select 1 from public.weight_checkins
    where id = checkin_id and coach_review->>'bulk_quality' = 'on_track'
      and coach_reviewed_photo_path = progress_photo_path
      and coach_review_model = 'claude-opus-5-5'
  ) then
    raise exception 'fenced body review was not saved: %', saved;
  end if;
  perform public.complete_coach_run(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'complete', '{}'::jsonb,
    pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'kind', 'photo_feedback', 'body', 'Shoulders are filling out.',
      'payload', pg_catalog.jsonb_build_object('local_day', '2026-10-06')
    ))
  );
end;
$$;

-- 10. Day digests and version-locked coach memory.
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-8000-0000000000c1';
  claim jsonb;
  saved text;
  memory_result jsonb;
  revision_count integer;
begin
  claim := public.claim_coach_run(owner_id, 'day_digest', '2026-10-05', 'digest', 'schedule');
  saved := public.save_day_digest(
    (claim->>'run_id')::uuid, gen_random_uuid(),
    '{"headline":"x","summary":"y","model":"claude-fable-5-1"}'::jsonb
  );
  if saved <> 'stale' then
    raise exception 'a digest accepted a wrong token: %', saved;
  end if;
  saved := public.save_day_digest(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid,
    pg_catalog.jsonb_build_object(
      'headline', 'Protein short by 30g.',
      'summary', 'Three meals, one lift.',
      'score', 72,
      'model', 'claude-fable-5-1',
      'input_fingerprint', 'fp-1',
      'game_plan', pg_catalog.jsonb_build_object(
        'theme', 'Front-load protein',
        'focus', pg_catalog.jsonb_build_array('40g at breakfast'),
        'training', pg_catalog.jsonb_build_object('session_name', 'Lower A')
      )
    )
  );
  if saved <> 'saved' then
    raise exception 'digest was not saved: %', saved;
  end if;
  saved := public.save_day_digest(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid,
    '{"headline":"Protein short by 25g.","summary":"Revised.","model":"claude-fable-5-1"}'::jsonb
  );
  if saved <> 'saved' or not exists (
    select 1 from public.day_digests
    where user_id = owner_id and local_day = '2026-10-05'
      and headline = 'Protein short by 25g.' and game_plan = '{}'::jsonb
  ) or (select count(*) from public.day_digests where user_id = owner_id) <> 1 then
    raise exception 'digest did not upsert in place';
  end if;

  memory_result := public.save_coach_memory(
    owner_id, 0, '# Luke\nLean bulk 162.5 to 175 lb.',
    '{"bio":{"goals":"Lean bulk to 175 lb."},"notes":{},"schedule":{"wake":"07:00"},"equipment":[]}'::jsonb,
    'seed', 'Seeded bio'
  );
  if memory_result->>'status' <> 'saved' or (memory_result->>'version')::integer <> 1 then
    raise exception 'first memory save failed: %', memory_result;
  end if;
  memory_result := public.save_coach_memory(
    owner_id, 0, '# Luke\nConflicting write.', '{}'::jsonb, 'coach_reply', null
  );
  if memory_result->>'status' <> 'conflict' or (memory_result->>'version')::integer <> 1 then
    raise exception 'a stale memory version was not rejected: %', memory_result;
  end if;
  memory_result := public.save_coach_memory(
    owner_id, 1, '# Luke\nNote: hates oatmeal.', '{"bio":{},"notes":{"food":"No oatmeal."}}'::jsonb,
    'day_digest', 'Learned a food dislike', (claim->>'run_id')::uuid, null,
    gen_random_uuid()
  );
  if memory_result->>'status' <> 'stale' then
    raise exception 'memory accepted a wrong run token: %', memory_result;
  end if;
  memory_result := public.save_coach_memory(
    owner_id, 1, '# Luke\nNote: hates oatmeal.', '{"bio":{},"notes":{"food":"No oatmeal."}}'::jsonb,
    'day_digest', 'Learned a food dislike', (claim->>'run_id')::uuid, null,
    (claim->>'claim_token')::uuid
  );
  select count(*) into revision_count from public.coach_memory_revisions
  where user_id = owner_id;
  if memory_result->>'status' <> 'saved' or (memory_result->>'version')::integer <> 2
    or revision_count <> 2 or not exists (
      select 1 from public.coach_memory_revisions
      where user_id = owner_id and version = 2 and run_id = (claim->>'run_id')::uuid
        and source = 'day_digest'
    ) then
    raise exception 'fenced memory save or its revision failed: %', memory_result;
  end if;
  begin
    perform public.save_coach_memory(
      owner_id, 2, '# Luke', '{"bio":["not","an","object"]}'::jsonb, 'manual', null
    );
    raise exception 'memory accepted a non-object bio';
  exception when check_violation then
    null;
  end;
  perform public.complete_coach_run(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'complete', '{}'::jsonb
  );
end;
$$;

-- 11. Training plans: one draft, one active, activation by explicit call.
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-8000-0000000000c1';
  plan_doc constant jsonb := '{"version":1,"name":"Upper/Lower 4x","phase":"lean_bulk","sessions_per_week":4,"rotation":["upper_a","lower_a"],"sessions":[{"id":"upper_a","name":"Upper A","exercises":[]}]}'::jsonb;
  first_id uuid;
  second_id uuid;
  third_id uuid;
  result jsonb;
  claim jsonb;
begin
  result := public.save_training_plan_draft(
    owner_id, plan_doc, 'Four lift days fit the schedule.', 'First plan'
  );
  first_id := (result->>'plan_id')::uuid;
  result := public.save_training_plan_draft(owner_id, plan_doc, null, 'Revised');
  second_id := (result->>'plan_id')::uuid;
  if (result->>'superseded_draft_id')::uuid <> first_id
    or (select count(*) from public.training_plans
        where user_id = owner_id and status = 'draft') <> 1 then
    raise exception 'a second draft did not supersede the first: %', result;
  end if;

  result := public.activate_training_plan(owner_id, second_id);
  if result->>'status' <> 'activated' or result->>'previous_plan_id' is not null then
    raise exception 'draft activation failed: %', result;
  end if;
  if public.activate_training_plan(owner_id, second_id)->>'status' <> 'already_active' then
    raise exception 'activating the active plan was not idempotent';
  end if;

  claim := public.claim_coach_run(owner_id, 'training_plan', '2026-10-06', 'plan_rebuild');
  result := public.save_training_plan_draft(
    owner_id, plan_doc, null, 'Weekly tweak', 'weekly', 'claude-opus-5-5',
    (claim->>'run_id')::uuid, gen_random_uuid()
  );
  if result->>'status' <> 'stale' then
    raise exception 'a plan draft accepted a wrong run token: %', result;
  end if;
  result := public.save_training_plan_draft(
    owner_id, plan_doc, null, 'Weekly tweak', 'weekly', 'claude-opus-5-5',
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid
  );
  third_id := (result->>'plan_id')::uuid;
  perform public.complete_coach_run(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'complete',
    pg_catalog.jsonb_build_object('plan_id', third_id)
  );
  result := public.activate_training_plan(owner_id, third_id);
  if result->>'status' <> 'activated' or (result->>'previous_plan_id')::uuid <> second_id then
    raise exception 'activation did not supersede the previous plan: %', result;
  end if;
  -- Undo: the superseded plan can be re-activated.
  result := public.activate_training_plan(owner_id, second_id);
  if result->>'status' <> 'activated' or (result->>'previous_plan_id')::uuid <> third_id
    or (select count(*) from public.training_plans
        where user_id = owner_id and status = 'active') <> 1 then
    raise exception 'undo activation failed: %', result;
  end if;

  result := public.save_training_plan_draft(owner_id, plan_doc, null, 'Discard me');
  if public.discard_training_plan_draft(owner_id, (result->>'plan_id')::uuid)->>'status'
      <> 'rejected'
    or public.activate_training_plan(owner_id, (result->>'plan_id')::uuid)->>'status'
      <> 'invalid_state' then
    raise exception 'a discarded draft could still be activated';
  end if;
  if public.activate_training_plan(
    '00000000-0000-4000-8000-0000000000c2', second_id
  )->>'status' <> 'not_found' then
    raise exception 'another user activated this plan';
  end if;

  begin
    perform public.save_training_plan_draft(
      owner_id, '{"version":2,"name":"x","sessions":[]}'::jsonb
    );
    raise exception 'a non-v1 plan document was accepted';
  exception when check_violation then
    null;
  end;
end;
$$;

-- 12. Device snapshots and coach-media Storage as the client.
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-0000000000c1', true);

do $$
declare
  stored_latitude numeric;
begin
  insert into public.device_snapshots (
    user_id, device_id, app_version, os_version, timezone, notification_status,
    location_status, coarse_latitude, coarse_longitude, location_captured_at,
    city, region, country_code, nearby, nearby_captured_at
  ) values (
    '00000000-0000-4000-8000-0000000000c1', 'de000000-0000-4000-8000-000000000001',
    '2.0', '26.1', 'America/New_York', 'authorized', 'when_in_use',
    40.712776, -74.005974, pg_catalog.now(), 'New York', 'NY', 'US',
    '[{"ref":"s1","name":"CVS","category":"pharmacy","distance_m":210,"walk_minutes":3,"walk_minutes_source":"mapkit_eta"}]'::jsonb,
    pg_catalog.now()
  );
  select coarse_latitude into stored_latitude from public.device_snapshots;
  if stored_latitude <> 40.713 then
    raise exception 'coarse latitude was not rounded to 3 decimals: %', stored_latitude;
  end if;

  insert into public.device_snapshots (user_id, device_id, timezone, notification_status)
  values (
    '00000000-0000-4000-8000-0000000000c1', 'de000000-0000-4000-8000-000000000001',
    'America/Chicago', 'denied'
  )
  on conflict (user_id, device_id) do update
  set timezone = excluded.timezone, notification_status = excluded.notification_status;
  if (select timezone from public.device_snapshots) <> 'America/Chicago' then
    raise exception 'device snapshot upsert failed';
  end if;

  begin
    update public.device_snapshots set timezone = 'Mars/Olympus_Mons';
    raise exception 'an invalid device timezone was stored';
  exception when invalid_parameter_value then
    null;
  end;
  begin
    update public.device_snapshots
    set nearby = '[{"name":"CVS","lat":40.71,"lng":-74.0}]'::jsonb;
    raise exception 'nearby stores carried coordinates';
  exception when check_violation then
    null;
  end;
  begin
    insert into public.device_snapshots (user_id, device_id, timezone)
    values (
      '00000000-0000-4000-8000-0000000000c2', gen_random_uuid(), 'UTC'
    );
    raise exception 'a device snapshot crossed the owner boundary';
  exception when insufficient_privilege then
    null;
  end;
  begin
    update public.device_snapshots set created_at = pg_catalog.now();
    raise exception 'a client rewrote device created_at';
  exception when insufficient_privilege then
    null;
  end;

  insert into storage.objects (bucket_id, name)
  values (
    'coach-media',
    '00000000-0000-4000-8000-0000000000c1/2026-10-06/chat-44444444-5555-4666-8777-888888888888.jpg'
  );
  if not exists (select 1 from storage.objects where bucket_id = 'coach-media') then
    raise exception 'the owner cannot read their coach-media upload';
  end if;
  begin
    insert into storage.objects (bucket_id, name)
    values (
      'coach-media',
      '00000000-0000-4000-8000-0000000000c2/2026-10-06/chat-44444444-5555-4666-8777-888888888888.jpg'
    );
    raise exception 'a coach-media upload crossed the owner boundary';
  exception when insufficient_privilege then
    null;
  end;
  begin
    insert into storage.objects (bucket_id, name)
    values (
      'coach-media',
      '00000000-0000-4000-8000-0000000000c1/2026-10-06/progress-44444444-5555-4666-8777-888888888888.jpg'
    );
    raise exception 'coach-media accepted a non chat/activity name';
  exception when insufficient_privilege then
    null;
  end;
  delete from storage.objects where bucket_id = 'coach-media';
  if not exists (select 1 from storage.objects where bucket_id = 'coach-media') then
    raise exception 'a client deleted a coach-media object';
  end if;
end;
$$;

reset role;

-- 13. Housekeeping delivers due rows, interrupts dead streams, and fails
--     stuck activities.
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-8000-0000000000c1';
  report jsonb;
  claim jsonb;
  stuck_id uuid;
begin
  insert into public.coach_messages (
    user_id, role, kind, body, local_day, deliver_at, status, notify, slot_key
  ) values (
    owner_id, 'coach', 'checkpoint', 'Due now.', '2026-10-06',
    pg_catalog.now() - interval '1 minute', 'scheduled', true, 'housekeeping_due'
  );

  claim := public.claim_coach_run(
    owner_id, 'coach_reply', '2026-10-06',
    'reply:c1000000-0000-4000-8000-0000000000ff', 'user'
  );
  perform public.upsert_streaming_coach_message(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid,
    'c1500000-0000-4000-8000-0000000000ff', 'Half a thought', '{}'::jsonb, false
  );
  update private.coach_runs
  set lease_expires_at = pg_catalog.now() - interval '2 hours'
  where id = (claim->>'run_id')::uuid;

  insert into public.activities (
    user_id, client_request_id, local_day, status, source, title
  ) values (
    owner_id, 'ac000000-0000-4000-8000-0000000000ff', '2026-10-06', 'complete',
    'text', 'Walk'
  ) returning id into stuck_id;
  update public.activities
  set status = 'processing'
  where id = stuck_id;
  -- updated_at is set by trigger; age it with the trigger bypassed by role.
  alter table public.activities disable trigger activities_set_updated_at;
  update public.activities
  set updated_at = pg_catalog.now() - interval '31 minutes'
  where id = stuck_id;
  alter table public.activities enable trigger activities_set_updated_at;

  report := public.run_coach_housekeeping();
  if (report->>'delivered')::integer < 1
    or (report->>'expired_runs')::integer < 1
    or (report->>'interrupted_messages')::integer < 1
    or (report->>'failed_activities')::integer < 1 then
    raise exception 'housekeeping report is incomplete: %', report;
  end if;
  if not exists (
    select 1 from public.coach_messages
    where slot_key = 'housekeeping_due' and status = 'delivered'
  ) or not exists (
    select 1 from public.coach_messages
    where id = 'c1500000-0000-4000-8000-0000000000ff'
      and not (payload ? 'streaming') and payload->>'interrupted' = 'true'
  ) or not exists (
    select 1 from public.activities where id = stuck_id and status = 'failed'
  ) then
    raise exception 'housekeeping did not repair due, interrupted, and stuck rows';
  end if;
end;
$$;

-- 14. Account deletion cascades every coach row.
do $$
declare
  departing_id constant uuid := '00000000-0000-4000-8000-0000000000c2';
  claim jsonb;
  meal_id uuid;
  user_message_id uuid;
begin
  update public.profiles set coach_enabled = true where user_id = departing_id;
  user_message_id := (public.post_user_coach_message(
    departing_id, 'c2000000-0000-4000-8000-000000000001', '2026-10-06', 'text', 'Bye'
  )->>'message_id')::uuid;
  insert into public.entries (
    user_id, client_request_id, local_day, status, calories_kcal, protein_g
  ) values (
    departing_id, 'c2e00000-0000-4000-8000-000000000001', '2026-10-06', 'complete', 500, 40
  ) returning id into meal_id;
  claim := public.claim_coach_run(departing_id, 'coach_checkpoint', '2026-10-06', 'morning');
  perform public.complete_coach_run(
    (claim->>'run_id')::uuid, (claim->>'claim_token')::uuid, 'complete', '{}'::jsonb,
    pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('kind', 'checkpoint', 'body', 'Morning.'),
      pg_catalog.jsonb_build_object(
        'kind', 'meal_ack', 'body', 'Good start.', 'entry_id', meal_id,
        'reply_to_id', user_message_id,
        'payload', pg_catalog.jsonb_build_object('entry_id', meal_id)
      )
    )
  );
  begin
    perform public.post_coach_message(
      departing_id, 'meal_ack', 'Not yours.', '{}'::jsonb, '2026-10-06', 'cross-link',
      false, null, null,
      (select id from public.entries
       where user_id = '00000000-0000-4000-8000-000000000001' limit 1)
    );
    raise exception 'a coach message linked another user''s meal';
  exception when foreign_key_violation then
    null;
  end;
  perform public.save_coach_memory(departing_id, 0, '# Two', '{}'::jsonb, 'seed', null);
  perform public.save_training_plan_draft(
    departing_id, '{"version":1,"name":"x","sessions":[]}'::jsonb
  );
  insert into public.activities (user_id, client_request_id, local_day, title)
  values (departing_id, gen_random_uuid(), '2026-10-06', 'Run');
  insert into public.device_snapshots (user_id, device_id, timezone)
  values (departing_id, gen_random_uuid(), 'UTC');

  delete from auth.users where id = departing_id;

  if exists (select 1 from public.coach_messages where user_id = departing_id)
    or exists (select 1 from private.coach_runs where user_id = departing_id)
    or exists (select 1 from public.coach_memory where user_id = departing_id)
    or exists (select 1 from public.coach_memory_revisions where user_id = departing_id)
    or exists (select 1 from public.training_plans where user_id = departing_id)
    or exists (select 1 from public.activities where user_id = departing_id)
    or exists (select 1 from public.device_snapshots where user_id = departing_id)
    or exists (select 1 from public.day_digests where user_id = departing_id) then
    raise exception 'account deletion left coach rows behind';
  end if;
end;
$$;

rollback;
