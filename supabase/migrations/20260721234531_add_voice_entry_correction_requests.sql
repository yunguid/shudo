-- Voice and text corrections run independently from the original entry
-- processor. The prior completed meal remains visible until a corrected
-- estimate is validated and atomically applied.

create table public.entry_correction_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  entry_id uuid references public.entries(id) on delete set null,
  client_request_id uuid not null,
  claim_token uuid not null default gen_random_uuid(),
  status text not null default 'processing',
  generation_attempt smallint not null default 1,
  correction_text text,
  analysis_model text,
  transcription_model text,
  provider_response_id text,
  error_message text,
  reserved_at timestamptz not null default now(),
  last_claimed_at timestamptz not null default now(),
  lease_expires_at timestamptz default (now() + interval '135 seconds'),
  completed_at timestamptz,
  constraint entry_correction_requests_user_request_unique
    unique (user_id, client_request_id),
  constraint entry_correction_requests_status_check
    check (status in ('processing', 'complete', 'failed')),
  constraint entry_correction_requests_generation_attempt_check
    check (generation_attempt between 1 and 2),
  constraint entry_correction_requests_text_length_check
    check (
      correction_text is null
      or char_length(correction_text) between 1 and 4000
    ),
  constraint entry_correction_requests_error_length_check
    check (error_message is null or char_length(error_message) <= 500),
  constraint entry_correction_requests_state_check check (
    (
      status = 'processing'
      and lease_expires_at is not null
      and completed_at is null
    )
    or (
      status = 'complete'
      and lease_expires_at is null
      and completed_at is not null
      and correction_text is not null
    )
    or (
      status = 'failed'
      and lease_expires_at is null
      and completed_at is null
    )
  )
);

create index entry_correction_requests_user_claimed_idx
  on public.entry_correction_requests (user_id, last_claimed_at desc);
create index entry_correction_requests_entry_idx
  on public.entry_correction_requests (entry_id)
  where entry_id is not null;
create unique index entry_correction_requests_one_active_entry_idx
  on public.entry_correction_requests (entry_id)
  where status = 'processing';

alter table public.entry_corrections
  add column if not exists request_id uuid
    references public.entry_correction_requests(id) on delete set null;
create unique index if not exists entry_corrections_request_unique_idx
  on public.entry_corrections (request_id)
  where request_id is not null;

alter table public.entry_correction_requests enable row level security;
revoke all on public.entry_correction_requests
  from public, anon, authenticated, service_role;

