-- Voice/text correction requests reserve provider spend before work begins and
-- never hide or mutate the prior valid meal until finalization succeeds.
insert into auth.users (id, email)
values
  ('00000000-0000-4000-8000-000000000005', 'correction@example.test'),
  ('00000000-0000-4000-8000-000000000006', 'correction-quota@example.test');

do $$
declare
  correction_user constant uuid := '00000000-0000-4000-8000-000000000005';
  other_user constant uuid := '00000000-0000-4000-8000-000000000002';
  v_entry_id constant uuid := '60000000-0000-4000-8000-000000000001';
  v_request_id constant uuid := '61000000-0000-4000-8000-000000000001';
  valid_analysis constant jsonb := '{
    "analysis_preview":"Adding steak raises protein and calories.",
    "title":"Steak burrito bowl",
    "items":[{
      "name":"Steak burrito bowl",
      "amount":"half bowl with steak",
      "protein_g":43,
      "carbs_g":71,
      "fat_g":34,
      "calories_kcal":790,
      "confidence":0.8
    }],
    "totals":{
      "protein_g":43,
      "carbs_g":71,
      "fat_g":34,
      "calories_kcal":790
    },
    "confidence":0.8,
    "notes":"Includes one restaurant serving of steak."
  }'::jsonb;
  reservation jsonb;
  transition text;
  first_claim_token uuid;
  active_claim_token uuid;
  blocked boolean := false;
  failure_recorded boolean;
