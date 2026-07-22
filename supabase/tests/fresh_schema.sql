\set ON_ERROR_STOP on
\ir bootstrap.sql

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'postgres') then
    create role postgres nologin;
  end if;
end;
$$;

\ir ../migrations/20260720221116_rebuild_shudo_core.sql
\ir ../migrations/20260721125035_add_analysis_streaming_preview.sql
\ir ../migrations/20260721222010_restrict_rls_auto_enable_execute.sql
\ir ../migrations/20260721223105_account_onboarding_corrections_weekly.sql
\ir ../migrations/20260721231126_harden_target_history_weekly_claims.sql
\ir ../migrations/20260721234531_add_voice_entry_correction_requests.sql
\ir ../migrations/20260722001415_project_ai_budget_timezone.sql

insert into auth.users (id, email)
values
  ('00000000-0000-4000-8000-000000000001', 'one@example.test'),
  ('00000000-0000-4000-8000-000000000002', 'two@example.test');

insert into public.entries (
  user_id,
  client_request_id,
  local_day,
  status,
  protein_g,
  carbs_g,
  fat_g,
  calories_kcal
)
values
  (
    '00000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000001',
    '2026-07-20',
    'complete',
    25,
    50,
    10,
    390
  ),
  (
    '00000000-0000-4000-8000-000000000002',
    '10000000-0000-4000-8000-000000000002',
    '2026-07-20',
    'complete',
    99,
    99,
    99,
    999
  ),
  (
    '00000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000003',
    '2026-07-20',
    'queued',
    0,
    0,
    0,
    0
  );

do $$
begin
  if has_table_privilege('anon', 'public.entries', 'select') then
    raise exception 'anon unexpectedly has entries SELECT';
  end if;
  if has_table_privilege('authenticated', 'public.entries', 'delete') then
    raise exception 'authenticated unexpectedly has entries DELETE';
  end if;
  if has_table_privilege('authenticated', 'public.entries', 'update') then
    raise exception 'authenticated unexpectedly has entries UPDATE';
  end if;
  if not has_table_privilege(
    'service_role',
    'public.entries',
    'select,insert,update,delete'
  ) then
    raise exception 'service_role is missing Edge Function table privileges';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.claim_entry_upload(uuid, uuid)',
    'execute'
  ) then
    raise exception 'authenticated unexpectedly can claim uploads';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.claim_entry_processing(uuid, uuid)',
    'execute'
  ) then
    raise exception 'authenticated unexpectedly can claim processing';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.fail_stale_entry_upload(uuid, uuid, uuid)',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'public.fail_stale_incomplete_entry(uuid, uuid)',
    'execute'
  ) then
    raise exception 'authenticated unexpectedly can repair stale uploads';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.fail_exhausted_entry_processing(uuid, uuid, smallint)',
    'execute'
  ) then
    raise exception 'authenticated unexpectedly can repair exhausted processing';
  end if;
  if has_function_privilege(
    'anon',
    'public.fail_stale_entry_upload(uuid, uuid, uuid)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'public.fail_stale_incomplete_entry(uuid, uuid)',
    'execute'
  ) or has_function_privilege(
    'anon',
    'public.fail_exhausted_entry_processing(uuid, uuid, smallint)',
    'execute'
  ) then
    raise exception 'anon unexpectedly can execute a repair RPC';
  end if;
  if not has_function_privilege(
    'service_role',
    'public.fail_stale_entry_upload(uuid, uuid, uuid)',
    'execute'
  ) or not has_function_privilege(
    'service_role',
    'public.fail_stale_incomplete_entry(uuid, uuid)',
    'execute'
  ) or not has_function_privilege(
    'service_role',
    'public.fail_exhausted_entry_processing(uuid, uuid, smallint)',
    'execute'
  ) then
    raise exception 'service_role is missing repair RPC privileges';
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'entries'
  ) then
    raise exception 'entries is missing from Realtime publication';
  end if;
end;
$$;

\ir ai_budget_timezone.sql

\ir voice_corrections.sql

-- Streamed previews stay bounded and are replaced/terminalized under the same
-- attempt fence as the durable processor state.
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-8000-000000000001';
  preview_entry_id constant uuid := '50000000-0000-4000-8000-000000000001';
  claimed_attempt smallint;
  repaired boolean;
  stored_preview text;
  rejected boolean := false;
begin
  insert into public.entries (
    id,
    user_id,
    client_request_id,
    local_day,
    status,
    processing_attempts
  ) values (
    preview_entry_id,
    owner_id,
    '51000000-0000-4000-8000-000000000001',
    '2026-07-21',
    'queued',
    0
  );

  select public.claim_entry_processing(preview_entry_id, owner_id)
  into claimed_attempt;
  if claimed_attempt <> 1 then
    raise exception 'preview fixture did not acquire its first attempt';
  end if;

  update public.entries
  set analysis_preview = 'A chicken bowl with rice and vegetables.'
  where id = preview_entry_id;

  begin
    update public.entries
    set analysis_preview = repeat('x', 241)
    where id = preview_entry_id;
  exception when check_violation then
    rejected := true;
  end;
  if not rejected then
    raise exception 'preview constraint accepted more than 240 characters';
  end if;

  update public.entries
  set lease_expires_at = now() - interval '1 second'
  where id = preview_entry_id;
  select public.claim_entry_processing(preview_entry_id, owner_id)
  into claimed_attempt;
  if claimed_attempt <> 2 then
    raise exception 'preview fixture did not replace its stale attempt';
  end if;
  select analysis_preview into stored_preview
  from public.entries
  where id = preview_entry_id;
  if stored_preview is not null then
    raise exception 'replacement claim retained a stale streamed preview';
  end if;

  update public.entries
  set analysis_preview = 'Still estimating this meal.',
      processing_attempts = 3,
      lease_expires_at = now() - interval '1 second'
  where id = preview_entry_id;
  select public.fail_exhausted_entry_processing(
    preview_entry_id,
    owner_id,
    3::smallint
  ) into repaired;
  if not repaired then
    raise exception 'expired final preview attempt was not terminalized';
  end if;
  select analysis_preview into stored_preview
  from public.entries
  where id = preview_entry_id;
  if stored_preview is not null then
    raise exception 'terminalized attempt retained a streamed preview';
  end if;

  rejected := false;
  begin
    update public.entries
    set analysis_preview = 'Stale terminal preview'
    where id = preview_entry_id;
  exception when check_violation then
    rejected := true;
  end;
  if not rejected then
    raise exception 'terminal state accepted a streamed preview';
  end if;

  delete from public.entries where id = preview_entry_id;
