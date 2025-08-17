-- EXTENSIONS
create extension if not exists "uuid-ossp";
create extension if not exists pgcrypto;

-- PROFILES (1:1 with auth.users)
create table if not exists public.profiles (
	user_id uuid primary key references auth.users(id) on delete cascade,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	timezone text not null default 'UTC',
	units text not null default 'imperial',
	height_cm numeric(5,2),
	weight_kg numeric(6,2),
	target_weight_kg numeric(6,2),
	goal text not null default 'gain',
	daily_macro_target jsonb not null default jsonb_build_object(
		'calories_kcal', 2800,
		'protein_g', 180,
		'carbs_g', 360,
		'fat_g', 72
	)
);

-- ENTRIES
create table if not exists public.entries (
	id uuid primary key default gen_random_uuid(),
	user_id uuid not null references auth.users(id) on delete cascade,
	created_at timestamptz not null default now(),
	processed_at timestamptz,
	status text not null default 'pending',
	client_submitted_at timestamptz,
	timezone_snapshot text not null default 'UTC',
	local_day date generated always as (date(timezone(timezone_snapshot, created_at))) stored,
	has_audio boolean default false,
	has_image boolean default false,
	has_text boolean default false,
	raw_text text,
	image_path text,
	audio_path text,
	image_sha256 text,
	dedupe_hash text unique,
	model_output jsonb,
	protein_g numeric(8,2),
	carbs_g numeric(8,2),
	fat_g numeric(8,2),
	calories_kcal numeric(8,2),
	confidence numeric(4,3),
	error_msg text
);

create index if not exists entries_user_day_idx on public.entries (user_id, local_day);
create index if not exists entries_status_idx on public.entries (status);

-- ENTRY ITEMS
create table if not exists public.entry_items (
	id bigserial primary key,
	entry_id uuid references public.entries(id) on delete cascade,
	label text,
	qty numeric,
	unit text,
	calories_kcal integer,
	protein_g integer,
	carbs_g integer,
	fat_g integer
);

create index if not exists entry_items_entry_id_idx on public.entry_items (entry_id);

-- MACRO PLANS
create table if not exists public.macro_plans (
	id bigserial primary key,
	user_id uuid not null references auth.users(id) on delete cascade,
	effective_from date not null,
	calories_kcal integer not null,
	protein_g integer not null,
	carbs_g integer not null,
	fat_g integer not null,
	notes text
);

create index if not exists macro_plans_user_effective_idx on public.macro_plans (user_id, effective_from);

-- DAILY SUMMARIES
create table if not exists public.daily_summaries (
	id bigserial primary key,
	user_id uuid not null references auth.users(id) on delete cascade,
	local_date date not null,
	calories_kcal integer not null default 0,
	protein_g integer not null default 0,
	carbs_g integer not null default 0,
	fat_g integer not null default 0,
	created_at timestamptz not null default now()
);

create unique index if not exists daily_summaries_user_date_idx on public.daily_summaries (user_id, local_date);

-- VIEW: day_totals
create or replace view public.day_totals as
select
	e.user_id,
	e.local_day,
	coalesce(sum(e.protein_g),0) as protein_g,
	coalesce(sum(e.carbs_g),0)  as carbs_g,
	coalesce(sum(e.fat_g),0)    as fat_g,
	coalesce(sum(e.calories_kcal),0) as calories_kcal,
	count(*) as entry_count
from public.entries e
where e.status = 'complete'
group by e.user_id, e.local_day;

-- VIEW: today_status
create or replace view public.today_status as
select
	p.user_id,
	p.timezone,
	current_date as server_date,
	dt.local_day,
	(p.daily_macro_target->>'protein_g')::numeric as target_protein_g,
	(p.daily_macro_target->>'carbs_g')::numeric  as target_carbs_g,
	(p.daily_macro_target->>'fat_g')::numeric    as target_fat_g,
	(p.daily_macro_target->>'calories_kcal')::numeric as target_calories_kcal,
	dt.protein_g as consumed_protein_g,
	dt.carbs_g   as consumed_carbs_g,
	dt.fat_g     as consumed_fat_g,
	dt.calories_kcal as consumed_calories_kcal
from public.profiles p
left join public.day_totals dt
	on dt.user_id = p.user_id
	and dt.local_day = date(timezone(p.timezone, now()));

-- RLS
alter table public.profiles enable row level security;
alter table public.entries  enable row level security;
alter table public.entry_items enable row level security;
alter table public.macro_plans enable row level security;
alter table public.daily_summaries enable row level security;

create policy "select own profile" on public.profiles for select to authenticated using (auth.uid() = user_id);
create policy "insert own profile" on public.profiles for insert to authenticated with check (auth.uid() = user_id);
create policy "update own profile" on public.profiles for update to authenticated using (auth.uid() = user_id);

create policy "select own entries" on public.entries for select to authenticated using (auth.uid() = user_id);
create policy "insert own entries" on public.entries for insert to authenticated with check (auth.uid() = user_id);

revoke update on public.entries from authenticated;

-- RLS policies for new tables
create policy "select own entry_items" on public.entry_items for select to authenticated using (
	exists (
		select 1 from public.entries e where e.id = entry_id and e.user_id = auth.uid()
	)
);

create policy "select own macro_plans" on public.macro_plans for select to authenticated using (auth.uid() = user_id);
create policy "insert own macro_plans" on public.macro_plans for insert to authenticated with check (auth.uid() = user_id);
create policy "update own macro_plans" on public.macro_plans for update to authenticated using (auth.uid() = user_id);

create policy "select own daily_summaries" on public.daily_summaries for select to authenticated using (auth.uid() = user_id);


