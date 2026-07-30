-- Append-only photos for an already-complete meal. The original
-- entries.image_path remains the backwards-compatible primary photo; this
-- table holds later memories/evidence without replacing it.

create table if not exists public.entry_photos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  entry_id uuid not null references public.entries(id) on delete cascade,
  correction_request_id uuid references public.entry_correction_requests(id)
    on delete set null,
  client_request_id uuid not null,
  storage_path text not null,
  purpose text not null default 'memory',
  created_at timestamptz not null default now(),
  constraint entry_photos_user_request_unique unique (user_id, client_request_id),
  constraint entry_photos_storage_path_unique unique (storage_path),
  constraint entry_photos_purpose_check check (purpose in ('memory', 'evidence')),
  constraint entry_photos_storage_path_check check (
    char_length(storage_path) between 1 and 500
    and storage_path !~ '(^|/)\.\.(/|$)'
  )
);

create index if not exists entry_photos_entry_created_idx
  on public.entry_photos (entry_id, created_at, id);
create unique index if not exists entry_photos_correction_request_unique_idx
  on public.entry_photos (correction_request_id)
  where correction_request_id is not null;

alter table public.entry_photos enable row level security;
revoke all on table public.entry_photos from public, anon, authenticated, service_role;
grant select on table public.entry_photos to authenticated, service_role;

drop policy if exists entry_photos_select_own on public.entry_photos;
create policy entry_photos_select_own on public.entry_photos
for select to authenticated
using ((select auth.uid()) = user_id);

-- Idempotent memory-photo publication. The object key is deterministic from
-- the client request id, so a retry after a lost response cannot duplicate a
-- photo. If the meal had no primary photo, publish this path there as well so
-- older clients and timeline cards can still display it.
create or replace function public.attach_entry_photo(
  p_entry_id uuid,
  p_user_id uuid,
  p_client_request_id uuid,
  p_storage_path text,
  p_purpose text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing public.entry_photos%rowtype;
  entry_status text;
  required_prefix text;
begin
  if p_entry_id is null or p_user_id is null or p_client_request_id is null then
    raise exception using errcode = '22023', message = 'Photo identifiers are required';
  end if;
  if p_purpose not in ('memory', 'evidence') then
    raise exception using errcode = '22023', message = 'Photo purpose is invalid';
  end if;
  required_prefix := p_user_id::text || '/' || p_entry_id::text
    || '/updates/' || p_client_request_id::text || '/';
  if p_storage_path is null
    or left(p_storage_path, length(required_prefix)) <> required_prefix then
    raise exception using errcode = '22023', message = 'Photo path is outside the update prefix';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shudo-entry-photo:' || p_entry_id::text, 0)
  );
  select entry.status into entry_status
  from public.entries as entry
  where entry.id = p_entry_id and entry.user_id = p_user_id
  for update of entry;
  if not found then return 'not_found'; end if;
  if entry_status <> 'complete' then return 'busy'; end if;

  select photo.* into existing
  from public.entry_photos as photo
  where photo.user_id = p_user_id
    and photo.client_request_id = p_client_request_id;
  if found then
    if existing.entry_id = p_entry_id
      and existing.storage_path = p_storage_path
      and existing.purpose = p_purpose then
      return 'complete';
    end if;
    return 'conflict';
  end if;
  if (
    select pg_catalog.count(*) from public.entry_photos as photo
    where photo.entry_id = p_entry_id and photo.user_id = p_user_id
  ) >= 20 then
    return 'capacity';
  end if;

  insert into public.entry_photos (
    user_id, entry_id, client_request_id, storage_path, purpose
  ) values (
    p_user_id, p_entry_id, p_client_request_id, p_storage_path, p_purpose
  );
  update public.entries
  set image_path = coalesce(image_path, p_storage_path)
  where id = p_entry_id and user_id = p_user_id;
  return 'complete';
end;
$$;

revoke all on function public.attach_entry_photo(uuid, uuid, uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.attach_entry_photo(uuid, uuid, uuid, text, text)
  to service_role;

-- New correction clients can atomically finalize nutrition and publish the
-- evidence photo. The legacy nine-argument function remains callable by old
-- Edge deployments/native releases.
create or replace function public.finalize_entry_correction(
  p_entry_id uuid,
  p_user_id uuid,
  p_client_request_id uuid,
  p_claim_token uuid,
  p_correction_text text,
  p_analysis jsonb,
  p_analysis_model text,
  p_transcription_model text,
  p_provider_response_id text,
  p_photo_path text,
  p_photo_purpose text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  finalized text;
  request_id uuid;
  photo_result text;
begin
  finalized := public.finalize_entry_correction(
    p_entry_id,
    p_user_id,
    p_client_request_id,
    p_claim_token,
    p_correction_text,
    p_analysis,
    p_analysis_model,
    p_transcription_model,
    p_provider_response_id
  );
  if finalized <> 'complete' or p_photo_path is null then
    return finalized;
  end if;

  photo_result := public.attach_entry_photo(
    p_entry_id,
    p_user_id,
    p_client_request_id,
    p_photo_path,
    coalesce(p_photo_purpose, 'evidence')
  );
  if photo_result <> 'complete' then
    raise exception using errcode = '40001', message = 'Correction photo could not be published';
  end if;
  select request.id into request_id
  from public.entry_correction_requests as request
  where request.user_id = p_user_id
    and request.entry_id = p_entry_id
    and request.client_request_id = p_client_request_id;
  update public.entry_photos
  set correction_request_id = request_id
  where user_id = p_user_id and client_request_id = p_client_request_id;
  return finalized;
end;
$$;

revoke all on function public.finalize_entry_correction(
  uuid, uuid, uuid, uuid, text, jsonb, text, text, text, text, text
) from public, anon, authenticated;
grant execute on function public.finalize_entry_correction(
  uuid, uuid, uuid, uuid, text, jsonb, text, text, text, text, text
) to service_role;

-- Keep deletion transactional: every appended photo is placed in the durable
-- cleanup outbox before the entry cascade removes its metadata.
create or replace function public.delete_entry_with_cleanup(
  p_entry_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  entry_row public.entries%rowtype;
  photo_row record;
begin
  select entry.* into entry_row
  from public.entries as entry
  where entry.id = p_entry_id
    and entry.user_id = p_user_id
    and entry.status in ('complete', 'failed', 'deleting')
  for update of entry;
  if not found then return false; end if;

  if entry_row.image_path is not null then
    perform private.enqueue_storage_cleanup_job(
      'entry-images', 'object', entry_row.image_path, now()
    );
  end if;
  for photo_row in
    select storage_path from public.entry_photos
    where entry_id = p_entry_id and user_id = p_user_id
      and storage_path is distinct from entry_row.image_path
  loop
    perform private.enqueue_storage_cleanup_job(
      'entry-images', 'object', photo_row.storage_path, now()
    );
  end loop;
  if entry_row.audio_path is not null then
    perform private.enqueue_storage_cleanup_job(
      'entry-audio', 'object', entry_row.audio_path, now()
    );
  end if;
  if entry_row.upload_token is not null then
    perform private.enqueue_entry_upload_prefixes(
      p_user_id, p_entry_id, entry_row.upload_token, now() + interval '5 minutes'
    );
  end if;
  delete from public.entries where id = entry_row.id;
  return true;
end;
$$;

revoke all on function public.delete_entry_with_cleanup(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.delete_entry_with_cleanup(uuid, uuid)
  to service_role;

comment on table public.entry_photos is
  'Photos appended to completed meals without replacing the original capture; purpose separates nutrition evidence from memory-only media.';
