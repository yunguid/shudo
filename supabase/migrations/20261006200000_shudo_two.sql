-- Shudo 2.0: the coach in your pocket. Additive on fresh and restored projects
-- and safe to replay. Adds coach settings on profiles, pooled AI budgets with
-- a per-call cost ledger and a coach spend breaker, a private fenced coach job
-- ledger, the in-app coach thread, living coach memory, nightly day digests,
-- activities, training plans, photo-first body check-ins, device context, and
-- a private coach-media bucket.
--
-- There is deliberately no pg_cron, pg_net, or Vault here. Daily coach work is
-- dispatched by the existing scheduled maintenance function; everything else
-- is event-driven. Every write path below is a service-role RPC fenced on a
-- (run_id, claim_token) pair, except the narrow client columns granted
-- through RLS (coach_messages.read_at, body check-ins, device snapshots, and
-- profile coach settings).

-- 1. Profile coach settings. target_weight_kg stays the goal weight and
--    goal_type stays the phase (lose = cut, maintain, gain = bulk).
alter table public.profiles
  add column if not exists goal_date date,
  add column if not exists goal_started_on date,
  add column if not exists goal_start_weight_kg numeric(6,2),
  add column if not exists coach_enabled boolean not null default false,
  add column if not exists coach_intensity text not null default 'locked_in',
  add column if not exists coach_profanity text not null default 'mild',
  add column if not exists quiet_hours_start time not null default '23:00',
  add column if not exists quiet_hours_end time not null default '07:00',
  add column if not exists location_recs_enabled boolean not null default false,
  add column if not exists physique_ai_review_enabled boolean not null default false;

alter table public.profiles
  drop constraint if exists profiles_goal_dates_check,
  drop constraint if exists profiles_goal_start_weight_range_check,
  drop constraint if exists profiles_coach_intensity_check,
  drop constraint if exists profiles_coach_profanity_check,
  drop constraint if exists profiles_quiet_hours_check,
  add constraint profiles_goal_dates_check check (
    (goal_date is null or goal_date between date '2020-01-01' and date '2100-12-31')
    and (
      goal_started_on is null
      or goal_started_on between date '2020-01-01' and date '2100-12-31'
    )
    and (goal_date is null or goal_started_on is null or goal_started_on <= goal_date)
  ),
  add constraint profiles_goal_start_weight_range_check
    check (goal_start_weight_kg is null or goal_start_weight_kg between 20 and 500),
  add constraint profiles_coach_intensity_check
    check (coach_intensity in ('chill', 'locked_in', 'drill_sergeant')),
  add constraint profiles_coach_profanity_check
    check (coach_profanity in ('off', 'mild', 'salty')),
  add constraint profiles_quiet_hours_check
    check (quiet_hours_start <> quiet_hours_end);

-- 2. Coach job ledger: one fenced, leased, retry-bounded row per
--    (user, local_day, checkpoint_key). Never exposed to the Data API.
create table if not exists private.coach_runs (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  operation text not null,
  local_day date not null,
  checkpoint_key text not null,
  trigger_source text not null,
  status text not null default 'running',
  scheduled_for timestamptz not null default pg_catalog.now(),
  claim_token uuid not null default pg_catalog.gen_random_uuid(),
  generation_attempt smallint not null default 1,
  last_claimed_at timestamptz not null default pg_catalog.now(),
  lease_expires_at timestamptz default (pg_catalog.now() + interval '150 seconds'),
  input_fingerprint text,
  result jsonb not null default '{}'::jsonb,
  model text,
  provider_response_id text,
  error_message text,
  completed_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  constraint coach_runs_user_day_key_unique unique (user_id, local_day, checkpoint_key),
  constraint coach_runs_operation_check check (operation in (
    'coach_checkpoint', 'coach_reply', 'day_digest', 'activity_analysis',
    'body_review', 'nearby_research', 'training_plan'
  )),
  constraint coach_runs_checkpoint_key_check
    check (checkpoint_key ~ '^[a-z][a-z0-9_]{0,39}(:[A-Za-z0-9_-]{1,64})?$'),
  constraint coach_runs_trigger_source_check
    check (trigger_source in ('schedule', 'event', 'user', 'manual')),
  constraint coach_runs_status_check
    check (status in ('running', 'complete', 'skipped', 'failed')),
  constraint coach_runs_attempt_check check (generation_attempt between 1 and 3),
  constraint coach_runs_fingerprint_check check (
    input_fingerprint is null or char_length(input_fingerprint) between 1 and 128
  ),
  constraint coach_runs_result_check check (
    jsonb_typeof(result) = 'object' and octet_length(result::text) <= 32768
  ),
  constraint coach_runs_text_check check (
    (error_message is null or char_length(error_message) <= 500)
    and (model is null or char_length(model) <= 100)
    and (provider_response_id is null or char_length(provider_response_id) <= 200)
  ),
  constraint coach_runs_state_check check (
    (status = 'running' and lease_expires_at is not null and completed_at is null)
    or (
      status in ('complete', 'skipped')
      and lease_expires_at is null
      and completed_at is not null
    )
    or (status = 'failed' and lease_expires_at is null and completed_at is null)
  )
);

create index if not exists coach_runs_user_claimed_idx
  on private.coach_runs (user_id, last_claimed_at desc);
create index if not exists coach_runs_user_operation_day_idx
  on private.coach_runs (user_id, operation, local_day, created_at desc);
create index if not exists coach_runs_live_idx
  on private.coach_runs (user_id, lease_expires_at)
  where status = 'running';

alter table private.coach_runs enable row level security;
revoke all on table private.coach_runs from public, anon, authenticated, service_role;

drop trigger if exists coach_runs_set_updated_at on private.coach_runs;
create trigger coach_runs_set_updated_at
before update on private.coach_runs
for each row execute function private.set_updated_at();

-- 3. AI accounting. The four capture operations keep their exact caps and
--    their 180-per-24h pool. Coach operations get a separate 400-per-24h
--    pool, so neither workload can starve the other, plus a rolling project
--    spend breaker computed from the per-call ledger.
alter table private.ai_job_usage
  drop constraint if exists ai_job_usage_operation_check,
  add constraint ai_job_usage_operation_check check (operation in (
    'meal_analysis', 'onboarding', 'entry_correction', 'weekly_summary',
    'coach_checkpoint', 'coach_reply', 'day_digest', 'activity_analysis',
    'body_review', 'nearby_research', 'training_plan'
  ));

create table if not exists private.ai_provider_calls (
  id uuid primary key default pg_catalog.gen_random_uuid(),
  usage_id uuid references private.ai_job_usage(id) on delete set null,
  run_id uuid references private.coach_runs(id) on delete set null,
  user_id uuid references auth.users(id) on delete set null,
  operation text not null,
  workload text not null,
  model text not null,
  provider_request_id text,
  input_tokens integer not null default 0,
  output_tokens integer not null default 0,
  cache_read_tokens integer not null default 0,
  cache_write_tokens integer not null default 0,
  web_search_requests integer not null default 0,
  cost_usd_micros bigint not null default 0,
  pricing_version text not null,
  latency_ms integer,
  created_at timestamptz not null default pg_catalog.now(),
  constraint ai_provider_calls_operation_check check (operation in (
    'meal_analysis', 'onboarding', 'entry_correction', 'weekly_summary',
    'coach_checkpoint', 'coach_reply', 'day_digest', 'activity_analysis',
    'body_review', 'nearby_research', 'training_plan'
  )),
  constraint ai_provider_calls_workload_check
    check (workload ~ '^[a-z][a-z0-9_.:-]{0,63}$'),
  constraint ai_provider_calls_model_check
    check (char_length(model) between 1 and 100),
  constraint ai_provider_calls_request_id_check
    check (provider_request_id is null or char_length(provider_request_id) <= 200),
  constraint ai_provider_calls_tokens_check check (
    input_tokens >= 0 and output_tokens >= 0 and cache_read_tokens >= 0
    and cache_write_tokens >= 0 and web_search_requests between 0 and 1000
  ),
  constraint ai_provider_calls_cost_check
    check (cost_usd_micros between 0 and 100000000),
  constraint ai_provider_calls_pricing_check
    check (char_length(pricing_version) between 1 and 32),
  constraint ai_provider_calls_latency_check
    check (latency_ms is null or latency_ms between 0 and 3600000)
);

create index if not exists ai_provider_calls_created_idx
  on private.ai_provider_calls (created_at desc);
create index if not exists ai_provider_calls_operation_created_idx
  on private.ai_provider_calls (operation, created_at desc);
create index if not exists ai_provider_calls_usage_idx
  on private.ai_provider_calls (usage_id) where usage_id is not null;
create index if not exists ai_provider_calls_run_idx
  on private.ai_provider_calls (run_id) where run_id is not null;
create index if not exists ai_provider_calls_user_idx
  on private.ai_provider_calls (user_id) where user_id is not null;

alter table private.ai_provider_calls enable row level security;
revoke all on table private.ai_provider_calls
  from public, anon, authenticated, service_role;

create or replace function private.reserve_ai_job_usage(
  p_operation text,
  p_user_id uuid,
  p_request_key text,
  p_attempt smallint
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_operation text := pg_catalog.btrim(coalesce(p_operation, ''));
  normalized_request_key text := pg_catalog.btrim(coalesce(p_request_key, ''));
  capture_operations constant text[] := array[
    'meal_analysis', 'onboarding', 'entry_correction', 'weekly_summary'
  ];
  coach_operations constant text[] := array[
    'coach_checkpoint', 'coach_reply', 'day_digest', 'activity_analysis',
    'body_review', 'nearby_research', 'training_plan'
  ];
  operation_limit integer;
  pool text[];
  pool_limit integer;
  -- Rolling 24h project spend breaker for coach work ($25). Meal capture is
  -- bounded by its own counts and is never blocked by coach spend.
  coach_spend_cap_micros constant bigint := 25000000;
begin
  operation_limit := case normalized_operation
    when 'meal_analysis' then 100
    when 'onboarding' then 25
    when 'entry_correction' then 60
    when 'weekly_summary' then 25
    when 'coach_checkpoint' then 150
    when 'coach_reply' then 200
    when 'day_digest' then 12
    when 'activity_analysis' then 60
    when 'body_review' then 12
    when 'nearby_research' then 40
    when 'training_plan' then 12
    else null
  end;
  if operation_limit is null
    or p_user_id is null
    or char_length(normalized_request_key) not between 1 and 256
    or p_attempt not between 1 and 20 then
    raise exception using
      errcode = '22023', message = 'AI job reservation is invalid';
  end if;
  if normalized_operation = any(capture_operations) then
    pool := capture_operations;
    pool_limit := 180;
  else
    pool := coach_operations;
    pool_limit := 400;
  end if;

  -- Every project reservation shares one transaction lock. The ledger is tiny
  -- at beta scale, and serializing this decision prevents concurrent requests
  -- from crossing an operation cap, a pool cap, or the spend breaker.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shudo-project-ai-budget-v1', 0)
  );

  if exists (
    select 1
    from private.ai_job_usage as usage
    where usage.operation = normalized_operation
      and usage.user_id = p_user_id
      and usage.request_key = normalized_request_key
      and usage.attempt = p_attempt
  ) then
    return false;
  end if;

  if (
    select pg_catalog.count(*)
    from private.ai_job_usage as usage
    where usage.operation = any(pool)
      and usage.reserved_at >= pg_catalog.now() - interval '24 hours'
  ) >= pool_limit
    or (
      select pg_catalog.count(*)
      from private.ai_job_usage as usage
      where usage.operation = normalized_operation
        and usage.reserved_at >= pg_catalog.now() - interval '24 hours'
    ) >= operation_limit then
    raise exception using
      errcode = 'P0001', message = 'project_ai_budget_exceeded';
  end if;

  if pool = coach_operations and (
    select coalesce(pg_catalog.sum(call.cost_usd_micros), 0)
    from private.ai_provider_calls as call
    where call.created_at >= pg_catalog.now() - interval '24 hours'
  ) >= coach_spend_cap_micros then
    raise exception using
      errcode = 'P0001', message = 'project_ai_spend_exceeded';
  end if;

  insert into private.ai_job_usage (
    user_id,
    operation,
    request_key,
    attempt
  ) values (
    p_user_id,
    normalized_operation,
    normalized_request_key,
    p_attempt
  );
  return true;
