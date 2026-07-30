-- Existing-meal photos append safely, preserve the legacy image and nutrition,
-- dedupe ambiguous retries, remain owner-scoped, and join deletion cleanup.
do $$
<<existing_meal_photos>>
declare
  owner_id constant uuid := '00000000-0000-4000-8000-000000000001';
  other_id constant uuid := '00000000-0000-4000-8000-000000000002';
  entry_id constant uuid := '71000000-0000-4000-8000-000000000001';
  request_id constant uuid := '72000000-0000-4000-8000-000000000001';
  original_path constant text :=
    '00000000-0000-4000-8000-000000000001/71000000-0000-4000-8000-000000000001/original/photo.jpg';
  appended_path constant text :=
    '00000000-0000-4000-8000-000000000001/71000000-0000-4000-8000-000000000001/updates/72000000-0000-4000-8000-000000000001/photo.jpg';
  other_path constant text :=
    '00000000-0000-4000-8000-000000000002/71000000-0000-4000-8000-000000000001/updates/72000000-0000-4000-8000-000000000001/photo.jpg';
  result text;
begin
  if has_table_privilege('anon', 'public.entry_photos', 'select')
    or has_table_privilege('authenticated', 'public.entry_photos', 'insert')
    or not has_table_privilege('service_role', 'public.entry_photos', 'select')
    or has_function_privilege(
      'authenticated',
      'public.attach_entry_photo(uuid, uuid, uuid, text, text)',
      'execute'
    )
    or not has_function_privilege(
      'service_role',
      'public.attach_entry_photo(uuid, uuid, uuid, text, text)',
      'execute'
    ) then
    raise exception 'entry photo privileges are unsafe';
  end if;

  insert into public.entries (
    id, user_id, client_request_id, local_day, status, title, image_path,
    protein_g, carbs_g, fat_g, calories_kcal
  ) values (
    entry_id, owner_id, '73000000-0000-4000-8000-000000000001',
    '2026-07-29', 'complete', 'Birthday dinner', original_path,
    40, 80, 25, 705
  );

  result := public.attach_entry_photo(
    entry_id, owner_id, request_id, appended_path, 'memory'
  );
  if result <> 'complete' then
    raise exception 'memory photo did not attach: %', result;
  end if;
  result := public.attach_entry_photo(
    entry_id, owner_id, request_id, appended_path, 'memory'
  );
  if result <> 'complete'
    or (
      select count(*) from public.entry_photos as photo
      where photo.entry_id = existing_meal_photos.entry_id
    ) <> 1 then
    raise exception 'memory photo retry was not idempotent';
  end if;
  if not exists (
    select 1 from public.entries as entry
    where entry.id = existing_meal_photos.entry_id
      and image_path = original_path
      and protein_g = 40 and carbs_g = 80 and fat_g = 25 and calories_kcal = 705
  ) then
    raise exception 'memory photo replaced original data or nutrition';
  end if;
  if not exists (
    select 1 from public.entry_photos as photo
    where photo.entry_id = existing_meal_photos.entry_id
      and user_id = owner_id
      and client_request_id = request_id
      and storage_path = appended_path
      and purpose = 'memory'
      and created_at is not null
  ) then
    raise exception 'appended photo metadata was not preserved';
  end if;
  if public.attach_entry_photo(
    entry_id, other_id, request_id, other_path, 'memory'
  ) <> 'not_found' then
    raise exception 'photo attachment crossed the owner boundary';
  end if;

  if not public.delete_entry_with_cleanup(entry_id, owner_id) then
    raise exception 'meal with appended photo was not deleted';
  end if;
  if exists (
    select 1 from public.entry_photos as photo
    where photo.entry_id = existing_meal_photos.entry_id
  )
    or not exists (
      select 1 from private.storage_cleanup_jobs
      where bucket = 'entry-images' and mode = 'object' and object_path = original_path
    )
    or not exists (
      select 1 from private.storage_cleanup_jobs
      where bucket = 'entry-images' and mode = 'object' and object_path = appended_path
    ) then
    raise exception 'meal deletion did not clean up all photo metadata and objects';
  end if;
end;
$$;

-- Evidence photos publish in the same transaction as the corrected estimate.
do $$
<<evidence_photo>>
declare
  owner_id constant uuid := '00000000-0000-4000-8000-000000000001';
  entry_id constant uuid := '71000000-0000-4000-8000-000000000002';
  request_id constant uuid := '72000000-0000-4000-8000-000000000002';
  original_path constant text :=
    '00000000-0000-4000-8000-000000000001/71000000-0000-4000-8000-000000000002/original/photo.jpg';
  evidence_path constant text :=
    '00000000-0000-4000-8000-000000000001/71000000-0000-4000-8000-000000000002/updates/72000000-0000-4000-8000-000000000002/photo.jpg';
  valid_analysis constant jsonb := '{
    "title":"Birthday dinner, corrected",
    "items":[{
      "name":"Dinner",
      "amount":"half serving",
      "protein_g":35,
      "carbs_g":60,
      "fat_g":20,
      "calories_kcal":560,
      "confidence":0.8
    }],
    "totals":{
      "protein_g":35,
      "carbs_g":60,
      "fat_g":20,
      "calories_kcal":560
    },
    "confidence":0.8,
    "notes":"The correction and evidence photo show a half serving."
  }'::jsonb;
  reservation jsonb;
  transition text;
begin
  insert into public.entries (
    id, user_id, client_request_id, local_day, status, title, image_path,
    protein_g, carbs_g, fat_g, calories_kcal
  ) values (
    entry_id, owner_id, '73000000-0000-4000-8000-000000000002',
    '2026-07-29', 'complete', 'Birthday dinner', original_path,
    40, 80, 25, 705
  );

  reservation := public.reserve_entry_correction(entry_id, owner_id, request_id);
  if reservation->>'status' <> 'reserved' then
    raise exception 'evidence correction was not reserved: %', reservation;
  end if;
  transition := public.finalize_entry_correction(
    entry_id,
    owner_id,
    request_id,
    (reservation->>'claim_token')::uuid,
    'The evidence photo shows half the serving.',
    valid_analysis,
    'gpt-test',
    null,
    'response-test',
    evidence_path,
    'evidence'
  );
  if transition <> 'complete' then
    raise exception 'evidence correction did not finalize: %', transition;
  end if;
  if not exists (
    select 1 from public.entries as entry
    where entry.id = evidence_photo.entry_id
      and entry.image_path = original_path
      and entry.title = 'Birthday dinner, corrected'
      and entry.protein_g = 35
      and entry.carbs_g = 60
      and entry.fat_g = 20
      and entry.calories_kcal = 560
  ) then
    raise exception 'evidence finalization did not preserve identity/photo or update nutrition';
  end if;
  if not exists (
    select 1
    from public.entry_photos as photo
    join public.entry_correction_requests as request
      on request.id = photo.correction_request_id
    where photo.entry_id = evidence_photo.entry_id
      and photo.client_request_id = evidence_photo.request_id
      and photo.storage_path = evidence_photo.evidence_path
      and photo.purpose = 'evidence'
      and request.status = 'complete'
  ) then
    raise exception 'evidence photo and correction metadata were not published atomically';
  end if;
  -- This fixture validates publication, while the block above owns deletion
  -- cleanup coverage. Remove it so later schema-wide row-count checks retain
  -- their original baseline.
  delete from public.entries where id = evidence_photo.entry_id;
end;
$$;