end;
$$;

do $$
begin
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
    raise exception 'postgres public default ACLs still grant a Data API role';
  end if;

  if not has_table_privilege(
    'authenticated',
    'public.daily_totals',
    'select'
  ) or not has_table_privilege(
    'service_role',
    'public.daily_totals',
    'select'
  ) then
    raise exception 'daily_totals is missing an explicit SELECT grant';
  end if;
  if has_table_privilege('anon', 'public.daily_totals', 'select')
    or has_table_privilege('authenticated', 'public.daily_totals', 'insert')
    or has_table_privilege('authenticated', 'public.daily_totals', 'update')
    or has_table_privilege('authenticated', 'public.daily_totals', 'delete')
    or has_table_privilege('service_role', 'public.daily_totals', 'insert')
    or has_table_privilege('service_role', 'public.daily_totals', 'update')
    or has_table_privilege('service_role', 'public.daily_totals', 'delete') then
    raise exception 'daily_totals has a non-SELECT Data API privilege';
  end if;
end;
$$;

-- The Storage cleanup outbox is reachable only through narrowly scoped,
-- service-role RPCs. The table and its private helpers stay invisible even to
-- the service role used by Edge Functions.
do $$
declare
  function_signatures text[] := array[
    'public.enqueue_storage_cleanup(text, text, text, timestamptz)',
    'public.claim_storage_cleanup(integer, integer)',
    'public.complete_storage_cleanup(uuid, uuid)',
    'public.fail_storage_cleanup(uuid, uuid, text)',
    'public.publish_entry_upload(uuid, uuid, uuid, date, text, text, text, text)',
    'public.fail_entry_upload(uuid, uuid, uuid, text)',
    'public.fail_stale_incomplete_entry(uuid, uuid)',
    'public.detach_entry_audio(uuid, uuid, smallint, text)',
    'public.delete_entry_with_cleanup(uuid, uuid)',
    'public.prepare_entry_resume(uuid, uuid)'
  ];
  function_signature text;
  partial_index_count integer;
begin
  if has_schema_privilege('service_role', 'private', 'usage') then
    raise exception 'service role unexpectedly has private schema USAGE';
  end if;

  if has_table_privilege(
    'service_role',
    'private.storage_cleanup_jobs',
    'select'
  ) or has_table_privilege(
    'authenticated',
    'private.storage_cleanup_jobs',
    'select'
  ) or has_table_privilege(
    'anon',
    'private.storage_cleanup_jobs',
    'select'
  ) then
    raise exception 'Storage cleanup table leaked a direct table grant';
  end if;

  foreach function_signature in array function_signatures loop
    if has_function_privilege(
      'authenticated',
      function_signature,
      'execute'
    ) or has_function_privilege(
      'anon',
      function_signature,
      'execute'
    ) then
      raise exception 'cleanup RPC leaked EXECUTE: %', function_signature;
    end if;
    if not has_function_privilege(
      'service_role',
      function_signature,
      'execute'
    ) then
      raise exception 'service role cannot execute %', function_signature;
    end if;
  end loop;

  if has_function_privilege(
    'service_role',
    'private.enqueue_storage_cleanup_job(text, text, text, timestamptz)',
    'execute'
  ) or has_function_privilege(
    'service_role',
    'private.enqueue_entry_upload_prefixes(uuid, uuid, uuid, timestamptz)',
    'execute'
  ) then
    raise exception 'service role can bypass a public cleanup RPC';
  end if;

  if exists (
    select 1
    from pg_constraint
    where conrelid = 'private.storage_cleanup_jobs'::regclass
      and contype = 'f'
  ) then
    raise exception 'cleanup jobs must survive entry deletion without an FK';
  end if;

  select count(*)
  into partial_index_count
  from pg_index as index_meta
  join pg_class as index_relation
    on index_relation.oid = index_meta.indexrelid
  join pg_namespace as index_schema
    on index_schema.oid = index_relation.relnamespace
  where index_schema.nspname = 'private'
    and index_relation.relname in (
      'storage_cleanup_jobs_due_idx',
      'storage_cleanup_jobs_expired_lease_idx'
    )
    and index_meta.indpred is not null;
  if partial_index_count <> 2 then
    raise exception 'cleanup queue is missing its partial due/lease indexes';
  end if;
end;
$$;

