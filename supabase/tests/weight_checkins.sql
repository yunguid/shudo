-- Weigh-ins are strictly user-owned at the row and Storage layers, keep one
-- observation per local day, and the weekly summary's micronutrient report
-- only ever stores a JSON object.

do $$
begin
  if not exists (
    select 1 from storage.buckets
    where id = 'weight-checkin-photos'
      and public = false
      and file_size_limit = 4194304
      and allowed_mime_types = array['image/jpeg']
  ) then
    raise exception 'private weigh-in photo bucket is missing or unsafe';
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'weight_checkins'
      and column_name = 'scale_photo_path'
  ) then
    raise exception 'weight_checkins still carries the removed scale photo column';
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'weekly_summaries'
      and column_name = 'micronutrient_report'
  ) then
    raise exception 'weekly_summaries is missing micronutrient_report';
  end if;

  if has_table_privilege('anon', 'public.weight_checkins', 'select') then
    raise exception 'anon unexpectedly reads weight_checkins';
  end if;
end;
$$;

-- The report column only accepts JSON objects.
do $$
declare
  rejected boolean := false;
begin
  begin
    update public.weekly_summaries
    set micronutrient_report = '[]'::jsonb
    where user_id = '00000000-0000-4000-8000-000000000001';
  exception when check_violation then
    rejected := true;
  end;
  if exists (
    select 1 from public.weekly_summaries
    where user_id = '00000000-0000-4000-8000-000000000001'
  ) and not rejected then
    raise exception 'micronutrient_report accepted a non-object payload';
  end if;
end;
$$;

set role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-4000-8000-000000000001',
  false
);

do $$
declare
  visible_count integer;
  stored_weight numeric;
  cross_user_rejected boolean := false;
  range_rejected boolean := false;
  foreign_path_rejected boolean := false;
begin
  insert into public.weight_checkins (user_id, local_day, weight_kg)
  values ('00000000-0000-4000-8000-000000000001', '2026-07-30', 82.6);

  -- Same-day upsert replaces rather than duplicates.
  insert into public.weight_checkins (user_id, local_day, weight_kg)
  values ('00000000-0000-4000-8000-000000000001', '2026-07-30', 82.4)
  on conflict (user_id, local_day)
  do update set weight_kg = excluded.weight_kg;

  select count(*), max(weight_kg)
  into visible_count, stored_weight
  from public.weight_checkins
  where local_day = '2026-07-30';
  if visible_count <> 1 or stored_weight <> 82.4 then
    raise exception 'weigh-in upsert kept % rows at %', visible_count, stored_weight;
  end if;

  begin
    insert into public.weight_checkins (user_id, local_day, weight_kg)
    values ('00000000-0000-4000-8000-000000000002', '2026-07-30', 90);
  exception when insufficient_privilege or check_violation then
    cross_user_rejected := true;
  end;
  if not cross_user_rejected then
    raise exception 'weigh-in INSERT crossed the owner boundary';
  end if;

  begin
    insert into public.weight_checkins (user_id, local_day, weight_kg)
    values ('00000000-0000-4000-8000-000000000001', '2026-07-29', 12);
  exception when check_violation then
    range_rejected := true;
  end;
  if not range_rejected then
    raise exception 'weight range check accepted 12 kg';
  end if;

  begin
    insert into public.weight_checkins (
      user_id, local_day, weight_kg, progress_photo_path
    ) values (
      '00000000-0000-4000-8000-000000000001',
      '2026-07-28',
      82,
      '00000000-0000-4000-8000-000000000002/2026-07-28/progress-11111111-2222-4333-8444-555555555555.jpg'
    );
  exception when check_violation then
    foreign_path_rejected := true;
  end;
  if not foreign_path_rejected then
    raise exception 'progress photo path accepted another user''s folder';
  end if;
end;
$$;

-- Storage policies admit only the owner's dated progress paths.
do $$
declare
  cross_user_rejected boolean := false;
  malformed_rejected boolean := false;
begin
  insert into storage.objects (bucket_id, name)
  values (
    'weight-checkin-photos',
    '00000000-0000-4000-8000-000000000001/2026-07-30/progress-11111111-2222-4333-8444-555555555555.jpg'
  );
  delete from storage.objects
  where bucket_id = 'weight-checkin-photos'
    and name = '00000000-0000-4000-8000-000000000001/2026-07-30/progress-11111111-2222-4333-8444-555555555555.jpg';

  begin
    insert into storage.objects (bucket_id, name)
    values (
      'weight-checkin-photos',
      '00000000-0000-4000-8000-000000000002/2026-07-30/progress-22222222-2222-4222-8222-222222222222.jpg'
    );
  exception when insufficient_privilege then
    cross_user_rejected := true;
  end;
  if not cross_user_rejected then
    raise exception 'weigh-in photo INSERT crossed the owner boundary';
  end if;

  begin
    insert into storage.objects (bucket_id, name)
    values (
      'weight-checkin-photos',
      '00000000-0000-4000-8000-000000000001/2026-07-30/scale-33333333-3333-4333-8333-333333333333.jpg'
    );
  exception when insufficient_privilege then
    malformed_rejected := true;
  end;
  if not malformed_rejected then
    raise exception 'weigh-in photo policy accepted a non-progress name';
  end if;
end;
$$;

reset role;

do $$
begin
  delete from public.weight_checkins
  where user_id = '00000000-0000-4000-8000-000000000001';
end;
$$;
