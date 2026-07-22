-- Profile photos stay private and user-scoped at both the profile row and
-- Storage object layers.
do $$
begin
  if not exists (
    select 1 from storage.buckets
    where id = 'profile-photos'
      and public = false
      and file_size_limit = 2097152
      and allowed_mime_types = array['image/jpeg']
  ) then
    raise exception 'private profile photo bucket is missing or unsafe';
  end if;
end;
$$;

insert into storage.objects (bucket_id, name)
values
  ('profile-photos', '00000000-0000-4000-8000-000000000001/11111111-1111-4111-8111-111111111111.jpg'),
  ('profile-photos', '00000000-0000-4000-8000-000000000002/22222222-2222-4222-8222-222222222222.jpg');

set role authenticated;
select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-4000-8000-000000000001',
  false
);

do $$
declare
  visible_count integer;
  cross_user_insert_rejected boolean := false;
  malformed_name_rejected boolean := false;
  invalid_profile_path_rejected boolean := false;
begin
  select count(*) into visible_count
  from storage.objects
  where bucket_id = 'profile-photos';
  if visible_count <> 1 then
    raise exception 'profile photo SELECT exposed % objects instead of one', visible_count;
  end if;

  insert into storage.objects (bucket_id, name)
  values (
    'profile-photos',
    '00000000-0000-4000-8000-000000000001/33333333-3333-4333-8333-333333333333.jpg'
  );
  update storage.objects
  set name = '00000000-0000-4000-8000-000000000001/44444444-4444-4444-8444-444444444444.jpg'
  where name = '00000000-0000-4000-8000-000000000001/33333333-3333-4333-8333-333333333333.jpg';
  delete from storage.objects
  where name = '00000000-0000-4000-8000-000000000001/44444444-4444-4444-8444-444444444444.jpg';

  begin
    insert into storage.objects (bucket_id, name)
    values (
      'profile-photos',
      '00000000-0000-4000-8000-000000000002/55555555-5555-4555-8555-555555555555.jpg'
    );
  exception when insufficient_privilege then
    cross_user_insert_rejected := true;
  end;
  if not cross_user_insert_rejected then
    raise exception 'profile photo INSERT crossed the owner boundary';
  end if;

  begin
    insert into storage.objects (bucket_id, name)
    values (
      'profile-photos',
      '00000000-0000-4000-8000-000000000001/not-a-versioned-photo.jpg'
    );
  exception when insufficient_privilege then
    malformed_name_rejected := true;
  end;
  if not malformed_name_rejected then
    raise exception 'profile photo INSERT accepted a malformed object name';
  end if;

  begin
    update public.profiles
    set avatar_path = '00000000-0000-4000-8000-000000000002/22222222-2222-4222-8222-222222222222.jpg'
    where user_id = '00000000-0000-4000-8000-000000000001';
  exception when check_violation then
    invalid_profile_path_rejected := true;
  end;
  if not invalid_profile_path_rejected then
    raise exception 'profile accepted another user''s avatar path';
  end if;

  update public.profiles
  set avatar_path = '00000000-0000-4000-8000-000000000001/11111111-1111-4111-8111-111111111111.jpg'
  where user_id = '00000000-0000-4000-8000-000000000001';
end;
$$;

reset role;