-- Exercise cleanup leasing, fencing, retry backoff, upload token rotation,
-- transactional publication/failure, audio detach, and durable entry deletion.
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-8000-000000000001';
  other_id constant uuid := '00000000-0000-4000-8000-000000000002';
  upload_entry_id constant uuid := '30000000-0000-4000-8000-000000000001';
  upload_client_id constant uuid := '30100000-0000-4000-8000-000000000001';
  old_upload_token constant uuid := '31000000-0000-4000-8000-000000000001';
  published_token constant uuid := '31100000-0000-4000-8000-000000000001';
  fail_entry_id constant uuid := '30000000-0000-4000-8000-000000000002';
  fail_client_id constant uuid := '30100000-0000-4000-8000-000000000002';
  fail_upload_token constant uuid := '31000000-0000-4000-8000-000000000002';
  stale_entry_id constant uuid := '30000000-0000-4000-8000-000000000003';
  stale_client_id constant uuid := '30100000-0000-4000-8000-000000000003';
  stale_upload_token constant uuid := '31000000-0000-4000-8000-000000000003';
  detach_entry_id constant uuid := '30000000-0000-4000-8000-000000000004';
  detach_client_id constant uuid := '30100000-0000-4000-8000-000000000004';
  delete_entry_id constant uuid := '30000000-0000-4000-8000-000000000005';
  delete_client_id constant uuid := '30100000-0000-4000-8000-000000000005';
  busy_entry_id constant uuid := '30000000-0000-4000-8000-000000000006';
  busy_client_id constant uuid := '30100000-0000-4000-8000-000000000006';
  deleting_entry_id constant uuid := '30000000-0000-4000-8000-000000000007';
  deleting_client_id constant uuid := '30100000-0000-4000-8000-000000000007';
  queue_job_id uuid;
  claimed_job_id uuid;
  first_lease_token uuid;
  second_lease_token uuid;
  replacement_upload_token uuid;
  claimed_attempts integer;
  claimed_count integer;
  stored_count integer;
  stored_status text;
  stored_error text;
  stored_image_path text;
  stored_audio_path text;
  stored_upload_token uuid;
  stored_lease timestamptz;
  stored_not_before timestamptz;
  result boolean;
  old_image_path text;
  old_audio_path text;
  new_image_path text;
  new_audio_path text;
  stale_prefix text;