begin
  if has_table_privilege(
    'anon', 'public.entry_correction_requests', 'select'
  ) or has_table_privilege(
    'authenticated', 'public.entry_correction_requests', 'select'
  ) or has_table_privilege(
    'service_role', 'public.entry_correction_requests', 'select'
  ) then
    raise exception 'correction request ledger is directly exposed';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.reserve_entry_correction(uuid, uuid, uuid)',
    'execute'
  ) or not has_function_privilege(
    'service_role',
    'public.reserve_entry_correction(uuid, uuid, uuid)',
    'execute'
  ) then
    raise exception 'correction reservation RPC privileges are unsafe';
  end if;
  if has_function_privilege(
    'authenticated',
    'public.finalize_entry_correction(uuid, uuid, uuid, uuid, text, jsonb, text, text, text)',
    'execute'
  ) or not has_function_privilege(
    'service_role',
    'public.finalize_entry_correction(uuid, uuid, uuid, uuid, text, jsonb, text, text, text)',
    'execute'
  ) or has_function_privilege(
    'authenticated',
    'public.fail_entry_correction(uuid, uuid, uuid, uuid, text)',
    'execute'
  ) or not has_function_privilege(
    'service_role',
    'public.fail_entry_correction(uuid, uuid, uuid, uuid, text)',
    'execute'
  ) then
    raise exception 'correction terminal RPC privileges are unsafe';
  end if;

  insert into public.entries (
    id,
    user_id,
    client_request_id,
    local_day,
    status,
    status_message,
    title,
    raw_text,
    protein_g,
    carbs_g,
    fat_g,
    calories_kcal,
    confidence,
    items,
    processed_at
  ) values (
    v_entry_id,
    correction_user,
    '62000000-0000-4000-8000-000000000001',
    '2026-07-21',
    'complete',
    'Ready',
    'Vegetarian bowl',
    'Half a bowl with rice, peppers, corn, pico, cheese, and guacamole.',
    20,
    70,
    28,
    620,
    0.7,
    '[{"name":"Vegetarian bowl","amount":"half bowl","protein_g":20,"carbs_g":70,"fat_g":28,"calories_kcal":620,"confidence":0.7}]'::jsonb,
    now()
  );

  select public.reserve_entry_correction(v_entry_id, other_user, v_request_id)
  into reservation;
  transition := reservation->>'status';
  if transition <> 'not_found' then
    raise exception 'correction reservation crossed ownership: %', transition;
  end if;

  select public.reserve_entry_correction(
    v_entry_id, correction_user, v_request_id
  )
  into reservation;
  transition := reservation->>'status';
  first_claim_token := (reservation->>'claim_token')::uuid;
  if transition <> 'reserved' then
    raise exception 'correction spend was not reserved: %', transition;
  end if;
  if first_claim_token is null then
    raise exception 'correction reservation omitted its claim token';
  end if;
  if not exists (
    select 1 from public.entries
    where id = v_entry_id
      and status = 'complete'
      and title = 'Vegetarian bowl'
      and calories_kcal = 620
  ) then
    raise exception 'reservation hid or changed the prior valid meal';
  end if;

  select public.reserve_entry_correction(
    v_entry_id, correction_user, v_request_id
  )
  into reservation;
  transition := reservation->>'status';
  if transition <> 'processing' then
    raise exception 'duplicate in-flight correction was not idempotent: %', transition;
  end if;

  begin
    perform public.prepare_entry_reanalysis(
      v_entry_id,
      correction_user,
      'A legacy client attempted a parallel correction.'
    );
  exception when raise_exception then
    blocked := sqlerrm = 'entry_correction_in_progress';
  end;
  if not blocked then
    raise exception 'legacy correction was not fenced from active voice work';
  end if;
  if exists (
    select 1 from public.entry_corrections as correction
    where correction.entry_id = v_entry_id
  ) then
    raise exception 'blocked legacy correction left partial audit state';
  end if;

  select public.fail_entry_correction(
    v_entry_id,
    correction_user,
    v_request_id,
    first_claim_token,
    'synthetic transcription failure'
  ) into failure_recorded;
  if not failure_recorded then
    raise exception 'failed correction reservation was not terminalized';
  end if;
  if not exists (
    select 1 from public.entries
    where id = v_entry_id
      and status = 'complete'
      and title = 'Vegetarian bowl'
      and calories_kcal = 620
  ) then
    raise exception 'failed correction changed the prior valid meal';
  end if;

  select public.reserve_entry_correction(
    v_entry_id, correction_user, v_request_id
  )
  into reservation;
  transition := reservation->>'status';
  active_claim_token := (reservation->>'claim_token')::uuid;
  if transition <> 'reclaimed' then
    raise exception 'same correction could not retry once: %', transition;
  end if;
  if active_claim_token is null or active_claim_token = first_claim_token then
    raise exception 'reclaimed correction did not rotate its claim token';
  end if;
  if not exists (
    select 1 from public.entry_correction_requests
    where user_id = correction_user
      and client_request_id = v_request_id
      and status = 'processing'
      and generation_attempt = 2
  ) then
    raise exception 'retry did not consume a second durable provider attempt';
  end if;

  select public.fail_entry_correction(
    v_entry_id,
    correction_user,
    v_request_id,
    first_claim_token,
    'stale worker failure'
  ) into failure_recorded;
  if failure_recorded then
    raise exception 'stale claim token terminalized the reclaimed correction';
  end if;
  if not exists (
    select 1 from public.entry_correction_requests
    where user_id = correction_user
      and client_request_id = v_request_id
      and claim_token = active_claim_token
      and status = 'processing'
  ) then
    raise exception 'stale failure changed the active correction claim';
  end if;

  select public.finalize_entry_correction(
    v_entry_id,
    correction_user,
    v_request_id,
    first_claim_token,
    'The bowl also had steak.',
    valid_analysis,
    'gpt-5.6-sol',
    'gpt-4o-transcribe',
    'response-stale'
  ) into transition;
  if transition <> 'stale' then
    raise exception 'stale claim token was allowed to finalize: %', transition;
  end if;
  if exists (
    select 1 from public.entry_corrections as correction
    where correction.entry_id = v_entry_id
  ) or not exists (
    select 1 from public.entries
    where id = v_entry_id
      and title = 'Vegetarian bowl'
      and calories_kcal = 620
  ) then
    raise exception 'stale finalization mutated the valid meal';
  end if;

  blocked := false;
  begin
    perform public.finalize_entry_correction(
      v_entry_id,
      correction_user,
      v_request_id,
      active_claim_token,
      'The bowl also had steak.',
      '{"title":"broken"}'::jsonb,
      'gpt-5.6-sol',
      'gpt-4o-transcribe',
      'response-broken'
    );
  exception when invalid_parameter_value then
    blocked := true;
  end;
  if not blocked then
    raise exception 'invalid correction analysis was accepted';
  end if;

  select public.finalize_entry_correction(
    v_entry_id,
    correction_user,
    v_request_id,
    active_claim_token,
    'The bowl also had steak.',
    valid_analysis,
    'gpt-5.6-sol',
    'gpt-4o-transcribe',
    'response-corrected'
  ) into transition;
  if transition <> 'complete' then
    raise exception 'valid correction was not finalized: %', transition;
  end if;

  if not exists (
    select 1 from public.entries
    where id = v_entry_id
      and status = 'complete'
      and title = 'Steak burrito bowl'
      and protein_g = 43
      and calories_kcal = 790
      and analysis_context = 'The bowl also had steak.'
      and provider_response_id = 'response-corrected'
      and analysis_model = 'gpt-5.6-sol'
      and transcription_model is null
  ) then
    raise exception 'final correction did not atomically replace the estimate';
  end if;
  if (
    select count(*) from public.entry_corrections as correction
    where correction.entry_id = v_entry_id
      and correction.request_id is not null
  ) <> 1 then
    raise exception 'successful correction audit row was not exactly-once';
  end if;
  if not exists (
    select 1 from public.entry_correction_requests
    where user_id = correction_user
      and client_request_id = v_request_id
      and status = 'complete'
      and lease_expires_at is null
      and completed_at is not null
      and correction_text = 'The bowl also had steak.'
      and transcription_model = 'gpt-4o-transcribe'
  ) then
    raise exception 'successful correction request was not terminalized';
  end if;

  select public.finalize_entry_correction(
    v_entry_id,
    correction_user,
    v_request_id,
    active_claim_token,
    'Duplicate completion must not run.',
    valid_analysis,
    'gpt-5.6-sol',
    'gpt-4o-transcribe',
    'response-duplicate'
  ) into transition;
  if transition <> 'stale' or not exists (
    select 1 from public.entries
    where id = v_entry_id
      and provider_response_id = 'response-corrected'
  ) or (
    select count(*) from public.entry_corrections as correction
    where correction.entry_id = v_entry_id
      and correction.request_id is not null
  ) <> 1 then
    raise exception 'completed claim was allowed to finalize twice';
  end if;

  select public.reserve_entry_correction(
    v_entry_id, correction_user, v_request_id
  )
  into reservation;
  transition := reservation->>'status';
  if transition <> 'complete' then
    raise exception 'completed correction was not replay-safe: %', transition;
  end if;

  delete from public.entries where id = v_entry_id;
  if not exists (
    select 1 from public.entry_correction_requests
    where user_id = correction_user
      and client_request_id = v_request_id
      and entry_id is null
      and generation_attempt = 2
  ) then
    raise exception 'meal deletion erased the durable correction spend ledger';
  end if;