-- The request table is intentionally not a client Data API surface. The
-- authenticated Edge Function can only access it through the narrowly scoped
-- service-role RPCs below.
create or replace function public.reserve_entry_correction(
  p_entry_id uuid,
  p_user_id uuid,
  p_client_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing public.entry_correction_requests%rowtype;
  active_claim_token uuid;
  current_status text;
  recent_attempts integer;
begin
  if p_entry_id is null or p_user_id is null or p_client_request_id is null then
    raise exception using errcode = '22023', message = 'Correction identifiers are required';
  end if;

  -- Capacity and quota are per-user, so reservations for different meals must
  -- share the same lock. This makes the provider-spend check race-safe.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'shudo-entry-correction-user:' || p_user_id::text,
      0
    )
  );

  select request.* into existing
  from public.entry_correction_requests as request
  where request.user_id = p_user_id
    and request.client_request_id = p_client_request_id
  for update of request;

  if found then
    if existing.entry_id is distinct from p_entry_id then
      return pg_catalog.jsonb_build_object('status', 'conflict');
    end if;
    if existing.status = 'complete' then
      return pg_catalog.jsonb_build_object('status', 'complete');
    end if;
    if existing.status = 'processing'
      and existing.lease_expires_at > pg_catalog.now() then
      return pg_catalog.jsonb_build_object('status', 'processing');
    end if;

    if existing.status = 'processing' then
      update public.entry_correction_requests
      set status = 'failed',
          lease_expires_at = null,
          error_message = 'Correction processing lease expired'
      where id = existing.id;
      existing.status := 'failed';
    end if;

    if existing.generation_attempt >= 2 then
      return pg_catalog.jsonb_build_object('status', 'failed');
    end if;
  end if;

  -- Expired work cannot block this user or meal indefinitely. It remains in
  -- the durable quota ledger because the provider attempt may already have run.
  update public.entry_correction_requests
  set status = 'failed',
      lease_expires_at = null,
      error_message = coalesce(error_message, 'Correction processing lease expired')
  where status = 'processing'
    and lease_expires_at <= pg_catalog.now()
    and (user_id = p_user_id or entry_id = p_entry_id);

  select entry.status into current_status
  from public.entries as entry
  where entry.id = p_entry_id and entry.user_id = p_user_id
  for update of entry;

  if not found then
    return pg_catalog.jsonb_build_object('status', 'not_found');
  end if;
  if current_status in ('queued', 'transcribing', 'analyzing', 'deleting') then
    return pg_catalog.jsonb_build_object('status', 'busy');
  end if;
  if current_status <> 'complete' then
    return pg_catalog.jsonb_build_object('status', 'unavailable');
  end if;

  select
    coalesce(pg_catalog.sum(request.generation_attempt), 0)::integer
    + (
      select pg_catalog.count(*)::integer
      from public.entry_corrections as correction
      where correction.user_id = p_user_id
        and correction.request_id is null
        and correction.created_at >= pg_catalog.now() - interval '24 hours'
    )
  into recent_attempts
  from public.entry_correction_requests as request
  where request.user_id = p_user_id
    and request.last_claimed_at >= pg_catalog.now() - interval '24 hours';

  if recent_attempts >= 10 then
    return pg_catalog.jsonb_build_object('status', 'quota');
  end if;
  if exists (
    select 1 from public.entry_correction_requests as request
    where request.user_id = p_user_id
      and request.status = 'processing'
      and request.lease_expires_at > pg_catalog.now()
      and request.client_request_id <> p_client_request_id
  ) then
    return pg_catalog.jsonb_build_object('status', 'capacity');
  end if;

  if existing.id is not null then
    update public.entry_correction_requests
    set status = 'processing',
        generation_attempt = generation_attempt + 1,
        claim_token = pg_catalog.gen_random_uuid(),
        last_claimed_at = pg_catalog.now(),
        lease_expires_at = pg_catalog.now() + interval '135 seconds',
        error_message = null,
        completed_at = null
    where id = existing.id
    returning claim_token into active_claim_token;
    return pg_catalog.jsonb_build_object(
      'status', 'reclaimed',
      'claim_token', active_claim_token
    );
  end if;

  insert into public.entry_correction_requests (
    user_id,
    entry_id,
    client_request_id
  ) values (
    p_user_id,
    p_entry_id,
    p_client_request_id
  ) returning claim_token into active_claim_token;
  return pg_catalog.jsonb_build_object(
    'status', 'reserved',
    'claim_token', active_claim_token
  );
end;
$$;

revoke all on function public.reserve_entry_correction(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.reserve_entry_correction(uuid, uuid, uuid)
  to service_role;

create or replace function private.entry_correction_analysis_is_valid(
  p_analysis jsonb
)
returns boolean
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  totals jsonb;
begin
  if p_analysis is null or pg_catalog.jsonb_typeof(p_analysis) <> 'object' then
    return false;
  end if;
  if pg_catalog.jsonb_typeof(p_analysis->'title') <> 'string'
    or char_length(pg_catalog.btrim(p_analysis->>'title')) not between 1 and 120
    or pg_catalog.jsonb_typeof(p_analysis->'items') <> 'array'
    or pg_catalog.jsonb_array_length(p_analysis->'items') > 30
    or pg_catalog.jsonb_typeof(p_analysis->'totals') <> 'object'
    or pg_catalog.jsonb_typeof(p_analysis->'confidence') <> 'number'
    or (p_analysis->>'confidence')::numeric not between 0 and 1
    or not (p_analysis ? 'notes')
    or (
      p_analysis->'notes' <> 'null'::jsonb
      and (
        pg_catalog.jsonb_typeof(p_analysis->'notes') <> 'string'
        or char_length(p_analysis->>'notes') > 1000
      )
    ) then
    return false;
  end if;

  totals := p_analysis->'totals';
  if pg_catalog.jsonb_typeof(totals->'protein_g') <> 'number'
    or pg_catalog.jsonb_typeof(totals->'carbs_g') <> 'number'
    or pg_catalog.jsonb_typeof(totals->'fat_g') <> 'number'
    or pg_catalog.jsonb_typeof(totals->'calories_kcal') <> 'number'
    or (totals->>'protein_g')::numeric not between 0 and 100000
    or (totals->>'carbs_g')::numeric not between 0 and 100000
    or (totals->>'fat_g')::numeric not between 0 and 100000
    or (totals->>'calories_kcal')::numeric not between 0 and 1000000 then
    return false;
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_array_elements(p_analysis->'items') as item(value)
    where pg_catalog.jsonb_typeof(item.value) <> 'object'
      or pg_catalog.jsonb_typeof(item.value->'name') <> 'string'
      or char_length(pg_catalog.btrim(item.value->>'name')) < 1
      or pg_catalog.jsonb_typeof(item.value->'amount') <> 'string'
      or char_length(pg_catalog.btrim(item.value->>'amount')) < 1
      or pg_catalog.jsonb_typeof(item.value->'protein_g') <> 'number'
      or pg_catalog.jsonb_typeof(item.value->'carbs_g') <> 'number'
      or pg_catalog.jsonb_typeof(item.value->'fat_g') <> 'number'
      or pg_catalog.jsonb_typeof(item.value->'calories_kcal') <> 'number'
      or pg_catalog.jsonb_typeof(item.value->'confidence') <> 'number'
      or (item.value->>'protein_g')::numeric not between 0 and 100000
      or (item.value->>'carbs_g')::numeric not between 0 and 100000
      or (item.value->>'fat_g')::numeric not between 0 and 100000
      or (item.value->>'calories_kcal')::numeric not between 0 and 1000000
      or (item.value->>'confidence')::numeric not between 0 and 1
  ) then
    return false;
  end if;
  return true;