begin
  truncate table private.storage_cleanup_jobs;

  -- A claimed queue job is invisible until its database-time lease expires;
  -- failure retains it with backoff, and a replacement token fences completion.
  select public.enqueue_storage_cleanup(
    'entry-images',
    'object',
    owner_id::text || '/queue-fixture/photo.jpg',
    now() - interval '1 second'
  ) into queue_job_id;

  select cleanup.id, cleanup.lease_token, cleanup.attempts
  into claimed_job_id, first_lease_token, claimed_attempts
  from public.claim_storage_cleanup(1, 30) as cleanup;
  if claimed_job_id is distinct from queue_job_id
    or first_lease_token is null
    or claimed_attempts <> 1 then
    raise exception 'cleanup queue did not return its first fenced claim';
  end if;
  select lease_expires_at
  into stored_lease
  from private.storage_cleanup_jobs
  where id = queue_job_id;
  if stored_lease is distinct from now() + interval '30 seconds' then
    raise exception 'cleanup claim did not use database time: %', stored_lease;
  end if;

  select count(*)
  into claimed_count
  from public.claim_storage_cleanup(1, 30);
  if claimed_count <> 0 then
    raise exception 'an active cleanup lease was claimed twice';
  end if;

  select public.complete_storage_cleanup(queue_job_id, gen_random_uuid())
  into result;
  if result then
    raise exception 'wrong cleanup token completed a live job';
  end if;
  select public.fail_storage_cleanup(
    queue_job_id,
    first_lease_token,
    repeat('x', 700)
  ) into result;
  if not result then
    raise exception 'cleanup failure did not release its current lease';
  end if;
  select not_before, lease_token, length(last_error), attempts
  into stored_not_before, stored_upload_token, stored_count, claimed_attempts
  from private.storage_cleanup_jobs
  where id = queue_job_id;
  if stored_not_before is distinct from now() + interval '15 seconds'
    or stored_upload_token is not null
    or stored_count <> 500
    or claimed_attempts <> 1 then
    raise exception 'cleanup failure did not retain/back off the job';
  end if;

  update private.storage_cleanup_jobs
  set not_before = now() - interval '1 second'
  where id = queue_job_id;
  select cleanup.id, cleanup.lease_token, cleanup.attempts
  into claimed_job_id, second_lease_token, claimed_attempts
  from public.claim_storage_cleanup(1, 30) as cleanup;
  if claimed_job_id is distinct from queue_job_id
    or second_lease_token is null
    or second_lease_token = first_lease_token
    or claimed_attempts <> 2 then
    raise exception 'cleanup retry did not rotate its random fence';
  end if;
  select public.complete_storage_cleanup(queue_job_id, first_lease_token)
  into result;
  if result then
    raise exception 'stale cleanup worker completed a replacement claim';
  end if;
  select public.complete_storage_cleanup(queue_job_id, second_lease_token)
  into result;
  if not result or exists (
    select 1 from private.storage_cleanup_jobs where id = queue_job_id
  ) then
    raise exception 'current cleanup worker did not remove its completed job';
  end if;

  -- Rotating an expired upload token queues both old staging prefixes with a
  -- five-minute grace, and publication queues changed durable objects exactly.
  old_image_path := owner_id::text || '/' || upload_entry_id::text || '/'
    || published_token::text || '/old-photo.jpg';
  old_audio_path := owner_id::text || '/' || upload_entry_id::text || '/'
    || published_token::text || '/old-voice.m4a';
  insert into public.entries (
    id,
    user_id,
    client_request_id,
    local_day,
    status,
    intended_image,
    intended_audio,
    image_path,
    audio_path,
    transcript,
    transcription_model,
    upload_token,
    lease_expires_at
  ) values (
    upload_entry_id,
    owner_id,
    upload_client_id,
    '2026-07-20',
    'queued',
    true,
    true,
    old_image_path,
    old_audio_path,
    'old recording transcript',
    'old-transcriber',
    old_upload_token,
    now() - interval '1 second'
  );

  select public.claim_entry_upload(upload_entry_id, owner_id)
  into replacement_upload_token;
  if replacement_upload_token is null
    or replacement_upload_token = old_upload_token then
    raise exception 'expired upload token was not rotated';
  end if;
  select upload_token, lease_expires_at
  into stored_upload_token, stored_lease
  from public.entries
  where id = upload_entry_id;
  if stored_upload_token is distinct from replacement_upload_token
    or stored_lease is distinct from now() + interval '60 seconds' then
    raise exception 'upload claim returned a token/lease not stored by DB time';
  end if;
  stale_prefix := owner_id::text || '/' || upload_entry_id::text || '/'
    || old_upload_token::text || '/';
  select count(*), min(not_before)
  into stored_count, stored_not_before
  from private.storage_cleanup_jobs
  where mode = 'prefix'
    and object_path = stale_prefix;
  if stored_count <> 2
    or stored_not_before is distinct from now() + interval '5 minutes' then
    raise exception 'token rotation did not grace both stale prefixes';
  end if;

  select public.publish_entry_upload(
    upload_entry_id,
    owner_id,
    old_upload_token,
    '2026-07-21',
    'America/New_York',
    'replacement',
    old_image_path,
    old_audio_path
  ) into result;
  if result then
    raise exception 'stale upload token published over its replacement';
  end if;

  new_image_path := owner_id::text || '/' || upload_entry_id::text || '/'
    || replacement_upload_token::text || '/photo.jpg';
  new_audio_path := owner_id::text || '/' || upload_entry_id::text || '/'
    || replacement_upload_token::text || '/voice.m4a';
  begin
    -- Model an original attachment that has neither a published object nor a
    -- durable transcript. The subtransaction restores the fixture's old
    -- transcript after the expected publication error.
    update public.entries
    set transcript = null
    where id = upload_entry_id;
    perform public.publish_entry_upload(
      upload_entry_id,
      owner_id,
      replacement_upload_token,
      '2026-07-21',
      'America/New_York',
      'replacement',
      new_image_path,
      null
    );
    raise exception 'publication accepted a missing intended recording';
  exception
    when sqlstate '22023' then null;
  end;
  select public.publish_entry_upload(
    upload_entry_id,
    owner_id,
    replacement_upload_token,
    '2026-07-21',
    'America/New_York',
    'replacement',
    new_image_path,
    new_audio_path
  ) into result;
  if not result then
    raise exception 'current upload token did not publish';
  end if;
  select status, image_path, audio_path, upload_token, lease_expires_at
  into stored_status, stored_image_path, stored_audio_path,
       stored_upload_token, stored_lease
  from public.entries
  where id = upload_entry_id;
  if stored_status <> 'queued'
    or stored_image_path is distinct from new_image_path
    or stored_audio_path is distinct from new_audio_path
    or stored_upload_token is not null
    or stored_lease is not null then
    raise exception 'upload publication did not atomically expose its paths';
  end if;
  if exists (
    select 1
    from public.entries
    where id = upload_entry_id
      and (transcript is not null or transcription_model is not null)
  ) then
    raise exception 'replacement audio retained the prior recording transcript';
  end if;
  select count(*)
  into stored_count
  from private.storage_cleanup_jobs
  where mode = 'object'
    and (
      (bucket = 'entry-images' and object_path = old_image_path)
      or (bucket = 'entry-audio' and object_path = old_audio_path)
    )
    and not_before <= now();
  if stored_count <> 2 then
    raise exception 'publication did not enqueue both replaced exact objects';
  end if;
  if exists (
    select 1
    from private.storage_cleanup_jobs
    where mode = 'prefix'
      and object_path = owner_id::text || '/' || upload_entry_id::text || '/'
        || replacement_upload_token::text || '/'
  ) then
    raise exception 'publication queued its still-live upload prefix';
  end if;

  -- A synchronous upload failure is token-fenced, truncates its stored error,
  -- and schedules both staging buckets without waiting for lease expiry.
  insert into public.entries (
    id,
    user_id,
    client_request_id,
    local_day,
    status,
    upload_token,
    lease_expires_at
  ) values (
    fail_entry_id,
    owner_id,
    fail_client_id,
    '2026-07-20',
    'queued',
    fail_upload_token,
    now() + interval '1 minute'
  );
  select public.fail_entry_upload(
    fail_entry_id,
    other_id,
    fail_upload_token,
    'wrong owner'
  ) into result;
  if result then
    raise exception 'upload failure crossed the entry owner boundary';
  end if;
  select public.fail_entry_upload(
    fail_entry_id,
    owner_id,
    fail_upload_token,
    repeat('y', 700)
  ) into result;
  if not result then
    raise exception 'current upload token could not terminalize its failure';
  end if;
  select status, error_message, upload_token, lease_expires_at
  into stored_status, stored_error, stored_upload_token, stored_lease
  from public.entries
  where id = fail_entry_id;
  if stored_status <> 'failed'
    or length(stored_error) <> 500
    or stored_upload_token is not null
    or stored_lease is not null then
    raise exception 'upload failure did not atomically clear its token';
  end if;
  stale_prefix := owner_id::text || '/' || fail_entry_id::text || '/'
    || fail_upload_token::text || '/';
  select count(*), min(not_before)
  into stored_count, stored_not_before
  from private.storage_cleanup_jobs
  where mode = 'prefix'
    and object_path = stale_prefix;
  if stored_count <> 2
    or stored_not_before is distinct from now() + interval '5 minutes' then
    raise exception 'upload failure did not grace both staging prefixes';
  end if;

  -- The stale repair is DB-expiry gated and performs the same durable cleanup.
  insert into public.entries (
    id,
    user_id,
    client_request_id,
    local_day,
    status,
    upload_token,
    lease_expires_at
  ) values (
    stale_entry_id,
    owner_id,
    stale_client_id,
    '2026-07-20',
    'queued',
    stale_upload_token,
    now() + interval '1 minute'
  );
  select public.fail_stale_entry_upload(
    stale_entry_id,
    owner_id,
    stale_upload_token
  ) into result;
  if result then
    raise exception 'stale repair terminated a live upload by Edge time';
  end if;
  update public.entries
  set lease_expires_at = now() - interval '1 second'
  where id = stale_entry_id;
  select public.fail_stale_entry_upload(
    stale_entry_id,
    owner_id,
    stale_upload_token
  ) into result;
  if not result then
    raise exception 'stale repair did not terminalize an expired upload';
  end if;
  stale_prefix := owner_id::text || '/' || stale_entry_id::text || '/'
    || stale_upload_token::text || '/';
  select count(*), min(not_before)
  into stored_count, stored_not_before
  from private.storage_cleanup_jobs
  where mode = 'prefix'
    and object_path = stale_prefix;
  if stored_count <> 2
    or stored_not_before is distinct from now() + interval '5 minutes' then
    raise exception 'stale repair did not grace both staging prefixes';
  end if;

  -- Processing-attempt fencing protects a replacement worker while the exact
  -- audio detach and queue insert commit together.
  old_audio_path := owner_id::text || '/' || detach_entry_id::text
    || '/voice.m4a';
  insert into public.entries (
    id,
    user_id,
    client_request_id,
    local_day,
    status,
    transcript,
    intended_audio,
    audio_path,
    processing_attempts,
    lease_expires_at
  ) values (
    detach_entry_id,
    owner_id,
    detach_client_id,
    '2026-07-20',
    'analyzing',
    null,
    true,
    old_audio_path,
    2,
    now() + interval '1 minute'
  );
  select public.detach_entry_audio(
    detach_entry_id,
    owner_id,
    1::smallint,
    old_audio_path
  ) into result;
  if result then
    raise exception 'stale processing attempt detached replacement audio';
  end if;
  select public.detach_entry_audio(
    detach_entry_id,
    owner_id,
    2::smallint,
    old_audio_path
  ) into result;
  if result then
    raise exception 'audio without a durable transcript was detached';
  end if;
  if not exists (
    select 1
    from public.entries
    where id = detach_entry_id
      and audio_path = old_audio_path
  ) or exists (
    select 1
    from private.storage_cleanup_jobs
    where bucket = 'entry-audio'
      and mode = 'object'
      and object_path = old_audio_path
  ) then
    raise exception 'rejected audio detach changed durable state';
  end if;
  update public.entries
  set transcript = 'durable transcript'
  where id = detach_entry_id;
  select public.detach_entry_audio(
    detach_entry_id,
    owner_id,
    2::smallint,
    old_audio_path
  ) into result;
  if not result then
    raise exception 'current processing attempt could not detach audio';
  end if;
  select audio_path
  into stored_audio_path
  from public.entries
  where id = detach_entry_id;
  if stored_audio_path is not null or not exists (
    select 1
    from private.storage_cleanup_jobs
    where bucket = 'entry-audio'
      and mode = 'object'
      and object_path = old_audio_path
  ) then
    raise exception 'audio detach did not atomically enqueue its exact object';
  end if;

  -- Terminal entry deletion leaves no row but retains exact cleanup jobs. A
  -- processing row and another owner's request are both rejected.
  old_image_path := owner_id::text || '/' || delete_entry_id::text
    || '/photo.jpg';
  old_audio_path := owner_id::text || '/' || delete_entry_id::text
    || '/voice.m4a';
  insert into public.entries (
    id,
    user_id,
    client_request_id,
    local_day,
    status,
    intended_image,
    intended_audio,
    image_path,
    audio_path
  ) values (
    delete_entry_id,
    owner_id,
    delete_client_id,
    '2026-07-20',
    'complete',
    true,
    true,
    old_image_path,
    old_audio_path
  );
  select public.delete_entry_with_cleanup(delete_entry_id, other_id)
  into result;
  if result then
    raise exception 'entry deletion crossed the owner boundary';
  end if;
  select public.delete_entry_with_cleanup(delete_entry_id, owner_id)
  into result;
  if not result or exists (
    select 1 from public.entries where id = delete_entry_id
  ) then
    raise exception 'terminal entry was not deleted';
  end if;
  select count(*)
  into stored_count
  from private.storage_cleanup_jobs
  where mode = 'object'
    and (
      (bucket = 'entry-images' and object_path = old_image_path)
      or (bucket = 'entry-audio' and object_path = old_audio_path)
    );
  if stored_count <> 2 then
    raise exception 'entry deletion did not preserve both cleanup jobs';
  end if;

  insert into public.entries (
    id,
    user_id,
    client_request_id,
    local_day,
    status,
    processing_attempts,
    lease_expires_at
  ) values (
    busy_entry_id,
    owner_id,
    busy_client_id,
    '2026-07-20',
    'analyzing',
    1,
    now() + interval '1 minute'
  );
  select public.delete_entry_with_cleanup(busy_entry_id, owner_id)
  into result;
  if result or not exists (
    select 1 from public.entries where id = busy_entry_id
  ) then
    raise exception 'nonterminal entry was deleted';
  end if;

  insert into public.entries (
    id,
    user_id,
    client_request_id,
    local_day,
    status
  ) values (
    deleting_entry_id,
    owner_id,
    deleting_client_id,
    '2026-07-20',
    'deleting'
  );
  select public.delete_entry_with_cleanup(deleting_entry_id, owner_id)
  into result;
  if not result or exists (
    select 1 from public.entries where id = deleting_entry_id
  ) then
    raise exception 'deleting-state retry was not idempotently finished';
  end if;

  -- Keep the fixture's later RLS cardinality assertions focused on their
  -- original rows; cleanup jobs intentionally remain after these row deletes.
  delete from public.entries
  where id in (
    upload_entry_id,
    fail_entry_id,
    stale_entry_id,
    detach_entry_id,
    busy_entry_id
  );