end;
$$;

revoke all on function private.reserve_ai_job_usage(text, uuid, text, smallint)
  from public, anon, authenticated, service_role;

-- Every coach run attempt reserves exactly one AI job before it can commit.
create or replace function private.reserve_coach_run_ai_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT'
    or new.generation_attempt > old.generation_attempt then
    perform private.reserve_ai_job_usage(
      new.operation,
      new.user_id,
      new.local_day::text || ':' || new.checkpoint_key,
      new.generation_attempt
    );
  end if;
  return new;
end;
$$;

revoke all on function private.reserve_coach_run_ai_job()
  from public, anon, authenticated, service_role;

drop trigger if exists coach_runs_reserve_ai_job on private.coach_runs;
create trigger coach_runs_reserve_ai_job
after insert or update of generation_attempt on private.coach_runs
for each row execute function private.reserve_coach_run_ai_job();

-- 4. Activities: workouts and other movement, separate from meal entries.
--    Clients read and delete their own rows; inserts and analysis happen on
--    the server (log_activity, coach chat) under an activity_analysis run.
create table if not exists public.activities (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  client_request_id uuid not null,
  local_day date not null,
  occurred_at timestamptz not null default now(),
  timezone_snapshot text not null default 'UTC',
  status text not null default 'complete',
  source text not null default 'manual',
  kind text not null default 'other',
  title text not null,
  duration_min numeric(6,1),
  distance_km numeric(7,2),
  active_kcal numeric(7,1),
  avg_heart_rate smallint,
  intensity text,
  rpe numeric(3,1),
  details jsonb not null default '{}'::jsonb,
  input_text text,
  transcript text,
  speech_engine text,
  image_path text,
  source_message_id uuid,
  external_source text,
  external_id text,
  confidence numeric(4,3),
  analysis_model text,
  provider_response_id text,
  error_message text,
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint activities_user_request_unique unique (user_id, client_request_id),
  constraint activities_status_check
    check (status in ('processing', 'complete', 'failed')),
  constraint activities_source_check check (
    source in ('manual', 'text', 'voice', 'photo', 'coach_chat', 'healthkit')
  ),
  constraint activities_kind_check check (kind in (
    'strength', 'cardio', 'walk', 'run', 'cycle', 'swim', 'hiit', 'sport',
    'mobility', 'other'
  )),
  constraint activities_title_check
    check (char_length(btrim(title)) between 1 and 120),
  constraint activities_numbers_check check (
    (duration_min is null or duration_min between 0 and 1440)
    and (distance_km is null or distance_km between 0 and 1000)
    and (active_kcal is null or active_kcal between 0 and 10000)
    and (avg_heart_rate is null or avg_heart_rate between 30 and 230)
    and (rpe is null or rpe between 1 and 10)
    and (confidence is null or confidence between 0 and 1)
  ),
  constraint activities_intensity_check check (
    intensity is null or intensity in ('easy', 'moderate', 'hard', 'max')
  ),
  constraint activities_details_check check (
    jsonb_typeof(details) = 'object' and octet_length(details::text) <= 32768
  ),
  constraint activities_text_check check (
    (input_text is null or char_length(input_text) <= 4000)
    and (transcript is null or char_length(transcript) <= 8000)
    and (speech_engine is null or speech_engine ~ '^[a-z][a-z0-9_.]{0,63}$')
    and (error_message is null or char_length(error_message) <= 500)
    and (analysis_model is null or char_length(analysis_model) <= 100)
    and (provider_response_id is null or char_length(provider_response_id) <= 200)
  ),
  constraint activities_external_check check (
    (external_source is null) = (external_id is null)
    and (external_source is null or external_source = 'healthkit')
    and (external_id is null or char_length(external_id) between 1 and 128)
  ),
  constraint activities_image_path_owned_check check (
    image_path is null
    or (
      image_path ~ (
        '^' || user_id::text
        || '/[0-9]{4}-[0-9]{2}-[0-9]{2}/(activity|chat)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]jpg$'
      )
      and length(image_path) <= 160
    )
  )
);

create index if not exists activities_user_day_idx
  on public.activities (user_id, local_day desc, occurred_at desc);
create unique index if not exists activities_external_idx
  on public.activities (user_id, external_source, external_id)
  where external_id is not null;
create index if not exists activities_source_message_idx
  on public.activities (source_message_id)
  where source_message_id is not null;
create index if not exists activities_processing_idx
  on public.activities (user_id, updated_at)
  where status = 'processing';

drop trigger if exists activities_set_updated_at on public.activities;
create trigger activities_set_updated_at
before update on public.activities
for each row execute function private.set_updated_at();

-- 5. The coach thread. Visible rows are status <> 'superseded' and
--    deliver_at <= now(). Scheduled rows feed local notifications; a later
--    plan supersedes a still-future slot instead of stacking a second nudge.
create table if not exists public.coach_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null,
  kind text not null,
  body text not null default '',
  payload jsonb not null default '{}'::jsonb,
  local_day date not null,
  deliver_at timestamptz not null default now(),
  status text not null default 'delivered',
  notify boolean not null default false,
  checkpoint_key text,
  slot_key text,
  run_id uuid references private.coach_runs(id) on delete set null,
  dedupe_key text,
  client_request_id uuid,
  reply_to_id uuid references public.coach_messages(id) on delete set null,
  entry_id uuid references public.entries(id) on delete set null,
  activity_id uuid references public.activities(id) on delete set null,
  attachment_path text,
  model text,
  read_at timestamptz,
  superseded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint coach_messages_role_check
    check (role in ('coach', 'user', 'system_event')),
  constraint coach_messages_kind_check check (
    (
      role = 'coach'
      and kind in (
        'text', 'checkpoint', 'plan', 'snack_rec', 'meal_ack', 'workout_ack',
        'weigh_in_ack', 'photo_feedback', 'recap', 'profile_update',
        'training_plan', 'goal_change'
      )
    )
    or (role = 'user' and kind in ('text', 'photo'))
    or (role = 'system_event' and kind = 'event')
  ),
  -- Text bubbles need text. Cards and photos may be payload-only, a coach
  -- reply may be empty while its first tokens stream, and hidden rows are
  -- exempt.
  constraint coach_messages_body_check check (
    char_length(body) <= case when role = 'user' then 4000 else 6000 end
    and (
      char_length(btrim(body)) >= 1
      or kind not in ('text', 'checkpoint', 'event')
      or status = 'superseded'
      or (role = 'coach' and payload->>'streaming' = 'true')
    )
  ),
  -- The lock-screen text is payload.push_body, never longer than 150.
  constraint coach_messages_payload_check check (
    jsonb_typeof(payload) = 'object'
    and octet_length(payload::text) <= 32768
    and (
      not (payload ? 'push_body')
      or jsonb_typeof(payload->'push_body') = 'null'
      or (
        jsonb_typeof(payload->'push_body') = 'string'
        and char_length(payload->>'push_body') between 1 and 150
      )
    )
  ),
  constraint coach_messages_status_check
    check (status in ('scheduled', 'delivered', 'superseded')),
  constraint coach_messages_supersede_state_check
    check ((status = 'superseded') = (superseded_at is not null)),
  constraint coach_messages_user_shape_check check (
    (
      role = 'user'
      and client_request_id is not null
      and status = 'delivered'
      and run_id is null
      and slot_key is null
      and notify = false
    )
    or (role <> 'user' and client_request_id is null and attachment_path is null)
  ),
  constraint coach_messages_photo_check
    check ((kind = 'photo') = (attachment_path is not null)),
  constraint coach_messages_keys_check check (
    (
      checkpoint_key is null
      or checkpoint_key ~ '^[a-z][a-z0-9_]{0,39}(:[A-Za-z0-9_-]{1,64})?$'
    )
    and (slot_key is null or slot_key ~ '^[a-z][a-z0-9_]{0,39}$')
    and (dedupe_key is null or char_length(dedupe_key) between 1 and 128)
    and (model is null or char_length(model) <= 100)
  ),
  constraint coach_messages_attachment_path_check check (
    attachment_path is null
    or (
      attachment_path ~ (
        '^' || user_id::text
        || '/[0-9]{4}-[0-9]{2}-[0-9]{2}/chat-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]jpg$'
      )
      and length(attachment_path) <= 160
    )
  )
);

create index if not exists coach_messages_thread_idx
  on public.coach_messages (user_id, deliver_at desc, id desc)
  where status <> 'superseded';
create index if not exists coach_messages_user_day_idx
  on public.coach_messages (user_id, local_day, deliver_at);
create index if not exists coach_messages_sync_idx
  on public.coach_messages (user_id, updated_at);
create index if not exists coach_messages_scheduled_idx
  on public.coach_messages (deliver_at, user_id)
  where status = 'scheduled';
create index if not exists coach_messages_unread_idx
  on public.coach_messages (user_id, deliver_at)
  where read_at is null and role = 'coach' and status <> 'superseded';
create unique index if not exists coach_messages_user_request_idx
  on public.coach_messages (user_id, client_request_id)
  where client_request_id is not null;
create unique index if not exists coach_messages_dedupe_idx
  on public.coach_messages (user_id, dedupe_key)
  where dedupe_key is not null;
create unique index if not exists coach_messages_live_slot_idx
  on public.coach_messages (user_id, local_day, slot_key)
  where status = 'scheduled' and slot_key is not null;
create index if not exists coach_messages_run_idx
  on public.coach_messages (run_id) where run_id is not null;
create index if not exists coach_messages_reply_idx
  on public.coach_messages (reply_to_id) where reply_to_id is not null;
create index if not exists coach_messages_entry_idx
  on public.coach_messages (entry_id) where entry_id is not null;
create index if not exists coach_messages_activity_idx
  on public.coach_messages (activity_id) where activity_id is not null;

alter table public.activities
  drop constraint if exists activities_source_message_fk;
alter table public.activities
  add constraint activities_source_message_fk foreign key (source_message_id)
  references public.coach_messages(id) on delete set null;

drop trigger if exists coach_messages_set_updated_at on public.coach_messages;
create trigger coach_messages_set_updated_at
before update on public.coach_messages
for each row execute function private.set_updated_at();

-- Only links that are set or changed are checked, so foreign-key cascades
-- (which null one column at a time) never re-validate the others.
create or replace function private.enforce_coach_message_links()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  is_insert constant boolean := tg_op = 'INSERT';
begin
  if (
    new.entry_id is not null
    and (is_insert or new.entry_id is distinct from old.entry_id)
    and not exists (
      select 1 from public.entries as entry
      where entry.id = new.entry_id and entry.user_id = new.user_id
    )
  ) or (
    new.activity_id is not null
    and (is_insert or new.activity_id is distinct from old.activity_id)
    and not exists (
      select 1 from public.activities as activity
      where activity.id = new.activity_id and activity.user_id = new.user_id
    )
  ) or (
    new.reply_to_id is not null
    and (is_insert or new.reply_to_id is distinct from old.reply_to_id)
    and not exists (
      select 1 from public.coach_messages as parent
      where parent.id = new.reply_to_id and parent.user_id = new.user_id
    )
  ) or (
    new.run_id is not null
    and (is_insert or new.run_id is distinct from old.run_id)
    and not exists (
      select 1 from private.coach_runs as run
      where run.id = new.run_id and run.user_id = new.user_id
    )
  ) then
    raise exception using
      errcode = '23503', message = 'coach_message_link_not_owned';
  end if;
  return new;
