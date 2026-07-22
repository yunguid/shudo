-- A bounded, user-visible sentence is persisted while the Responses API emits
-- strict JSON. It is deliberately ephemeral: terminal and replacement states
-- clear it under the same processing-attempt fence as the rest of the row.
alter table public.entries
  add column if not exists analysis_preview text;

update public.entries
set analysis_preview = null
where analysis_preview is not null;

alter table public.entries
  drop constraint if exists entries_analysis_preview_valid;
alter table public.entries
  add constraint entries_analysis_preview_valid check (
    analysis_preview is null
    or (
      status = 'analyzing'
      and nullif(btrim(analysis_preview), '') is not null
      and char_length(analysis_preview) <= 240
    )
  );

comment on column public.entries.analysis_preview is
  'Bounded natural-language partial shown only during the active analyzing state.';

create or replace function public.prepare_entry_resume(
  p_entry_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  queued_id uuid;
begin
  update public.entries as entry
  set status = 'queued',
      status_message = 'Queued',
      analysis_preview = null,
      error_message = null,
      lease_expires_at = null
  where entry.id = p_entry_id
    and entry.user_id = p_user_id
    and entry.status = 'failed'
    and entry.processing_attempts < 3
    and entry.upload_token is null
    and (not entry.intended_image or entry.image_path is not null)
    and (
      not entry.intended_audio
      or entry.audio_path is not null
      or nullif(btrim(entry.transcript), '') is not null
    )
    and coalesce(
      entry.lease_expires_at,
      '-infinity'::timestamptz
    ) < now()
  returning entry.id into queued_id;

  return queued_id is not null;
end;
$$;

revoke all on function public.prepare_entry_resume(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.prepare_entry_resume(uuid, uuid)
  to service_role;

create or replace function public.claim_entry_processing(
  p_entry_id uuid,
  p_user_id uuid
)
returns smallint
language plpgsql
security definer
set search_path = ''
as $$
declare
  claimed_attempt smallint;
begin
  update public.entries
  set processing_attempts = processing_attempts + 1,
      lease_expires_at = now() + interval '135 seconds',
      status = case
        when audio_path is not null and transcript is null then 'transcribing'
        else 'analyzing'
      end,
      status_message = case
        when audio_path is not null and transcript is null then 'Listening to your note'
        else 'Estimating your meal'
      end,
      analysis_preview = null,
      error_message = null
  where id = p_entry_id
    and user_id = p_user_id
    and processing_attempts < 3
    and upload_token is null
    and (not intended_image or image_path is not null)
    and (
      not intended_audio
      or audio_path is not null
      or nullif(btrim(transcript), '') is not null
    )
    and (
      (
        status in ('queued', 'failed')
        and coalesce(lease_expires_at, '-infinity'::timestamptz) < now()
      )
      or (
        status in ('transcribing', 'analyzing')
        and coalesce(lease_expires_at, '-infinity'::timestamptz) < now()
      )
    )
  returning processing_attempts into claimed_attempt;

  return claimed_attempt;
end;
$$;

revoke all on function public.claim_entry_processing(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.claim_entry_processing(uuid, uuid)
  to service_role;

create or replace function public.fail_exhausted_entry_processing(
  p_entry_id uuid,
  p_user_id uuid,
  p_processing_attempt smallint
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  repaired_id uuid;
begin
  update public.entries
  set status = 'failed',
      status_message = 'Retry limit reached',
      analysis_preview = null,
      error_message = 'This meal could not be recovered. Delete it and log it again.',
      lease_expires_at = null
  where id = p_entry_id
    and user_id = p_user_id
    and processing_attempts = p_processing_attempt
    and processing_attempts >= 3
    and upload_token is null
    and status in ('queued', 'transcribing', 'analyzing')
    and coalesce(lease_expires_at, '-infinity'::timestamptz) < now()
  returning id into repaired_id;

  return repaired_id is not null;
end;
$$;

revoke all on function public.fail_exhausted_entry_processing(uuid, uuid, smallint)
  from public, anon, authenticated;
grant execute on function public.fail_exhausted_entry_processing(uuid, uuid, smallint)
  to service_role;