end;
$$;

\ir account_features.sql

-- Repair RPCs deliberately use database time plus exact lease tokens. These
-- assertions prove that a stale request cannot terminate a newer upload or a
-- still-live final processing attempt.
do $$
declare
  upload_entry_id uuid;
  initial_upload_token uuid;
  replacement_upload_token uuid;
  repair_succeeded boolean;
  stored_upload_token uuid;
  stored_status text;
  stored_status_message text;
  stored_error_message text;
  stored_lease timestamptz;
  exhausted_entry_id uuid;
  stored_attempts smallint;
begin
  insert into public.entries (
    user_id,
    client_request_id,
    local_day,
    status
  )
  values (
    '00000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000004',
    '2026-07-20',
    'queued'
  )
  returning id into upload_entry_id;

  select public.claim_entry_upload(
    upload_entry_id,
    '00000000-0000-4000-8000-000000000001'
  ) into initial_upload_token;
  if initial_upload_token is null then
    raise exception 'repair fixture did not acquire its initial upload token';
  end if;

  update public.entries
  set lease_expires_at = now() - interval '1 second'
  where id = upload_entry_id;

  select public.claim_entry_upload(
    upload_entry_id,
    '00000000-0000-4000-8000-000000000001'
  ) into replacement_upload_token;
  if replacement_upload_token is null
    or replacement_upload_token = initial_upload_token then
    raise exception 'repair fixture did not fence the expired upload';
  end if;

  select public.fail_stale_entry_upload(
    upload_entry_id,
    '00000000-0000-4000-8000-000000000001',
    replacement_upload_token
  ) into repair_succeeded;
  if repair_succeeded then
    raise exception 'database time repair terminated a live replacement upload';
  end if;

  update public.entries
  set lease_expires_at = now() - interval '1 second'
  where id = upload_entry_id;

  select public.fail_stale_entry_upload(
    upload_entry_id,
    '00000000-0000-4000-8000-000000000001',
    initial_upload_token
  ) into repair_succeeded;
  if repair_succeeded then
    raise exception 'stale upload token terminated its replacement worker';
  end if;

  select public.fail_stale_entry_upload(
    upload_entry_id,
    '00000000-0000-4000-8000-000000000002',
    replacement_upload_token
  ) into repair_succeeded;
  if repair_succeeded then
    raise exception 'upload repair crossed the entry owner boundary';
  end if;

  select upload_token, status, lease_expires_at
  into stored_upload_token, stored_status, stored_lease
  from public.entries
  where id = upload_entry_id;
  if stored_upload_token is distinct from replacement_upload_token
    or stored_status <> 'queued'
    or stored_lease is null then
    raise exception 'failed upload repairs mutated the replacement lease';
  end if;

  select public.fail_stale_entry_upload(
    upload_entry_id,
    '00000000-0000-4000-8000-000000000001',
    replacement_upload_token
  ) into repair_succeeded;
  if not repair_succeeded then
    raise exception 'expired upload was not repaired';
  end if;

  select upload_token, status, status_message, error_message, lease_expires_at
  into stored_upload_token, stored_status, stored_status_message,
       stored_error_message, stored_lease
  from public.entries
  where id = upload_entry_id;
  if stored_upload_token is not null
    or stored_status <> 'failed'
    or stored_status_message <> 'Upload interrupted'
    or stored_error_message is null
    or stored_lease is not null then
    raise exception 'expired upload repair did not produce its terminal state';
  end if;

  select public.fail_stale_entry_upload(
    upload_entry_id,
    '00000000-0000-4000-8000-000000000001',
    replacement_upload_token
  ) into repair_succeeded;
  if repair_succeeded then
    raise exception 'upload repair was not idempotent after terminalization';
  end if;

  insert into public.entries (
    user_id,
    client_request_id,
    local_day,
    status,
    status_message,
    processing_attempts,
    lease_expires_at
  )
  values (
    '00000000-0000-4000-8000-000000000001',
    '10000000-0000-4000-8000-000000000005',
    '2026-07-20',
    'analyzing',
    'Estimating your meal',
    3,
    now() + interval '10 minutes'
  )
  returning id into exhausted_entry_id;

  select public.fail_exhausted_entry_processing(
    exhausted_entry_id,
    '00000000-0000-4000-8000-000000000001',
    3::smallint
  ) into repair_succeeded;
  if repair_succeeded then
    raise exception 'database time repair terminated a live final processing attempt';
  end if;

  update public.entries
  set lease_expires_at = now() - interval '1 second'
  where id = exhausted_entry_id;

  select public.fail_exhausted_entry_processing(
    exhausted_entry_id,
    '00000000-0000-4000-8000-000000000001',
    2::smallint
  ) into repair_succeeded;
  if repair_succeeded then
    raise exception 'stale processing attempt terminated the final worker';
  end if;

  select public.fail_exhausted_entry_processing(
    exhausted_entry_id,
    '00000000-0000-4000-8000-000000000002',
    3::smallint
  ) into repair_succeeded;
  if repair_succeeded then
    raise exception 'processing repair crossed the entry owner boundary';
  end if;

  select status, processing_attempts, lease_expires_at
  into stored_status, stored_attempts, stored_lease
  from public.entries
  where id = exhausted_entry_id;
  if stored_status <> 'analyzing'
    or stored_attempts <> 3
    or stored_lease is null then
    raise exception 'failed processing repairs mutated the final attempt';
  end if;

  select public.fail_exhausted_entry_processing(
    exhausted_entry_id,
    '00000000-0000-4000-8000-000000000001',
    3::smallint
  ) into repair_succeeded;
  if not repair_succeeded then
    raise exception 'expired final processing attempt was not repaired';
  end if;

  select status, status_message, error_message, processing_attempts,
         lease_expires_at
  into stored_status, stored_status_message, stored_error_message,
       stored_attempts, stored_lease
  from public.entries
  where id = exhausted_entry_id;
  if stored_status <> 'failed'
    or stored_status_message <> 'Retry limit reached'
    or stored_error_message is null
    or stored_attempts <> 3
    or stored_lease is not null then
    raise exception 'exhausted processing repair did not produce its terminal state';
  end if;

  select public.fail_exhausted_entry_processing(
    exhausted_entry_id,
    '00000000-0000-4000-8000-000000000001',
    3::smallint
  ) into repair_succeeded;
  if repair_succeeded then
    raise exception 'processing repair was not idempotent after terminalization';
  end if;