end;
$$;

revoke all on function private.enforce_coach_message_links()
  from public, anon, authenticated, service_role;

drop trigger if exists coach_messages_enforce_links on public.coach_messages;
create trigger coach_messages_enforce_links
before insert or update of entry_id, activity_id, reply_to_id, run_id
on public.coach_messages
for each row execute function private.enforce_coach_message_links();

-- read_at is the only client-writable column: monotonic and never in the
-- future, so a client can mark a message read but never unread it.
create or replace function private.guard_coach_message_read()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.read_at is not null then
    new.read_at := old.read_at;
  elsif new.read_at is not null then
    new.read_at := least(new.read_at, pg_catalog.now());
  end if;
  return new;
end;
$$;

revoke all on function private.guard_coach_message_read()
  from public, anon, authenticated, service_role;

drop trigger if exists coach_messages_guard_read on public.coach_messages;
create trigger coach_messages_guard_read
before update of read_at on public.coach_messages
for each row execute function private.guard_coach_message_read();

alter table public.coach_messages enable row level security;

drop policy if exists coach_messages_select_own on public.coach_messages;
create policy coach_messages_select_own on public.coach_messages
for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists coach_messages_mark_read_own on public.coach_messages;
create policy coach_messages_mark_read_own on public.coach_messages
for update to authenticated
using (
  (select auth.uid()) = user_id
  and status <> 'superseded'
  and deliver_at <= pg_catalog.now()
)
with check ((select auth.uid()) = user_id);

revoke all on public.coach_messages from public, anon, authenticated, service_role;
grant select on public.coach_messages to authenticated;
grant update (read_at) on public.coach_messages to authenticated;
grant select, insert, update, delete on public.coach_messages to service_role;

do $$
begin
  if exists (
    select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime'
  ) and not exists (
    select 1
    from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'coach_messages'
  ) then
    alter publication supabase_realtime add table public.coach_messages;
  end if;
end;
$$;

-- Activities link back to the chat message that created them, and their
-- photos are server-managed coach-media objects cleaned up durably.
create or replace function private.enforce_activity_capture()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.source_message_id is not null
    and (tg_op = 'INSERT' or new.source_message_id is distinct from old.source_message_id)
    and not exists (
      select 1
      from public.coach_messages as message_row
      where message_row.id = new.source_message_id
        and message_row.user_id = new.user_id
    ) then
    raise exception using
      errcode = '23503', message = 'activity_message_link_not_owned';
  end if;
  if tg_op <> 'INSERT' then
    return new;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shudo-activity:' || new.user_id::text, 0)
  );
  if exists (
    select 1
    from public.activities as activity
    where activity.user_id = new.user_id
      and activity.client_request_id = new.client_request_id
  ) then
    -- The unique constraint reports the duplicate; callers treat it as a
    -- replay of the same capture.
    return new;
  end if;
  if (
    select pg_catalog.count(*)
    from public.activities as activity
    where activity.user_id = new.user_id
      and activity.created_at >= pg_catalog.now() - interval '24 hours'
  ) >= 40 then
    raise exception using
      errcode = 'P0001', message = 'activity_daily_quota_exceeded';
  end if;
  if new.status = 'processing' and (
    select pg_catalog.count(*)
    from public.activities as activity
    where activity.user_id = new.user_id
      and activity.status = 'processing'
  ) >= 3 then
    raise exception using
      errcode = 'P0001', message = 'activity_concurrency_quota_exceeded';
  end if;
  return new;
end;
$$;

revoke all on function private.enforce_activity_capture()
  from public, anon, authenticated, service_role;

drop trigger if exists activities_enforce_capture on public.activities;
create trigger activities_enforce_capture
before insert or update of source_message_id on public.activities
for each row execute function private.enforce_activity_capture();

alter table private.storage_cleanup_jobs
  drop constraint if exists storage_cleanup_jobs_bucket_check,
  add constraint storage_cleanup_jobs_bucket_check check (
    bucket in ('entry-images', 'entry-audio', 'weight-checkin-photos', 'coach-media')
  );

create or replace function private.enqueue_storage_cleanup_job(
  p_bucket text,
  p_mode text,
  p_object_path text,
  p_not_before timestamptz default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  queued_id uuid;
begin
  if p_bucket not in (
    'entry-images', 'entry-audio', 'weight-checkin-photos', 'coach-media'
  ) then
    raise exception using
      errcode = '22023',
      message = 'Unsupported Storage cleanup bucket';
  end if;
  if p_mode not in ('object', 'prefix') then
    raise exception using
      errcode = '22023',
      message = 'Unsupported Storage cleanup mode';
  end if;
  if p_object_path is null
    or p_object_path = ''
    or p_object_path <> btrim(p_object_path)
    or left(p_object_path, 1) = '/'
    or p_object_path ~ '(^|/)\.\.(/|$)'
    or (p_mode = 'prefix' and right(p_object_path, 1) <> '/')
    or (p_mode = 'object' and right(p_object_path, 1) = '/') then
    raise exception using
      errcode = '22023',
      message = 'Invalid Storage cleanup path';
  end if;

  insert into private.storage_cleanup_jobs as cleanup_job (
    bucket,
    mode,
    object_path,
    not_before
  )
  values (
    p_bucket,
    p_mode,
    p_object_path,
    coalesce(p_not_before, now())
  )
  on conflict (bucket, mode, object_path) do update
  set not_before = least(cleanup_job.not_before, excluded.not_before),
      updated_at = now()
  returning cleanup_job.id into queued_id;

  return queued_id;
end;
$$;

revoke all on function private.enqueue_storage_cleanup_job(text, text, text, timestamptz)
  from public, anon, authenticated, service_role;

create or replace function private.enqueue_activity_media_cleanup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if old.image_path is not null then
      perform private.enqueue_storage_cleanup_job(
        'coach-media', 'object', old.image_path, pg_catalog.now()
      );
    end if;
  elsif old.image_path is not null
    and new.image_path is distinct from old.image_path then
    perform private.enqueue_storage_cleanup_job(
      'coach-media', 'object', old.image_path, pg_catalog.now()
    );
  end if;
  return null;
end;
$$;

revoke all on function private.enqueue_activity_media_cleanup()
  from public, anon, authenticated, service_role;

drop trigger if exists activities_enqueue_media_cleanup on public.activities;
create trigger activities_enqueue_media_cleanup
after delete or update of image_path on public.activities
for each row execute function private.enqueue_activity_media_cleanup();

alter table public.activities enable row level security;

drop policy if exists activities_select_own on public.activities;
create policy activities_select_own on public.activities
for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists activities_delete_own on public.activities;
create policy activities_delete_own on public.activities
for delete to authenticated
using ((select auth.uid()) = user_id and status <> 'processing');

revoke all on public.activities from public, anon, authenticated, service_role;
grant select, delete on public.activities to authenticated;
grant select, insert, update, delete on public.activities to service_role;

-- 6. Living coach memory (bio + coach notes) with append-only revisions,
--    and nightly day digests carrying tomorrow's game plan.
create table if not exists public.coach_memory (
  user_id uuid primary key references auth.users(id) on delete cascade,
  version integer not null default 1,
  document text not null,
  sections jsonb not null default '{}'::jsonb,
  updated_source text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint coach_memory_version_check check (version >= 1),
  constraint coach_memory_document_check
    check (char_length(btrim(document)) between 1 and 24000),
  constraint coach_memory_sections_check check (
    jsonb_typeof(sections) = 'object'
    and octet_length(sections::text) <= 65536
    and (not (sections ? 'bio') or jsonb_typeof(sections->'bio') = 'object')
    and (not (sections ? 'notes') or jsonb_typeof(sections->'notes') = 'object')
    and (not (sections ? 'schedule') or jsonb_typeof(sections->'schedule') = 'object')
    and (not (sections ? 'equipment') or jsonb_typeof(sections->'equipment') = 'array')
  ),
  constraint coach_memory_source_check check (updated_source in (
    'seed', 'onboarding', 'coach_reply', 'bio_update', 'day_digest', 'weekly',
    'manual', 'undo'
  ))
);

create table if not exists public.coach_memory_revisions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  version integer not null,
  document text not null,
  sections jsonb not null,
  source text not null,
  change_summary text,
  run_id uuid references private.coach_runs(id) on delete set null,
  coach_message_id uuid references public.coach_messages(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint coach_memory_revisions_user_version_unique unique (user_id, version),
  constraint coach_memory_revisions_version_check check (version >= 1),
  constraint coach_memory_revisions_source_check check (source in (
    'seed', 'onboarding', 'coach_reply', 'bio_update', 'day_digest', 'weekly',
    'manual', 'undo'
  )),
  constraint coach_memory_revisions_summary_check
    check (change_summary is null or char_length(change_summary) <= 1000)
);

create index if not exists coach_memory_revisions_run_idx
  on public.coach_memory_revisions (run_id) where run_id is not null;
create index if not exists coach_memory_revisions_message_idx
  on public.coach_memory_revisions (coach_message_id)
  where coach_message_id is not null;

drop trigger if exists coach_memory_set_updated_at on public.coach_memory;
create trigger coach_memory_set_updated_at
before update on public.coach_memory
for each row execute function private.set_updated_at();

create table if not exists public.day_digests (
  user_id uuid not null references auth.users(id) on delete cascade,
  local_day date not null,
  headline text not null,
  summary text not null,
  metrics jsonb not null default '{}'::jsonb,
  highlights jsonb not null default '[]'::jsonb,
  misses jsonb not null default '[]'::jsonb,
  tomorrow_focus jsonb not null default '[]'::jsonb,
  game_plan jsonb not null default '{}'::jsonb,
  score smallint,
  input_fingerprint text not null,
  digest_version smallint not null default 1,
  model text not null,
  provider_response_id text,
  run_id uuid references private.coach_runs(id) on delete set null,
  generated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, local_day),
  constraint day_digests_text_check check (
    char_length(btrim(headline)) between 1 and 160
    and char_length(btrim(summary)) between 1 and 6000
    and char_length(model) between 1 and 100
    and char_length(input_fingerprint) between 1 and 128
    and (provider_response_id is null or char_length(provider_response_id) <= 200)
  ),
  constraint day_digests_json_check check (
    jsonb_typeof(metrics) = 'object'
    and jsonb_typeof(highlights) = 'array'
    and jsonb_typeof(misses) = 'array'
    and jsonb_typeof(tomorrow_focus) = 'array'
    and jsonb_typeof(game_plan) = 'object'
    and octet_length(metrics::text) + octet_length(highlights::text)
      + octet_length(misses::text) + octet_length(tomorrow_focus::text)
      + octet_length(game_plan::text) <= 49152
  ),
  constraint day_digests_score_check check (score is null or score between 0 and 100),
  constraint day_digests_version_check check (digest_version between 1 and 20)
);

create index if not exists day_digests_run_idx
  on public.day_digests (run_id) where run_id is not null;

drop trigger if exists day_digests_set_updated_at on public.day_digests;
create trigger day_digests_set_updated_at
before update on public.day_digests
for each row execute function private.set_updated_at();

alter table public.coach_memory enable row level security;
alter table public.coach_memory_revisions enable row level security;
alter table public.day_digests enable row level security;

drop policy if exists coach_memory_select_own on public.coach_memory;
create policy coach_memory_select_own on public.coach_memory
for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists coach_memory_revisions_select_own
  on public.coach_memory_revisions;