exception
  when invalid_text_representation or numeric_value_out_of_range then
    return false;
end;
$$;

revoke all on function private.entry_correction_analysis_is_valid(jsonb)
  from public, anon, authenticated, service_role;

create or replace function private.canonical_entry_correction_context(
  p_entry_id uuid,
  p_user_id uuid
)
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  canonical_context text := '';
  correction_row record;
  correction_separator constant text := E'\n\nEarlier correction:\n';
  remaining_characters integer;
begin
  for correction_row in
    select context
    from public.entry_corrections
    where user_id = p_user_id and entry_id = p_entry_id
    order by sequence_no desc
    limit 10
  loop
    if canonical_context = '' then
      canonical_context := pg_catalog.left(correction_row.context, 4000);
    else
      remaining_characters := 4000
        - char_length(canonical_context)
        - char_length(correction_separator);
      exit when remaining_characters <= 0;
      canonical_context := canonical_context
        || correction_separator
        || pg_catalog.left(correction_row.context, remaining_characters);
    end if;
  end loop;
  return canonical_context;
end;
$$;

revoke all on function private.canonical_entry_correction_context(uuid, uuid)
  from public, anon, authenticated, service_role;

create or replace function public.finalize_entry_correction(
  p_entry_id uuid,
  p_user_id uuid,
  p_client_request_id uuid,
  p_claim_token uuid,
  p_correction_text text,
  p_analysis jsonb,
  p_analysis_model text,
  p_transcription_model text,
  p_provider_response_id text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_row public.entry_correction_requests%rowtype;
  normalized_context text := pg_catalog.btrim(coalesce(p_correction_text, ''));
  current_status text;
begin
  -- Use the same per-user lock as reservation so a reclaimed attempt cannot
  -- race an older provider response to the durable request row.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'shudo-entry-correction-user:' || p_user_id::text,
      0
    )
  );

  select request.* into request_row
  from public.entry_correction_requests as request
  where request.user_id = p_user_id
    and request.entry_id = p_entry_id
    and request.client_request_id = p_client_request_id
  for update of request;
  if not found then
    return 'not_found';
  end if;
  if request_row.claim_token is distinct from p_claim_token then
    return 'stale';
  end if;
  if request_row.status <> 'processing' then
    return 'stale';
  end if;

  if char_length(normalized_context) not between 1 and 4000 then
    raise exception using
      errcode = '22023', message = 'Correction context must contain 1 to 4000 characters';
  end if;
  if not private.entry_correction_analysis_is_valid(p_analysis) then
    raise exception using errcode = '22023', message = 'Correction analysis is invalid';
  end if;

  select entry.status into current_status
  from public.entries as entry
  where entry.id = p_entry_id and entry.user_id = p_user_id
  for update of entry;
  if not found then
    return 'not_found';
  end if;
  if current_status <> 'complete' then
    return 'stale';
  end if;

  insert into public.entry_corrections (
    user_id,
    entry_id,
    request_id,
    context
  ) values (
    p_user_id,
    p_entry_id,
    request_row.id,
    normalized_context
  );

  update public.entries
  set title = pg_catalog.btrim(p_analysis->>'title'),
      protein_g = pg_catalog.round((p_analysis #>> '{totals,protein_g}')::numeric, 1),
      carbs_g = pg_catalog.round((p_analysis #>> '{totals,carbs_g}')::numeric, 1),
      fat_g = pg_catalog.round((p_analysis #>> '{totals,fat_g}')::numeric, 1),
      calories_kcal = pg_catalog.round((p_analysis #>> '{totals,calories_kcal}')::numeric, 1),
      confidence = pg_catalog.round((p_analysis->>'confidence')::numeric, 3),
      items = p_analysis->'items',
      analysis_notes = nullif(pg_catalog.btrim(p_analysis->>'notes'), ''),
      analysis_context = private.canonical_entry_correction_context(
        p_entry_id,
        p_user_id
      ),
      status_message = 'Ready',
      analysis_preview = null,
      error_message = null,
      provider_response_id = nullif(pg_catalog.btrim(p_provider_response_id), ''),
      analysis_model = nullif(pg_catalog.btrim(p_analysis_model), ''),
      processed_at = pg_catalog.now()
  where id = p_entry_id and user_id = p_user_id;

  update public.entry_correction_requests
  set status = 'complete',
      correction_text = normalized_context,
      analysis_model = nullif(pg_catalog.btrim(p_analysis_model), ''),
      transcription_model = nullif(pg_catalog.btrim(p_transcription_model), ''),
      provider_response_id = nullif(pg_catalog.btrim(p_provider_response_id), ''),
      error_message = null,
      lease_expires_at = null,
      completed_at = pg_catalog.now()
  where id = request_row.id
    and claim_token = p_claim_token
    and status = 'processing';
  if not found then
    raise exception using
      errcode = '40001',
      message = 'Correction claim changed during finalization';
  end if;

  return 'complete';
end;
$$;

revoke all on function public.finalize_entry_correction(
  uuid, uuid, uuid, uuid, text, jsonb, text, text, text
) from public, anon, authenticated;
grant execute on function public.finalize_entry_correction(
  uuid, uuid, uuid, uuid, text, jsonb, text, text, text
) to service_role;

create or replace function public.fail_entry_correction(
  p_entry_id uuid,
  p_user_id uuid,
  p_client_request_id uuid,
  p_claim_token uuid,
  p_error_message text
)
returns boolean
language sql
security definer
set search_path = ''
as $$
  update public.entry_correction_requests
  set status = 'failed',
      error_message = pg_catalog.left(
        coalesce(nullif(pg_catalog.btrim(p_error_message), ''), 'Correction failed'),
        500
      ),
      lease_expires_at = null,
      completed_at = null
  where user_id = p_user_id
    and (entry_id = p_entry_id or entry_id is null)
    and client_request_id = p_client_request_id
    and claim_token = p_claim_token
    and status = 'processing'
  returning true;
$$;

revoke all on function public.fail_entry_correction(
  uuid, uuid, uuid, uuid, text
)
  from public, anon, authenticated;
grant execute on function public.fail_entry_correction(
  uuid, uuid, uuid, uuid, text
)
  to service_role;

-- Older native builds use prepare_entry_reanalysis, which temporarily changes
-- the meal status. Fence that legacy transition while the safe correction
-- request owns the meal so two provider responses cannot race to overwrite it.
create or replace function private.block_parallel_entry_reanalysis()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'complete'
    and new.status in ('queued', 'transcribing', 'analyzing')
    and exists (
      select 1
      from public.entry_correction_requests as request
      where request.entry_id = old.id
        and request.user_id = old.user_id
        and request.status = 'processing'
        and request.lease_expires_at > pg_catalog.now()
    ) then
    raise exception using
      errcode = 'P0001', message = 'entry_correction_in_progress';
  end if;
  return new;
end;
$$;

revoke all on function private.block_parallel_entry_reanalysis()
  from public, anon, authenticated, service_role;
drop trigger if exists entries_block_parallel_reanalysis on public.entries;
create trigger entries_block_parallel_reanalysis
before update of status on public.entries
for each row execute function private.block_parallel_entry_reanalysis();

comment on table public.entry_correction_requests is
  'Durable idempotency, lease, and provider-spend ledger for voice/text meal corrections. Raw audio is never stored.';