end;
$$;

do $$
begin
  if exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'meal_audio_select_own'
  ) then
    raise exception 'authenticated users unexpectedly retain raw-audio policy';
  end if;
end;
$$;

insert into storage.objects (bucket_id, name)
values
  (
    'entry-images',
    '00000000-0000-4000-8000-000000000001/current/photo.jpg'
  ),
  (
    'entry-images',
    'u_00000000-0000-4000-8000-000000000001/e_legacy/photo.jpg'
  ),
  (
    'entry-images',
    '00000000-0000-4000-8000-000000000002/current/photo.jpg'
  ),
  (
    'entry-audio',
    '00000000-0000-4000-8000-000000000001/current/voice.m4a'
  ),
  (
    'entry-audio',
    'u_00000000-0000-4000-8000-000000000001/e_legacy/voice.m4a'
  );

set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', false);

do $$
declare
  visible_entries integer;
  visible_calories numeric;
  visible_images integer;
  visible_audio integer;
begin
  select count(*) into visible_entries from public.entries;
  if visible_entries <> 4 then
    raise exception 'RLS exposed % entries instead of 4', visible_entries;
  end if;

  select calories_kcal into visible_calories
  from public.daily_totals
  where local_day = '2026-07-20';
  if visible_calories <> 390 then
    raise exception 'daily_totals leaked or miscounted data: %', visible_calories;
  end if;

  select count(*)
  into visible_images
  from storage.objects
  where bucket_id = 'entry-images';
  if visible_images <> 2 then
    raise exception 'image RLS did not expose current + legacy owner paths: %',
      visible_images;
  end if;

  select count(*)
  into visible_audio
  from storage.objects
  where bucket_id = 'entry-audio';
  if visible_audio <> 0 then
    raise exception 'raw audio was exposed to authenticated users: %',
      visible_audio;
  end if;