create policy coach_memory_revisions_select_own on public.coach_memory_revisions
for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists day_digests_select_own on public.day_digests;
create policy day_digests_select_own on public.day_digests
for select to authenticated
using ((select auth.uid()) = user_id);

revoke all on public.coach_memory, public.coach_memory_revisions, public.day_digests
  from public, anon, authenticated, service_role;
grant select on public.coach_memory, public.coach_memory_revisions, public.day_digests
  to authenticated;
grant select, insert, update, delete on public.coach_memory,
  public.coach_memory_revisions, public.day_digests to service_role;

-- 7. Training plans: at most one active and one draft plan per user.
--    Drafts are proposed by the coach and activated only by Luke's tap.
create table if not exists public.training_plans (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'draft',
  plan jsonb not null,
  rationale text,
  change_summary text,
  source text not null default 'coach',
  model text,
  run_id uuid references private.coach_runs(id) on delete set null,
  created_at timestamptz not null default now(),
  activated_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint training_plans_status_check
    check (status in ('draft', 'active', 'superseded', 'rejected')),
  constraint training_plans_source_check
    check (source in ('coach', 'weekly', 'manual')),
  constraint training_plans_plan_check check (
    jsonb_typeof(plan) = 'object'
    and plan->'version' = '1'::jsonb
    and jsonb_typeof(plan->'name') = 'string'
    and jsonb_typeof(plan->'sessions') = 'array'
    and octet_length(plan::text) <= 65536
  ),
  constraint training_plans_text_check check (
    (rationale is null or char_length(rationale) <= 4000)
    and (change_summary is null or char_length(change_summary) <= 2000)
    and (model is null or char_length(model) <= 100)
  ),
  constraint training_plans_activation_check
    check (status <> 'active' or activated_at is not null)
);

create unique index if not exists training_plans_one_active_idx
  on public.training_plans (user_id) where status = 'active';
create unique index if not exists training_plans_one_draft_idx
  on public.training_plans (user_id) where status = 'draft';
create index if not exists training_plans_user_created_idx
  on public.training_plans (user_id, created_at desc);
create index if not exists training_plans_run_idx
  on public.training_plans (run_id) where run_id is not null;

drop trigger if exists training_plans_set_updated_at on public.training_plans;
create trigger training_plans_set_updated_at
before update on public.training_plans
for each row execute function private.set_updated_at();

alter table public.training_plans enable row level security;

drop policy if exists training_plans_select_own on public.training_plans;
create policy training_plans_select_own on public.training_plans
for select to authenticated
using ((select auth.uid()) = user_id);

revoke all on public.training_plans from public, anon, authenticated, service_role;
grant select on public.training_plans to authenticated;
grant select, insert, update, delete on public.training_plans to service_role;

-- 8. Body check-ins: same table and private bucket; photo-only days are
--    allowed because there is no scale yet. Coach review columns are written
--    only by the server, enforced through column-level grants.
alter table public.weight_checkins
  alter column weight_kg drop not null,
  add column if not exists note text,
  add column if not exists photo_pose text,
  add column if not exists photo_captured_at timestamptz,
  add column if not exists body_fat_pct numeric(4,1),
  add column if not exists waist_cm numeric(5,1),
  add column if not exists coach_review jsonb,
  add column if not exists coach_reviewed_photo_path text,
  add column if not exists coach_review_model text,
  add column if not exists coach_reviewed_at timestamptz;

alter table public.weight_checkins
  drop constraint if exists weight_checkins_observation_check,
  drop constraint if exists weight_checkins_note_check,
  drop constraint if exists weight_checkins_photo_pose_check,
  drop constraint if exists weight_checkins_body_metrics_check,
  drop constraint if exists weight_checkins_coach_review_check,
  add constraint weight_checkins_observation_check
    check (weight_kg is not null or progress_photo_path is not null),
  add constraint weight_checkins_note_check
    check (note is null or char_length(btrim(note)) between 1 and 1000),
  add constraint weight_checkins_photo_pose_check check (
    photo_pose is null
    or photo_pose in ('front', 'front_relaxed', 'front_flexed', 'side', 'back', 'other')
  ),
  add constraint weight_checkins_body_metrics_check check (
    (body_fat_pct is null or body_fat_pct between 2 and 70)
    and (waist_cm is null or waist_cm between 40 and 250)
  ),
  add constraint weight_checkins_coach_review_check check (
    (
      coach_review is null
      and coach_reviewed_at is null
      and coach_reviewed_photo_path is null
    )
    or (
      jsonb_typeof(coach_review) = 'object'
      and octet_length(coach_review::text) <= 16384
      and coach_reviewed_at is not null
      and coach_reviewed_photo_path is not null
      and (coach_review_model is null or char_length(coach_review_model) <= 100)
    )
  );

revoke insert, update on public.weight_checkins from authenticated;
grant insert (
  user_id, local_day, weight_kg, progress_photo_path, note, photo_pose,
  photo_captured_at, body_fat_pct, waist_cm
) on public.weight_checkins to authenticated;
grant update (
  user_id, local_day, weight_kg, progress_photo_path, note, photo_pose,
  photo_captured_at, body_fat_pct, waist_cm
) on public.weight_checkins to authenticated;

-- 9. Device context: the latest snapshot per device. Coarse (~110 m)
--    coordinates only, the last nearby-store list without coordinates, and a
--    future APNs token. There is no location history.
create table if not exists public.device_snapshots (
  user_id uuid not null references auth.users(id) on delete cascade,
  device_id uuid not null,
  platform text not null default 'ios',
  app_version text,
  os_version text,
  timezone text not null,
  locale text,
  notification_status text not null default 'not_determined',
  apns_token text,
  apns_environment text,
  location_status text not null default 'not_determined',
  coarse_latitude numeric(6,3),
  coarse_longitude numeric(6,3),
  location_accuracy_m integer,
  neighborhood text,
  city text,
  region text,
  country_code text,
  location_captured_at timestamptz,
  nearby jsonb not null default '[]'::jsonb,
  nearby_captured_at timestamptz,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, device_id),
  constraint device_snapshots_platform_check check (platform in ('ios', 'web')),
  constraint device_snapshots_text_check check (
    (app_version is null or char_length(app_version) <= 32)
    and (os_version is null or char_length(os_version) <= 32)
    and (locale is null or char_length(locale) <= 35)
  ),
  constraint device_snapshots_notification_check check (notification_status in (
    'not_determined', 'denied', 'authorized', 'provisional', 'ephemeral'
  )),
  constraint device_snapshots_apns_check check (
    (apns_token is null) = (apns_environment is null)
    and (apns_token is null or apns_token ~ '^[0-9a-f]{64,200}$')
    and (apns_environment is null or apns_environment in ('sandbox', 'production'))
  ),
  constraint device_snapshots_location_status_check check (location_status in (
    'not_determined', 'denied', 'restricted', 'when_in_use', 'always'
  )),
  constraint device_snapshots_location_check check (
    (coarse_latitude is null) = (coarse_longitude is null)
    and (coarse_latitude is null or location_captured_at is not null)
    and (coarse_latitude is null or coarse_latitude between -90 and 90)
    and (coarse_longitude is null or coarse_longitude between -180 and 180)
    and (location_accuracy_m is null or location_accuracy_m between 0 and 100000)
  ),
  constraint device_snapshots_place_check check (
    (neighborhood is null or char_length(neighborhood) between 1 and 120)
    and (city is null or char_length(city) between 1 and 120)
    and (region is null or char_length(region) between 1 and 120)
    and (country_code is null or country_code ~ '^[A-Z]{2}$')
  ),
  -- The nearby list is names, categories, and walking distances only. Any
  -- coordinate-looking key is rejected so precise location never lands here.
  constraint device_snapshots_nearby_check check (
    case
      when jsonb_typeof(nearby) = 'array' then
        jsonb_array_length(nearby) <= 24
        and octet_length(nearby::text) <= 16384
        and nearby::text !~* '"(lat|lng|lon|latitude|longitude|coordinates?)"[[:space:]]*:'
      else false
    end
  )
);

drop trigger if exists device_snapshots_set_updated_at on public.device_snapshots;
create trigger device_snapshots_set_updated_at
before update on public.device_snapshots
for each row execute function private.set_updated_at();

drop trigger if exists device_snapshots_enforce_timezone on public.device_snapshots;
create trigger device_snapshots_enforce_timezone
before insert or update of timezone on public.device_snapshots
for each row execute function private.enforce_profile_timezone();

alter table public.device_snapshots enable row level security;

drop policy if exists device_snapshots_select_own on public.device_snapshots;
create policy device_snapshots_select_own on public.device_snapshots
for select to authenticated
using ((select auth.uid()) = user_id);

drop policy if exists device_snapshots_insert_own on public.device_snapshots;
create policy device_snapshots_insert_own on public.device_snapshots
for insert to authenticated
with check ((select auth.uid()) = user_id);

drop policy if exists device_snapshots_update_own on public.device_snapshots;
create policy device_snapshots_update_own on public.device_snapshots
for update to authenticated
using ((select auth.uid()) = user_id)
with check ((select auth.uid()) = user_id);

drop policy if exists device_snapshots_delete_own on public.device_snapshots;
create policy device_snapshots_delete_own on public.device_snapshots
for delete to authenticated
using ((select auth.uid()) = user_id);

revoke all on public.device_snapshots from public, anon, authenticated, service_role;
grant select, delete on public.device_snapshots to authenticated;
grant insert (
  user_id, device_id, platform, app_version, os_version, timezone, locale,
  notification_status, apns_token, apns_environment, location_status,
  coarse_latitude, coarse_longitude, location_accuracy_m, neighborhood, city,
  region, country_code, location_captured_at, nearby, nearby_captured_at,
  last_seen_at
) on public.device_snapshots to authenticated;
grant update (
  user_id, device_id, platform, app_version, os_version, timezone, locale,
  notification_status, apns_token, apns_environment, location_status,
  coarse_latitude, coarse_longitude, location_accuracy_m, neighborhood, city,
  region, country_code, location_captured_at, nearby, nearby_captured_at,
  last_seen_at
) on public.device_snapshots to authenticated;
grant select, insert, update, delete on public.device_snapshots to service_role;

-- 10. Storage: private coach-media for chat and workout photos. Clients may
--     upload and read their own dated objects; deletion is server-managed.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('coach-media', 'coach-media', false, 6291456, array['image/jpeg'])
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists coach_media_select_own on storage.objects;
create policy coach_media_select_own on storage.objects
for select to authenticated
using (
  bucket_id = 'coach-media'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and name ~ (
    '^' || (select auth.uid())::text
    || '/[0-9]{4}-[0-9]{2}-[0-9]{2}/(activity|chat)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]jpg$'
  )
);

drop policy if exists coach_media_insert_own on storage.objects;
create policy coach_media_insert_own on storage.objects
for insert to authenticated
with check (
  bucket_id = 'coach-media'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and name ~ (
    '^' || (select auth.uid())::text
    || '/[0-9]{4}-[0-9]{2}-[0-9]{2}/(activity|chat)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[.]jpg$'
  )
);

-- 11. Service-role RPCs. None is callable by anon or authenticated; every
--     model output is written under a (run_id, claim_token) fence so a worker
--     that lost its lease can never post.

-- Shared fence check. A null token only proves provenance (the run belongs to
-- the user); a token additionally requires the live claim.
create or replace function private.coach_run_matches(
  p_run_id uuid,
  p_claim_token uuid,
  p_user_id uuid,
  p_operation text default null
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from private.coach_runs as run
    where run.id = p_run_id
      and run.user_id = p_user_id
      and (p_operation is null or run.operation = p_operation)
      and (
        p_claim_token is null
        or (run.claim_token = p_claim_token and run.status = 'running')
      )
  );