end;
$$;

do $$
declare
  quota_user constant uuid := '00000000-0000-4000-8000-000000000006';
  v_entry_id constant uuid := '63000000-0000-4000-8000-000000000001';
  fixture_index integer;
  reservation jsonb;
  transition text;
begin
  insert into public.entries (
    id, user_id, client_request_id, local_day, status, title
  ) values (
    v_entry_id,
    quota_user,
    '64000000-0000-4000-8000-000000000001',
    '2026-07-21',
    'complete',
    'Quota fixture'
  );
  for fixture_index in 1..10 loop
    insert into public.entry_corrections (user_id, entry_id, context)
    values (quota_user, v_entry_id, 'legacy correction ' || fixture_index);
  end loop;

  select public.reserve_entry_correction(
    v_entry_id,
    quota_user,
    '65000000-0000-4000-8000-000000000001'
  ) into reservation;
  transition := reservation->>'status';
  if transition <> 'quota' then
    raise exception 'provider spend was not rejected before correction 11: %', transition;
  end if;
  if exists (
    select 1 from public.entry_correction_requests where user_id = quota_user
  ) then
    raise exception 'quota rejection created a provider reservation';
  end if;
end;
$$;

do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'entry_correction_requests'
      and column_name in ('audio', 'audio_path', 'audio_url', 'audio_data')
  ) then
    raise exception 'correction request ledger persists raw audio';
  end if;
end;
$$;