end;
$$;

reset role;

do $$
declare
  queued_entry_id uuid;
  upload_token uuid;
  replacement_upload_token uuid;
  claimed_while_uploading smallint;
  claimed_after_upload smallint;
  replacement_processing_attempt smallint;
  attempts smallint;
  stale_worker_rows integer;
begin
  select id into queued_entry_id
  from public.entries
  where client_request_id = '10000000-0000-4000-8000-000000000003';

  select public.claim_entry_upload(
    queued_entry_id,
    '00000000-0000-4000-8000-000000000001'
  ) into upload_token;
  if upload_token is null then
    raise exception 'queued entry did not acquire an upload token';
  end if;

  update public.entries
  set lease_expires_at = now() - interval '1 second'
  where id = queued_entry_id;

  select public.claim_entry_upload(
    queued_entry_id,
    '00000000-0000-4000-8000-000000000001'
  ) into replacement_upload_token;
  if replacement_upload_token is null or replacement_upload_token = upload_token then
    raise exception 'expired upload was not fenced with a new token';
  end if;

  select public.claim_entry_processing(
    queued_entry_id,
    '00000000-0000-4000-8000-000000000001'
  ) into claimed_while_uploading;
  if claimed_while_uploading is not null then
    raise exception 'processing raced an active upload lease';
  end if;

  update public.entries
  set lease_expires_at = null,
      upload_token = null,
      status_message = 'Queued'
  where client_request_id = '10000000-0000-4000-8000-000000000003';

  select public.claim_entry_processing(
    queued_entry_id,
    '00000000-0000-4000-8000-000000000001'
  ) into claimed_after_upload;
  if claimed_after_upload <> 1 then
    raise exception 'published queued entry was not claimed';
  end if;

  update public.entries
  set lease_expires_at = now() - interval '1 second'
  where id = queued_entry_id;

  select public.claim_entry_processing(
    queued_entry_id,
    '00000000-0000-4000-8000-000000000001'
  ) into replacement_processing_attempt;
  if replacement_processing_attempt <> 2 then
    raise exception 'stale processing lease was not replaced: %', replacement_processing_attempt;
  end if;

  update public.entries
  set status = 'failed', lease_expires_at = null
  where id = queued_entry_id
    and processing_attempts = 1
    and status in ('transcribing', 'analyzing');
  get diagnostics stale_worker_rows = row_count;
  if stale_worker_rows <> 0 then
    raise exception 'stale processing attempt changed the replacement worker';
  end if;

  select processing_attempts into attempts
  from public.entries
  where client_request_id = '10000000-0000-4000-8000-000000000003';
  if attempts <> 2 then
    raise exception 'processing attempt count was %, expected 2', attempts;
  end if;
end;
$$;

-- A resume request commits failed -> queued before dispatch. Every competing
-- or ineligible state is left byte-for-byte under its existing fence.
do $$
declare
  owner_id constant uuid := '00000000-0000-4000-8000-000000000001';
  other_id constant uuid := '00000000-0000-4000-8000-000000000002';
  eligible_id constant uuid := '40000000-0000-4000-8000-000000000001';
  live_lease_id constant uuid := '40000000-0000-4000-8000-000000000002';
  exhausted_id constant uuid := '40000000-0000-4000-8000-000000000003';
  upload_owned_id constant uuid := '40000000-0000-4000-8000-000000000004';
  inflight_id constant uuid := '40000000-0000-4000-8000-000000000005';
  missing_media_id constant uuid := '40000000-0000-4000-8000-000000000006';
  fixture_upload_token constant uuid := '41000000-0000-4000-8000-000000000001';
  resumed boolean;
  stored_status text;
  stored_status_message text;
  stored_error text;
  stored_attempts smallint;
  stored_lease timestamptz;
  stored_upload_token uuid;
  processing_claim smallint;