$$;

revoke all on function private.coach_run_matches(uuid, uuid, uuid, text)
  from public, anon, authenticated, service_role;

create or replace function public.claim_coach_run(
  p_user_id uuid,
  p_operation text,
  p_local_day date,
  p_checkpoint_key text,
  p_trigger_source text default 'event',
  p_scheduled_for timestamptz default null,
  p_input_fingerprint text default null,
  p_lease_seconds integer default 150
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing private.coach_runs%rowtype;
  claimed private.coach_runs%rowtype;
  normalized_key text := pg_catalog.btrim(coalesce(p_checkpoint_key, ''));
  key_suffix text;
begin
  if p_user_id is null or p_local_day is null then
    raise exception using
      errcode = '22023', message = 'Coach run identifiers are required';
  end if;
  if p_operation is null or p_operation not in (
    'coach_checkpoint', 'coach_reply', 'day_digest', 'activity_analysis',
    'body_review', 'nearby_research', 'training_plan'
  ) then
    raise exception using
      errcode = '22023', message = 'Coach run operation is invalid';
  end if;
  if p_trigger_source is null
    or p_trigger_source not in ('schedule', 'event', 'user', 'manual') then
    raise exception using
      errcode = '22023', message = 'Coach run trigger is invalid';
  end if;

  -- UUID suffixes are stored lowercase so an uppercase client UUID and the
  -- server's uuid::text always resolve to the same run.
  key_suffix := pg_catalog.split_part(normalized_key, ':', 2);
  if key_suffix ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    normalized_key := pg_catalog.split_part(normalized_key, ':', 1)
      || ':' || pg_catalog.lower(key_suffix);
  end if;
  if normalized_key !~ '^[a-z][a-z0-9_]{0,39}(:[A-Za-z0-9_-]{1,64})?$'
    or (
      p_operation = 'coach_reply'
      and normalized_key !~ '^reply:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    )
    or (
      p_operation = 'activity_analysis'
      and normalized_key !~ '^activity:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    )
    or (p_operation = 'day_digest' and normalized_key <> 'digest') then
    raise exception using
      errcode = '22023', message = 'Coach checkpoint key is invalid';
  end if;
  if p_lease_seconds is null or p_lease_seconds not between 30 and 400 then
    raise exception using
      errcode = '22023', message = 'Coach lease must be 30 to 400 seconds';
  end if;
  if p_input_fingerprint is not null
    and char_length(p_input_fingerprint) not between 1 and 128 then
    raise exception using
      errcode = '22023', message = 'Coach fingerprint is invalid';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shudo-coach-run:' || p_user_id::text, 0)
  );

  -- Privacy gates live in SQL: proactive work needs the coach switched on,
  -- and physique photos reach a model only after an explicit opt-in.
  if p_operation in ('coach_checkpoint', 'day_digest') and not exists (
    select 1 from public.profiles as profile
    where profile.user_id = p_user_id and profile.coach_enabled
  ) then
    return pg_catalog.jsonb_build_object('status', 'disabled');
  end if;
  if p_operation = 'body_review' and not exists (
    select 1 from public.profiles as profile
    where profile.user_id = p_user_id and profile.physique_ai_review_enabled
  ) then
    return pg_catalog.jsonb_build_object('status', 'disabled');
  end if;

  select run.* into existing
  from private.coach_runs as run
  where run.user_id = p_user_id
    and run.local_day = p_local_day
    and run.checkpoint_key = normalized_key
  for update of run;

  begin
    if found then
      if existing.operation <> p_operation then
        return pg_catalog.jsonb_build_object(
          'status', 'conflict', 'run_id', existing.id,
          'checkpoint_key', normalized_key
        );
      end if;
      if existing.status in ('complete', 'skipped') then
        return pg_catalog.jsonb_build_object(
          'status', existing.status, 'run_id', existing.id,
          'checkpoint_key', normalized_key,
          'generation_attempt', existing.generation_attempt
        );
      end if;
      if existing.status = 'running'
        and existing.lease_expires_at > pg_catalog.now() then
        return pg_catalog.jsonb_build_object(
          'status', 'running', 'run_id', existing.id,
          'checkpoint_key', normalized_key,
          'generation_attempt', existing.generation_attempt,
          'lease_expires_at', existing.lease_expires_at
        );
      end if;
      if existing.generation_attempt >= 3
        or existing.result->>'terminal' = 'true' then
        update private.coach_runs
        set status = 'failed',
            lease_expires_at = null,
            completed_at = null,
            error_message = coalesce(error_message, 'Coach run retry limit reached')
        where id = existing.id and status = 'running';
        return pg_catalog.jsonb_build_object(
          'status', 'exhausted', 'run_id', existing.id,
          'checkpoint_key', normalized_key,
          'generation_attempt', existing.generation_attempt
        );
      end if;

      update private.coach_runs as run
      set status = 'running',
          generation_attempt = run.generation_attempt + 1,
          claim_token = pg_catalog.gen_random_uuid(),
          trigger_source = p_trigger_source,
          scheduled_for = coalesce(p_scheduled_for, run.scheduled_for),
          last_claimed_at = pg_catalog.now(),
          lease_expires_at = pg_catalog.now()
            + pg_catalog.make_interval(secs => p_lease_seconds),
          input_fingerprint = coalesce(p_input_fingerprint, run.input_fingerprint),
          result = '{}'::jsonb,
          error_message = null,
          completed_at = null
      where run.id = existing.id
      returning run.* into claimed;

      -- A run's visible output comes from exactly one attempt: hide anything
      -- an earlier attempt managed to post or stream before it died.
      update public.coach_messages
      set status = 'superseded',
          superseded_at = pg_catalog.now()
      where run_id = claimed.id and status <> 'superseded';

      return pg_catalog.jsonb_build_object(
        'status', 'reclaimed', 'run_id', claimed.id,
        'claim_token', claimed.claim_token,
        'checkpoint_key', claimed.checkpoint_key,
        'generation_attempt', claimed.generation_attempt,
        'lease_expires_at', claimed.lease_expires_at
      );
    end if;

    if (
      select pg_catalog.count(*)
      from private.coach_runs as run
      where run.user_id = p_user_id
        and run.status = 'running'
        and run.lease_expires_at > pg_catalog.now()
    ) >= 4 then
      return pg_catalog.jsonb_build_object('status', 'capacity');
    end if;

    insert into private.coach_runs (
      user_id, operation, local_day, checkpoint_key, trigger_source,
      scheduled_for, input_fingerprint, lease_expires_at
    ) values (
      p_user_id, p_operation, p_local_day, normalized_key, p_trigger_source,
      coalesce(p_scheduled_for, pg_catalog.now()), p_input_fingerprint,
      pg_catalog.now() + pg_catalog.make_interval(secs => p_lease_seconds)
    ) returning * into claimed;

    return pg_catalog.jsonb_build_object(
      'status', 'claimed', 'run_id', claimed.id,
      'claim_token', claimed.claim_token,
      'checkpoint_key', claimed.checkpoint_key,
      'generation_attempt', claimed.generation_attempt,
      'lease_expires_at', claimed.lease_expires_at
    );
  exception
    when raise_exception then
      if sqlerrm in (
        'project_ai_budget_exceeded', 'project_ai_spend_exceeded',
        'beta_access_required'
      ) then
        return pg_catalog.jsonb_build_object('status', 'quota', 'reason', sqlerrm);
      end if;
      raise;
  end;
end;
$$;

create or replace function public.get_coach_runs(
  p_user_id uuid,
  p_run_id uuid default null,
  p_local_day date default null,
  p_operation text default null,
  p_limit integer default 20
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    pg_catalog.jsonb_agg(item.run_json order by item.created_at desc, item.id desc),
    '[]'::jsonb
  )
  from (
    select
      run.id,
      run.created_at,
      pg_catalog.jsonb_build_object(
        'id', run.id,
        'operation', run.operation,
        'local_day', run.local_day,
        'checkpoint_key', run.checkpoint_key,
        'trigger_source', run.trigger_source,
        'status', run.status,
        'live', run.status = 'running' and run.lease_expires_at > pg_catalog.now(),
        'generation_attempt', run.generation_attempt,
        'input_fingerprint', run.input_fingerprint,
        'result', run.result,
        'model', run.model,
        'error_message', run.error_message,
        'scheduled_for', run.scheduled_for,
        'lease_expires_at', run.lease_expires_at,
        'completed_at', run.completed_at,
        'created_at', run.created_at,
        'updated_at', run.updated_at
      ) as run_json
    from private.coach_runs as run
    where run.user_id = p_user_id
      and (p_run_id is null or run.id = p_run_id)
      and (p_local_day is null or run.local_day = p_local_day)
      and (p_operation is null or run.operation = p_operation)
    order by run.created_at desc, run.id desc
    limit greatest(1, least(coalesce(p_limit, 20), 100))
  ) as item;
$$;

-- Messages are {kind, body, payload?, deliver_at?, local_day?, slot_key?,
-- notify?, reply_to_id?, entry_id?, activity_id?, id?}. Supersede entries are
-- 'slot' (the run's local_day) or 'YYYY-MM-DD:slot'.
create or replace function public.complete_coach_run(
  p_run_id uuid,
  p_claim_token uuid,
  p_status text,
  p_result jsonb default '{}'::jsonb,
  p_messages jsonb default '[]'::jsonb,
  p_supersede_slot_keys text[] default null,
  p_model text default null,
  p_provider_response_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  run_row private.coach_runs%rowtype;
  message_item jsonb;
  message_count integer := 0;
  message_deliver_at timestamptz;
  message_slot text;
  message_day date;
  slot_ref text;
  ref_day date;
  ref_slot text;
  inserted_id uuid;
  inserted_ids uuid[] := array[]::uuid[];
  superseded_count integer := 0;
  slot_superseded integer;
begin
  if p_status is null or p_status not in ('complete', 'skipped') then
    raise exception using
      errcode = '22023', message = 'Coach completion status is invalid';
  end if;
  if p_result is not null and pg_catalog.jsonb_typeof(p_result) <> 'object' then
    raise exception using
      errcode = '22023', message = 'Coach run result must be an object';
  end if;
  if p_messages is not null and pg_catalog.jsonb_typeof(p_messages) <> 'array' then
    raise exception using
      errcode = '22023', message = 'Coach messages must be an array';
  end if;
  if coalesce(pg_catalog.jsonb_array_length(p_messages), 0) > 12
    or coalesce(pg_catalog.cardinality(p_supersede_slot_keys), 0) > 24
    or (
      p_status = 'skipped'
      and coalesce(pg_catalog.jsonb_array_length(p_messages), 0) > 0
    ) then
    raise exception using
      errcode = '22023', message = 'Coach message batch is invalid';
  end if;

  select run.* into run_row
  from private.coach_runs as run
  where run.id = p_run_id
  for update of run;
  if not found then
    return pg_catalog.jsonb_build_object('status', 'not_found');
  end if;
  if run_row.claim_token is distinct from p_claim_token
    or run_row.status <> 'running' then
    return pg_catalog.jsonb_build_object('status', 'stale');
  end if;

  -- Anything already due is delivered and never retracted.
  update public.coach_messages
  set status = 'delivered'
  where user_id = run_row.user_id
    and status = 'scheduled'
    and deliver_at <= pg_catalog.now();

  foreach slot_ref in array coalesce(p_supersede_slot_keys, array[]::text[]) loop
    if slot_ref ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}:[a-z][a-z0-9_]{0,39}$' then
      ref_day := pg_catalog.split_part(slot_ref, ':', 1)::date;
      ref_slot := pg_catalog.split_part(slot_ref, ':', 2);
    elsif slot_ref ~ '^[a-z][a-z0-9_]{0,39}$' then
      ref_day := run_row.local_day;
      ref_slot := slot_ref;
    else
      raise exception using
        errcode = '22023', message = 'Coach supersede slot is invalid';
    end if;
    update public.coach_messages
    set status = 'superseded', superseded_at = pg_catalog.now()
    where user_id = run_row.user_id
      and status = 'scheduled'
      and local_day = ref_day
      and slot_key = ref_slot;
    get diagnostics slot_superseded = row_count;
    superseded_count := superseded_count + slot_superseded;
  end loop;

  for message_item in
    select element.value
    from pg_catalog.jsonb_array_elements(coalesce(p_messages, '[]'::jsonb))
      as element(value)
  loop
    message_count := message_count + 1;
    if pg_catalog.jsonb_typeof(message_item) <> 'object' then
      raise exception using
        errcode = '22023', message = 'Coach message must be an object';
    end if;
    message_deliver_at := greatest(
      coalesce(
        nullif(message_item->>'deliver_at', '')::timestamptz,
        pg_catalog.now()
      ),
      pg_catalog.now()
    );
    if message_deliver_at > pg_catalog.now() + interval '36 hours' then
      raise exception using
        errcode = '22023', message = 'Coach message is scheduled too far ahead';
    end if;
    message_slot := nullif(pg_catalog.btrim(message_item->>'slot_key'), '');
    message_day := coalesce(
      nullif(message_item->>'local_day', '')::date,
      run_row.local_day
    );
    -- A slot holds at most one pending nudge: the newest plan replaces it.
    if message_slot is not null then
      update public.coach_messages
      set status = 'superseded', superseded_at = pg_catalog.now()
      where user_id = run_row.user_id
        and status = 'scheduled'
        and local_day = message_day
        and slot_key = message_slot;
      get diagnostics slot_superseded = row_count;
      superseded_count := superseded_count + slot_superseded;
    end if;

    insert into public.coach_messages (
      id, user_id, role, kind, body, payload, local_day, deliver_at, status,
      notify, checkpoint_key, slot_key, run_id, dedupe_key, reply_to_id,
      entry_id, activity_id, model
    ) values (
      coalesce(nullif(message_item->>'id', '')::uuid, pg_catalog.gen_random_uuid()),
      run_row.user_id,
      'coach',
      message_item->>'kind',
      pg_catalog.btrim(coalesce(message_item->>'body', '')),
      case
        when pg_catalog.jsonb_typeof(message_item->'payload') = 'object'
          then message_item->'payload'
        else '{}'::jsonb
      end,
      message_day,
      message_deliver_at,
      case when message_deliver_at > pg_catalog.now() then 'scheduled' else 'delivered' end,
      coalesce(
        nullif(message_item->>'notify', '')::boolean,
        message_deliver_at > pg_catalog.now()
      ),
      run_row.checkpoint_key,
      message_slot,
      run_row.id,
      run_row.id::text || ':' || run_row.generation_attempt::text || ':'
        || message_count::text,
      nullif(message_item->>'reply_to_id', '')::uuid,
      nullif(message_item->>'entry_id', '')::uuid,
      nullif(message_item->>'activity_id', '')::uuid,
      nullif(pg_catalog.btrim(p_model), '')
    ) returning id into inserted_id;
    inserted_ids := inserted_ids || inserted_id;
  end loop;

  -- Finalize anything this attempt streamed. An empty stub is hidden.
  update public.coach_messages
  set status = 'superseded',
      superseded_at = pg_catalog.now(),
      payload = payload - 'streaming'
  where run_id = run_row.id
    and payload ? 'streaming'
    and pg_catalog.btrim(body) = ''
    and status <> 'superseded';
  update public.coach_messages
  set payload = payload - 'streaming',
      body = pg_catalog.btrim(body)
  where run_id = run_row.id
    and payload ? 'streaming';

  update private.coach_runs
  set status = p_status,
      result = coalesce(p_result, '{}'::jsonb),
      model = coalesce(nullif(pg_catalog.btrim(p_model), ''), model),
      provider_response_id = nullif(pg_catalog.btrim(p_provider_response_id), ''),
      error_message = null,
      lease_expires_at = null,
      completed_at = pg_catalog.now()
  where id = run_row.id;

  return pg_catalog.jsonb_build_object(
    'status', p_status,
    'message_ids', pg_catalog.to_jsonb(inserted_ids),
    'superseded', superseded_count
  );
end;
$$;

create or replace function public.fail_coach_run(
  p_run_id uuid,
  p_claim_token uuid,
  p_error_message text,
  p_retryable boolean default true
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  run_row private.coach_runs%rowtype;
begin
  update private.coach_runs as run
  set status = 'failed',
      lease_expires_at = null,
      completed_at = null,
      result = case
        when coalesce(p_retryable, true) then run.result
        else run.result || '{"terminal": true}'::jsonb
      end,
      error_message = pg_catalog.left(
        coalesce(nullif(pg_catalog.btrim(p_error_message), ''), 'Coach run failed'),
        500
      )
  where run.id = p_run_id
    and run.claim_token = p_claim_token
    and run.status = 'running'
  returning run.* into run_row;
  if not found then
    return false;
  end if;

  -- Text that was mid-stream stays readable but is marked interrupted; an
  -- empty stub is hidden.
  update public.coach_messages
  set status = 'superseded',
      superseded_at = pg_catalog.now(),
      payload = payload - 'streaming'
  where run_id = run_row.id
    and payload ? 'streaming'
    and pg_catalog.btrim(body) = ''
    and status <> 'superseded';
  update public.coach_messages
  set payload = (payload - 'streaming') || '{"interrupted": true}'::jsonb,
      body = pg_catalog.btrim(body)
  where run_id = run_row.id
    and payload ? 'streaming';

  if run_row.operation = 'activity_analysis'
    and (run_row.generation_attempt >= 3 or not coalesce(p_retryable, true)) then
    update public.activities
    set status = 'failed',
        error_message = 'Couldn’t read that workout. Edit it or log it again.'
    where user_id = run_row.user_id
      and id = pg_catalog.split_part(run_row.checkpoint_key, ':', 2)::uuid
      and status = 'processing';
  end if;
  return true;
end;
$$;

create or replace function public.post_user_coach_message(
  p_user_id uuid,
  p_client_request_id uuid,
  p_local_day date,
  p_kind text,
  p_body text,
  p_payload jsonb default '{}'::jsonb,
  p_attachment_path text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing public.coach_messages%rowtype;
  created public.coach_messages%rowtype;
  normalized_body text := pg_catalog.btrim(coalesce(p_body, ''));
  normalized_path text := nullif(pg_catalog.btrim(coalesce(p_attachment_path, '')), '');
  normalized_kind text := pg_catalog.btrim(coalesce(p_kind, ''));
begin
  -- A message with a photo is always a photo message (the text is its caption).
  if normalized_path is not null then
    normalized_kind := 'photo';
  end if;
  if p_user_id is null
    or p_client_request_id is null
    or p_local_day is null
    or normalized_kind not in ('text', 'photo')
    or (p_payload is not null and pg_catalog.jsonb_typeof(p_payload) <> 'object') then
    raise exception using
      errcode = '22023', message = 'User coach message is invalid';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shudo-coach-message:' || p_user_id::text, 0)
  );

  select message_row.* into existing
  from public.coach_messages as message_row
  where message_row.user_id = p_user_id
    and message_row.client_request_id = p_client_request_id;
  if found then
    if existing.kind = normalized_kind
      and existing.body = normalized_body
      and existing.attachment_path is not distinct from normalized_path then
      return pg_catalog.jsonb_build_object(
        'status', 'existing',
        'message_id', existing.id,
        'message', pg_catalog.to_jsonb(existing)
      );
    end if;
    return pg_catalog.jsonb_build_object(
      'status', 'conflict', 'message_id', existing.id
    );
  end if;

  if (
    select pg_catalog.count(*)
    from public.coach_messages as message_row
    where message_row.user_id = p_user_id
      and message_row.role = 'user'
      and message_row.created_at >= pg_catalog.now() - interval '24 hours'
  ) >= 200 then
    return pg_catalog.jsonb_build_object('status', 'quota');
  end if;

  insert into public.coach_messages (
    user_id, role, kind, body, payload, local_day, deliver_at, status, notify,
    client_request_id, attachment_path, read_at
  ) values (
    p_user_id, 'user', normalized_kind, normalized_body,
    coalesce(p_payload, '{}'::jsonb), p_local_day, pg_catalog.now(),
    'delivered', false, p_client_request_id, normalized_path, pg_catalog.now()
  ) returning * into created;

  return pg_catalog.jsonb_build_object(
    'status', 'created',
    'message_id', created.id,
    'message', pg_catalog.to_jsonb(created)
  );
end;
$$;

-- Streams a coach reply into one message row under the run fence. p_body is
-- the full text so far (not a delta), so a retried write is idempotent. The
-- row carries payload.streaming = true until p_done.
create or replace function public.upsert_streaming_coach_message(
  p_run_id uuid,
  p_claim_token uuid,
  p_message_id uuid,
  p_body text,
  p_payload jsonb default '{}'::jsonb,
  p_done boolean default false,
  p_kind text default 'text',
  p_model text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  run_row private.coach_runs%rowtype;
  existing public.coach_messages%rowtype;
  next_payload jsonb;
  next_body text;
  parent_id uuid;
  is_done boolean := coalesce(p_done, false);
begin
  if p_message_id is null
    or (p_payload is not null and pg_catalog.jsonb_typeof(p_payload) <> 'object') then
    raise exception using
      errcode = '22023', message = 'Streaming coach message is invalid';
  end if;

  select run.* into run_row
  from private.coach_runs as run
  where run.id = p_run_id
  for update of run;
  if not found then
    return pg_catalog.jsonb_build_object('status', 'not_found');
  end if;
  if run_row.claim_token is distinct from p_claim_token
    or run_row.status <> 'running' then
    return pg_catalog.jsonb_build_object('status', 'stale');
  end if;

  next_payload := coalesce(p_payload, '{}'::jsonb) - 'streaming';
  if not is_done then
    next_payload := next_payload || '{"streaming": true}'::jsonb;
  end if;
  next_body := case
    when is_done then pg_catalog.btrim(coalesce(p_body, ''))
    else coalesce(p_body, '')
  end;

  select message_row.* into existing
  from public.coach_messages as message_row
  where message_row.id = p_message_id
  for update of message_row;

  if found then
    if existing.user_id <> run_row.user_id
      or existing.run_id is distinct from run_row.id
      or existing.status = 'superseded' then
      return pg_catalog.jsonb_build_object(
        'status', 'conflict', 'message_id', p_message_id
      );
    end if;
    update public.coach_messages
    set body = next_body,
        payload = next_payload,
        model = coalesce(nullif(pg_catalog.btrim(p_model), ''), model)
    where id = p_message_id;
    return pg_catalog.jsonb_build_object(
      'status', 'saved', 'message_id', p_message_id,
      'created', false, 'done', is_done
    );
  end if;

  if run_row.operation = 'coach_reply' then
    select message_row.id into parent_id
    from public.coach_messages as message_row
    where message_row.user_id = run_row.user_id
      and message_row.client_request_id
        = pg_catalog.split_part(run_row.checkpoint_key, ':', 2)::uuid;
  end if;

  insert into public.coach_messages (
    id, user_id, role, kind, body, payload, local_day, deliver_at, status,
    notify, checkpoint_key, run_id, reply_to_id, model
  ) values (
    p_message_id, run_row.user_id, 'coach',
    coalesce(nullif(pg_catalog.btrim(p_kind), ''), 'text'),
    next_body, next_payload, run_row.local_day, pg_catalog.now(), 'delivered',
    false, run_row.checkpoint_key, run_row.id, parent_id,
    nullif(pg_catalog.btrim(p_model), '')
  );
  return pg_catalog.jsonb_build_object(
    'status', 'saved', 'message_id', p_message_id,
    'created', true, 'done', is_done
  );
end;
$$;

-- A coach message outside a run (weekly recap, card-action results).
-- Idempotent per (user, dedupe_key).
create or replace function public.post_coach_message(
  p_user_id uuid,
  p_kind text,
  p_body text,
  p_payload jsonb,
  p_local_day date,
  p_dedupe_key text,
  p_notify boolean default false,
  p_deliver_at timestamptz default null,
  p_slot_key text default null,
  p_entry_id uuid default null,
  p_activity_id uuid default null,
  p_reply_to_id uuid default null,
  p_model text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing public.coach_messages%rowtype;
  created public.coach_messages%rowtype;
  normalized_key text := nullif(pg_catalog.btrim(coalesce(p_dedupe_key, '')), '');
  normalized_slot text := nullif(pg_catalog.btrim(coalesce(p_slot_key, '')), '');
  message_deliver_at timestamptz := greatest(
    coalesce(p_deliver_at, pg_catalog.now()), pg_catalog.now()
  );
begin
  if p_user_id is null or p_local_day is null or normalized_key is null
    or (p_payload is not null and pg_catalog.jsonb_typeof(p_payload) <> 'object') then
    raise exception using
      errcode = '22023', message = 'Coach message is invalid';
  end if;
  if message_deliver_at > pg_catalog.now() + interval '36 hours' then
    raise exception using
      errcode = '22023', message = 'Coach message is scheduled too far ahead';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shudo-coach-message:' || p_user_id::text, 0)
  );

  select message_row.* into existing
  from public.coach_messages as message_row
  where message_row.user_id = p_user_id
    and message_row.dedupe_key = normalized_key;
  if found then
    return pg_catalog.jsonb_build_object(
      'status', 'existing',
      'message_id', existing.id,
      'message', pg_catalog.to_jsonb(existing)
    );
  end if;

  if normalized_slot is not null then
    update public.coach_messages
    set status = 'superseded', superseded_at = pg_catalog.now()
    where user_id = p_user_id
      and status = 'scheduled'
      and local_day = p_local_day
      and slot_key = normalized_slot;
  end if;

  insert into public.coach_messages (
    user_id, role, kind, body, payload, local_day, deliver_at, status, notify,
    slot_key, dedupe_key, reply_to_id, entry_id, activity_id, model
  ) values (
    p_user_id, 'coach', p_kind, pg_catalog.btrim(coalesce(p_body, '')),
    coalesce(p_payload, '{}'::jsonb), p_local_day, message_deliver_at,
    case when message_deliver_at > pg_catalog.now() then 'scheduled' else 'delivered' end,
    coalesce(p_notify, false), normalized_slot, normalized_key, p_reply_to_id,
    p_entry_id, p_activity_id, nullif(pg_catalog.btrim(p_model), '')
  ) returning * into created;

  return pg_catalog.jsonb_build_object(
    'status', 'created',
    'message_id', created.id,
    'message', pg_catalog.to_jsonb(created)
  );
end;
$$;

-- p_digest: {headline, summary, metrics?, highlights?, misses?,
-- tomorrow_focus?, game_plan?, score?, input_fingerprint?, digest_version?,
-- model, provider_response_id?}. The row's local_day is the digested day;
-- game_plan is for the following day.
create or replace function public.save_day_digest(
  p_run_id uuid,
  p_claim_token uuid,
  p_digest jsonb
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  run_row private.coach_runs%rowtype;
begin
  if p_digest is null or pg_catalog.jsonb_typeof(p_digest) <> 'object' then
    raise exception using
      errcode = '22023', message = 'Day digest must be an object';
  end if;

  select run.* into run_row
  from private.coach_runs as run
  where run.id = p_run_id
  for update of run;
  if not found then
    return 'not_found';
  end if;
  if run_row.claim_token is distinct from p_claim_token
    or run_row.status <> 'running'
    or run_row.operation <> 'day_digest' then
    return 'stale';
  end if;

  insert into public.day_digests (
    user_id, local_day, headline, summary, metrics, highlights, misses,
    tomorrow_focus, game_plan, score, input_fingerprint, digest_version, model,
    provider_response_id, run_id, generated_at
  ) values (
    run_row.user_id,
    run_row.local_day,
    pg_catalog.btrim(p_digest->>'headline'),
    pg_catalog.btrim(p_digest->>'summary'),
    coalesce(p_digest->'metrics', '{}'::jsonb),
    coalesce(p_digest->'highlights', '[]'::jsonb),
    coalesce(p_digest->'misses', '[]'::jsonb),
    coalesce(p_digest->'tomorrow_focus', '[]'::jsonb),
    coalesce(p_digest->'game_plan', '{}'::jsonb),
    nullif(p_digest->>'score', '')::smallint,
    coalesce(
      nullif(pg_catalog.btrim(p_digest->>'input_fingerprint'), ''),
      run_row.input_fingerprint,
      run_row.id::text
    ),
    coalesce(nullif(p_digest->>'digest_version', '')::smallint, 1::smallint),
    coalesce(
      nullif(pg_catalog.btrim(p_digest->>'model'), ''),
      run_row.model,
      'unknown'
    ),
    nullif(pg_catalog.btrim(p_digest->>'provider_response_id'), ''),
    run_row.id,
    pg_catalog.now()
  )
  on conflict (user_id, local_day) do update
  set headline = excluded.headline,
      summary = excluded.summary,
      metrics = excluded.metrics,
      highlights = excluded.highlights,
      misses = excluded.misses,
      tomorrow_focus = excluded.tomorrow_focus,
      game_plan = excluded.game_plan,
      score = excluded.score,
      input_fingerprint = excluded.input_fingerprint,
      digest_version = excluded.digest_version,
      model = excluded.model,
      provider_response_id = excluded.provider_response_id,
      run_id = excluded.run_id,
      generated_at = excluded.generated_at;
  return 'saved';
end;
$$;

-- p_analysis: {kind?, title?, duration_min?, distance_km?, active_kcal?,
-- avg_heart_rate?, intensity?, rpe?, details?, confidence?, model?,
-- provider_response_id?}. The run key must be activity:<p_activity_id>.
create or replace function public.save_activity_analysis(
  p_run_id uuid,
  p_claim_token uuid,
  p_activity_id uuid,
  p_analysis jsonb
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  run_row private.coach_runs%rowtype;
begin
  if p_activity_id is null
    or p_analysis is null
    or pg_catalog.jsonb_typeof(p_analysis) <> 'object' then
    raise exception using
      errcode = '22023', message = 'Activity analysis must be an object';
  end if;

  select run.* into run_row
  from private.coach_runs as run
  where run.id = p_run_id
  for update of run;
  if not found then
    return 'not_found';
  end if;
  if run_row.claim_token is distinct from p_claim_token
    or run_row.status <> 'running'
    or run_row.operation <> 'activity_analysis'
    or run_row.checkpoint_key <> 'activity:' || p_activity_id::text then
    return 'stale';
  end if;

  update public.activities as activity
  set kind = coalesce(nullif(p_analysis->>'kind', ''), activity.kind),
      title = coalesce(nullif(pg_catalog.btrim(p_analysis->>'title'), ''), activity.title),
      duration_min = nullif(p_analysis->>'duration_min', '')::numeric,
      distance_km = nullif(p_analysis->>'distance_km', '')::numeric,
      active_kcal = nullif(p_analysis->>'active_kcal', '')::numeric,
      avg_heart_rate = pg_catalog.round(
        nullif(p_analysis->>'avg_heart_rate', '')::numeric
      )::smallint,
      intensity = nullif(p_analysis->>'intensity', ''),
      rpe = nullif(p_analysis->>'rpe', '')::numeric,
      details = case
        when pg_catalog.jsonb_typeof(p_analysis->'details') = 'object'
          then p_analysis->'details'
        else activity.details
      end,
      confidence = nullif(p_analysis->>'confidence', '')::numeric,
      status = 'complete',
      error_message = null,
      analysis_model = coalesce(
        nullif(pg_catalog.btrim(p_analysis->>'model'), ''),
        activity.analysis_model
      ),
      provider_response_id = nullif(
        pg_catalog.btrim(p_analysis->>'provider_response_id'), ''
      ),
      processed_at = pg_catalog.now()
  where activity.id = p_activity_id
    and activity.user_id = run_row.user_id;
  if not found then
    return 'not_found';
  end if;
  return 'saved';
end;
$$;

-- p_review must carry photo_path equal to the check-in's current photo, so a
-- review never lands on a photo that was replaced while the model ran.
create or replace function public.save_body_review(
  p_run_id uuid,
  p_claim_token uuid,
  p_checkin_id uuid,
  p_review jsonb,
  p_model text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  run_row private.coach_runs%rowtype;
begin
  if p_checkin_id is null
    or p_review is null
    or pg_catalog.jsonb_typeof(p_review) <> 'object'
    or nullif(p_review->>'photo_path', '') is null then
    raise exception using
      errcode = '22023', message = 'Body review is invalid';
  end if;

  select run.* into run_row
  from private.coach_runs as run
  where run.id = p_run_id
  for update of run;
  if not found then
    return 'not_found';
  end if;
  if run_row.claim_token is distinct from p_claim_token
    or run_row.status <> 'running'
    or run_row.operation <> 'body_review' then
    return 'stale';
  end if;

  update public.weight_checkins as checkin
  set coach_review = p_review,
      coach_reviewed_photo_path = checkin.progress_photo_path,
      coach_review_model = nullif(pg_catalog.btrim(p_model), ''),
      coach_reviewed_at = pg_catalog.now()
  where checkin.id = p_checkin_id
    and checkin.user_id = run_row.user_id
    and checkin.progress_photo_path = p_review->>'photo_path';
  if not found then
    return 'stale';
  end if;
  return 'saved';
end;
$$;

-- Version-locked living memory. p_expected_version is the version the caller
-- read (0 when there is no memory yet). Returns {status: saved|conflict|stale,
-- version}. With p_claim_token the write is also fenced on that live run.
create or replace function public.save_coach_memory(
  p_user_id uuid,
  p_expected_version integer,
  p_document text,
  p_sections jsonb,
  p_source text,
  p_change_summary text default null,
  p_run_id uuid default null,
  p_message_id uuid default null,
  p_claim_token uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  existing_version integer;
  saved_version integer;
  normalized_document text := pg_catalog.btrim(coalesce(p_document, ''));
  normalized_sections jsonb := coalesce(p_sections, '{}'::jsonb);
begin
  if p_user_id is null or p_expected_version is null or p_expected_version < 0 then
    raise exception using
      errcode = '22023', message = 'Coach memory identifiers are required';
  end if;
  if p_claim_token is not null and p_run_id is null then
    raise exception using
      errcode = '22023', message = 'Coach memory claim token needs a run';
  end if;
  if p_run_id is not null then
    perform 1
    from private.coach_runs as run
    where run.id = p_run_id
    for update of run;
    if not private.coach_run_matches(p_run_id, p_claim_token, p_user_id) then
      return pg_catalog.jsonb_build_object('status', 'stale');
    end if;
  end if;
  if p_message_id is not null and not exists (
    select 1 from public.coach_messages as message_row
    where message_row.id = p_message_id and message_row.user_id = p_user_id
  ) then
    raise exception using
      errcode = '23503', message = 'coach_memory_message_not_owned';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shudo-coach-memory:' || p_user_id::text, 0)
  );
  select memory.version into existing_version
  from public.coach_memory as memory
  where memory.user_id = p_user_id
  for update of memory;
  existing_version := coalesce(existing_version, 0);
  if existing_version <> p_expected_version then
    return pg_catalog.jsonb_build_object(
      'status', 'conflict', 'version', existing_version
    );
  end if;

  insert into public.coach_memory (user_id, version, document, sections, updated_source)
  values (
    p_user_id, existing_version + 1, normalized_document, normalized_sections,
    p_source
  )
  on conflict (user_id) do update
  set version = excluded.version,
      document = excluded.document,
      sections = excluded.sections,
      updated_source = excluded.updated_source
  returning version into saved_version;

  insert into public.coach_memory_revisions (
    user_id, version, document, sections, source, change_summary, run_id,
    coach_message_id
  ) values (
    p_user_id, saved_version, normalized_document, normalized_sections, p_source,
    nullif(pg_catalog.btrim(p_change_summary), ''), p_run_id, p_message_id
  );
  return pg_catalog.jsonb_build_object('status', 'saved', 'version', saved_version);
end;
$$;

-- Saves a new draft and supersedes any previous draft. Returns
-- {status: saved|stale, plan_id, superseded_draft_id}.
create or replace function public.save_training_plan_draft(
  p_user_id uuid,
  p_plan jsonb,
  p_rationale text default null,
  p_change_summary text default null,
  p_source text default 'coach',
  p_model text default null,
  p_run_id uuid default null,
  p_claim_token uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  previous_draft_id uuid;
  created_id uuid;
begin
  if p_user_id is null
    or p_plan is null
    or pg_catalog.jsonb_typeof(p_plan) <> 'object' then
    raise exception using
      errcode = '22023', message = 'Training plan draft is invalid';
  end if;
  if p_claim_token is not null and p_run_id is null then
    raise exception using
      errcode = '22023', message = 'Training plan claim token needs a run';
  end if;
  if p_run_id is not null then
    perform 1
    from private.coach_runs as run
    where run.id = p_run_id
    for update of run;
    if not private.coach_run_matches(p_run_id, p_claim_token, p_user_id) then
      return pg_catalog.jsonb_build_object('status', 'stale');
    end if;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shudo-training-plan:' || p_user_id::text, 0)
  );

  update public.training_plans
  set status = 'superseded'
  where user_id = p_user_id and status = 'draft'
  returning id into previous_draft_id;

  insert into public.training_plans (
    user_id, status, plan, rationale, change_summary, source, model, run_id
  ) values (
    p_user_id, 'draft', p_plan,
    nullif(pg_catalog.btrim(p_rationale), ''),
    nullif(pg_catalog.btrim(p_change_summary), ''),
    coalesce(nullif(pg_catalog.btrim(p_source), ''), 'coach'),
    nullif(pg_catalog.btrim(p_model), ''),
    p_run_id
  ) returning id into created_id;

  return pg_catalog.jsonb_build_object(
    'status', 'saved',
    'plan_id', created_id,
    'superseded_draft_id', previous_draft_id
  );
end;
$$;

-- Activates a draft, or re-activates a superseded plan (undo). Returns
-- {status: activated|already_active|not_found|invalid_state, plan_id,
-- previous_plan_id}.
create or replace function public.activate_training_plan(
  p_user_id uuid,
  p_plan_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  target public.training_plans%rowtype;
  previous_id uuid;
begin
  if p_user_id is null or p_plan_id is null then
    raise exception using
      errcode = '22023', message = 'Training plan identifiers are required';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shudo-training-plan:' || p_user_id::text, 0)
  );

  select plan_row.* into target
  from public.training_plans as plan_row
  where plan_row.id = p_plan_id and plan_row.user_id = p_user_id
  for update of plan_row;
  if not found then
    return pg_catalog.jsonb_build_object('status', 'not_found', 'plan_id', p_plan_id);
  end if;
  if target.status = 'active' then
    return pg_catalog.jsonb_build_object(
      'status', 'already_active', 'plan_id', target.id
    );
  end if;
  if target.status not in ('draft', 'superseded') then
    return pg_catalog.jsonb_build_object(
      'status', 'invalid_state', 'plan_id', target.id
    );
  end if;

  update public.training_plans
  set status = 'superseded'
  where user_id = p_user_id and status = 'active'
  returning id into previous_id;

  update public.training_plans
  set status = 'active', activated_at = pg_catalog.now()
  where id = target.id;

  return pg_catalog.jsonb_build_object(
    'status', 'activated',
    'plan_id', target.id,
    'previous_plan_id', previous_id
  );
end;
$$;

create or replace function public.discard_training_plan_draft(
  p_user_id uuid,
  p_plan_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_status text;
begin
  if p_user_id is null or p_plan_id is null then
    raise exception using
      errcode = '22023', message = 'Training plan identifiers are required';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('shudo-training-plan:' || p_user_id::text, 0)
  );

  select plan_row.status into current_status
  from public.training_plans as plan_row
  where plan_row.id = p_plan_id and plan_row.user_id = p_user_id
  for update of plan_row;
  if not found then
    return pg_catalog.jsonb_build_object('status', 'not_found', 'plan_id', p_plan_id);
  end if;
  if current_status = 'rejected' then
    return pg_catalog.jsonb_build_object('status', 'rejected', 'plan_id', p_plan_id);
  end if;
  if current_status <> 'draft' then
    return pg_catalog.jsonb_build_object(
      'status', 'invalid_state', 'plan_id', p_plan_id
    );
  end if;

  update public.training_plans
  set status = 'rejected'
  where id = p_plan_id;
  return pg_catalog.jsonb_build_object('status', 'rejected', 'plan_id', p_plan_id);
end;
$$;

-- One row per provider call, priced in TypeScript. With p_run_id the call is
-- linked to that run's exact AI reservation; p_request_key/p_attempt link a
-- capture-pool reservation instead.
create or replace function public.record_ai_provider_call(
  p_user_id uuid,
  p_operation text,
  p_workload text,
  p_model text,
  p_input_tokens integer,
  p_output_tokens integer,
  p_cache_read_tokens integer,
  p_cache_write_tokens integer,
  p_web_search_requests integer,
  p_cost_usd_micros bigint,
  p_pricing_version text,
  p_run_id uuid default null,
  p_request_key text default null,
  p_attempt smallint default null,
  p_provider_request_id text default null,
  p_latency_ms integer default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  linked_usage_id uuid;
  linked_run_id uuid;
  recorded_id uuid;
  normalized_operation text := pg_catalog.btrim(coalesce(p_operation, ''));
begin
  if p_run_id is not null then
    select run.id, usage.id into linked_run_id, linked_usage_id
    from private.coach_runs as run
    left join private.ai_job_usage as usage
      on usage.operation = run.operation
      and usage.user_id = run.user_id
      and usage.request_key = run.local_day::text || ':' || run.checkpoint_key
      and usage.attempt = run.generation_attempt
    where run.id = p_run_id
      and (p_user_id is null or run.user_id = p_user_id);
  elsif p_request_key is not null and p_attempt is not null and p_user_id is not null then
    select usage.id into linked_usage_id
    from private.ai_job_usage as usage
    where usage.operation = normalized_operation
      and usage.user_id = p_user_id
      and usage.request_key = pg_catalog.btrim(p_request_key)
      and usage.attempt = p_attempt;
  end if;

  insert into private.ai_provider_calls (
    usage_id, run_id, user_id, operation, workload, model, provider_request_id,
    input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
    web_search_requests, cost_usd_micros, pricing_version, latency_ms
  ) values (
    linked_usage_id,
    linked_run_id,
    p_user_id,
    normalized_operation,
    pg_catalog.btrim(coalesce(p_workload, '')),
    pg_catalog.btrim(coalesce(p_model, '')),
    nullif(pg_catalog.btrim(p_provider_request_id), ''),
    coalesce(p_input_tokens, 0),
    coalesce(p_output_tokens, 0),
    coalesce(p_cache_read_tokens, 0),
    coalesce(p_cache_write_tokens, 0),
    coalesce(p_web_search_requests, 0),
    coalesce(p_cost_usd_micros, 0),
    pg_catalog.btrim(coalesce(p_pricing_version, '')),
    p_latency_ms
  ) returning id into recorded_id;
  return recorded_id;
end;
$$;

-- 12. Pure-SQL housekeeping, run by coach_tick (through the service-role
--     wrapper) and by tests.
create or replace function private.coach_housekeeping()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  delivered_count integer;
  expired_runs integer;
  interrupted_count integer;
  failed_activities integer;
begin
  update public.coach_messages
  set status = 'delivered'
  where status = 'scheduled' and deliver_at <= pg_catalog.now();
  get diagnostics delivered_count = row_count;

  update private.coach_runs
  set status = 'failed',
      lease_expires_at = null,
      error_message = coalesce(error_message, 'Coach run lease expired')
  where status = 'running'
    and lease_expires_at < pg_catalog.now() - interval '1 hour';
  get diagnostics expired_runs = row_count;

  update public.coach_messages as message_row
  set payload = (message_row.payload - 'streaming') || '{"interrupted": true}'::jsonb,
      status = case
        when pg_catalog.btrim(message_row.body) = '' then 'superseded'
        else message_row.status
      end,
      superseded_at = case
        when pg_catalog.btrim(message_row.body) = '' then pg_catalog.now()
        else message_row.superseded_at
      end
  from private.coach_runs as run
  where run.id = message_row.run_id
    and message_row.payload ? 'streaming'
    and (
      run.status <> 'running'
      or run.lease_expires_at < pg_catalog.now() - interval '10 minutes'
    );
  get diagnostics interrupted_count = row_count;

  update public.activities
  set status = 'failed',
      error_message = coalesce(
        error_message,
        'Activity analysis did not finish. Edit it or log it again.'
      )
  where status = 'processing'
    and updated_at < pg_catalog.now() - interval '30 minutes';
  get diagnostics failed_activities = row_count;

  return pg_catalog.jsonb_build_object(
    'delivered', delivered_count,
    'expired_runs', expired_runs,
    'interrupted_messages', interrupted_count,
    'failed_activities', failed_activities
  );
end;
$$;

revoke all on function private.coach_housekeeping()
  from public, anon, authenticated, service_role;

create or replace function public.run_coach_housekeeping()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select private.coach_housekeeping();
$$;

do $$
declare
  signature text;
begin
  foreach signature in array array[
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
  ] loop
    execute pg_catalog.format(
      'revoke all on function %s from public, anon, authenticated',
      signature
    );
    execute pg_catalog.format(
      'grant execute on function %s to service_role',
      signature
    );
  end loop;
end;
$$;

comment on table public.coach_messages is
  'In-app coach thread. Visible when status <> superseded and deliver_at <= now(); scheduled rows feed local notifications; clients may only set read_at.';
comment on column public.coach_messages.payload is
  'Card data discriminated by kind; streaming=true while a reply streams; push_body (<=150 chars) is the lock-screen text when notify is true.';
comment on table private.coach_runs is
  'Fenced, leased, retry-bounded ledger for every coach AI job; outputs are written only by claim-token RPCs.';
comment on table private.ai_provider_calls is
  'Per-call model token and cost ledger; never exposed through the Data API.';
comment on table public.coach_memory is
  'One living coach memory document per user (bio sections + coach notes); versioned with append-only revisions.';
comment on table public.day_digests is
  'Nightly per-local-day compressed summary written under a day_digest run fence; game_plan is for the following day.';
comment on table public.activities is
  'Workouts and other activities, separate from meal entries; written by the server, readable and deletable by the owner.';
comment on table public.training_plans is
  'Versioned training plans: at most one active and one draft per user; drafts are activated only by the user.';
comment on table public.device_snapshots is
  'Latest per-device context: timezone, permissions, coarse (~110 m) location, nearby stores without coordinates, future APNs token.';