begin
  insert into public.entries (
    id,
    user_id,
    client_request_id,
    local_day,
    status,
    status_message,
    error_message,
    processing_attempts,
    lease_expires_at
  ) values
    (
      eligible_id,
      owner_id,
      '40100000-0000-4000-8000-000000000001',
      '2026-07-20',
      'failed',
      'Could not finish this meal',
      'retryable error',
      1,
      now() - interval '1 second'
    ),
    (
      live_lease_id,
      owner_id,
      '40100000-0000-4000-8000-000000000002',
      '2026-07-20',
      'failed',
      'Could not finish this meal',
      'live lease error',
      1,
      now() + interval '1 minute'
    ),
    (
      exhausted_id,
      owner_id,
      '40100000-0000-4000-8000-000000000003',
      '2026-07-20',
      'failed',
      'Retry limit reached',
      'exhausted error',
      3,
      null
    ),
    (
      upload_owned_id,
      owner_id,
      '40100000-0000-4000-8000-000000000004',
      '2026-07-20',
      'failed',
      'Upload interrupted',
      'upload error',
      1,
      now() - interval '1 second'
    ),
    (
      missing_media_id,
      owner_id,
      '40100000-0000-4000-8000-000000000006',
      '2026-07-20',
      'queued',
      'Uploading',
      null,
      0,
      null
    ),
    (
      inflight_id,
      owner_id,
      '40100000-0000-4000-8000-000000000005',
      '2026-07-20',
      'analyzing',
      'Estimating your meal',
      null,
      1,
      now() + interval '1 minute'
    );
  update public.entries
  set upload_token = fixture_upload_token
  where id = upload_owned_id;
  update public.entries
  set intended_image = true,
      intended_audio = true,
      transcript = '   '
  where id = missing_media_id;

  select public.prepare_entry_resume(eligible_id, other_id) into resumed;
  if resumed then
    raise exception 'resume crossed the entry owner boundary';
  end if;
  select status, status_message, error_message, processing_attempts,
         lease_expires_at
  into stored_status, stored_status_message, stored_error, stored_attempts,
       stored_lease
  from public.entries
  where id = eligible_id;
  if stored_status <> 'failed'
    or stored_status_message <> 'Could not finish this meal'
    or stored_error <> 'retryable error'
    or stored_attempts <> 1
    or stored_lease is null then
    raise exception 'wrong-owner resume mutated the retryable row';
  end if;

  select public.prepare_entry_resume(eligible_id, owner_id) into resumed;
  if not resumed then
    raise exception 'eligible expired failed row was not prepared for resume';
  end if;
  select status, status_message, error_message, processing_attempts,
         lease_expires_at
  into stored_status, stored_status_message, stored_error, stored_attempts,
       stored_lease
  from public.entries
  where id = eligible_id;
  if stored_status <> 'queued'
    or stored_status_message <> 'Queued'
    or stored_error is not null
    or stored_attempts <> 1
    or stored_lease is not null then
    raise exception 'resume did not atomically prepare the failed row';
  end if;
  select public.prepare_entry_resume(eligible_id, owner_id) into resumed;
  if resumed then
    raise exception 'already queued row was prepared twice';
  end if;

  select public.prepare_entry_resume(live_lease_id, owner_id) into resumed;
  if resumed then
    raise exception 'resume replaced a live database-time lease';
  end if;
  select status, error_message, processing_attempts, lease_expires_at
  into stored_status, stored_error, stored_attempts, stored_lease
  from public.entries
  where id = live_lease_id;
  if stored_status <> 'failed'
    or stored_error <> 'live lease error'
    or stored_attempts <> 1
    or stored_lease <= now() then
    raise exception 'rejected live-lease resume mutated the row';
  end if;

  select public.prepare_entry_resume(exhausted_id, owner_id) into resumed;
  if resumed then
    raise exception 'resume reset an exhausted retry budget';
  end if;
  select status, error_message, processing_attempts
  into stored_status, stored_error, stored_attempts
  from public.entries
  where id = exhausted_id;
  if stored_status <> 'failed'
    or stored_error <> 'exhausted error'
    or stored_attempts <> 3 then
    raise exception 'rejected exhausted resume mutated the row';
  end if;

  select public.prepare_entry_resume(upload_owned_id, owner_id) into resumed;
  if resumed then
    raise exception 'resume replaced an upload-token fence';
  end if;
  select status, error_message, processing_attempts, upload_token,
         lease_expires_at
  into stored_status, stored_error, stored_attempts, stored_upload_token,
       stored_lease
  from public.entries
  where id = upload_owned_id;
  if stored_status <> 'failed'
    or stored_error <> 'upload error'
    or stored_attempts <> 1
    or stored_upload_token is distinct from fixture_upload_token
    or stored_lease is null then
    raise exception 'rejected upload-owned resume mutated the row';
  end if;

  select public.fail_stale_incomplete_entry(missing_media_id, owner_id)
  into resumed;
  if resumed then
    raise exception 'fresh incomplete capture was terminalized too early';
  end if;
  update public.entries
  set created_at = now() - interval '121 seconds'
  where id = missing_media_id;
  select public.fail_stale_incomplete_entry(missing_media_id, other_id)
  into resumed;
  if resumed then
    raise exception 'incomplete-capture repair crossed the owner boundary';
  end if;
  select public.fail_stale_incomplete_entry(missing_media_id, owner_id)
  into resumed;
  if not resumed then
    raise exception 'stale no-token incomplete capture was not terminalized';
  end if;
  select public.prepare_entry_resume(missing_media_id, owner_id) into resumed;
  if resumed then
    raise exception 'resume discarded the original attachment intent';
  end if;
  select public.claim_entry_processing(missing_media_id, owner_id)
  into processing_claim;
  if processing_claim is not null then
    raise exception 'processor claimed an unpublished intended attachment';
  end if;
  if not exists (
    select 1
    from public.entries
    where id = missing_media_id
      and status = 'failed'
      and status_message = 'Attachment upload incomplete'
      and processing_attempts = 3
      and intended_image
      and intended_audio
      and image_path is null
      and audio_path is null
      and nullif(btrim(transcript), '') is null
  ) then
    raise exception 'rejected incomplete-media resume mutated its row';
  end if;

  select public.prepare_entry_resume(inflight_id, owner_id) into resumed;
  if resumed then
    raise exception 'resume mutated an in-flight processing row';
  end if;
  select status, status_message, processing_attempts, lease_expires_at
  into stored_status, stored_status_message, stored_attempts, stored_lease
  from public.entries
  where id = inflight_id;
  if stored_status <> 'analyzing'
    or stored_status_message <> 'Estimating your meal'
    or stored_attempts <> 1
    or stored_lease <= now() then
    raise exception 'rejected in-flight resume mutated the row';
  end if;

  delete from public.entries
  where id in (
    eligible_id,
    live_lease_id,
    exhausted_id,
    upload_owned_id,
    missing_media_id,
    inflight_id
  );
end;
$$;
