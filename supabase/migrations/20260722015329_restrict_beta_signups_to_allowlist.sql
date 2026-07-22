-- Friends-only beta admission. Supabase Auth invokes the hook below before it
-- creates an email/password or social-auth user. The exact normalized-email
-- allowlist keeps normal account creation available to invited people without
-- exposing a public invite code or adding CAPTCHA to the native app.
create table public.beta_signup_allowlist (
  email text primary key,
  enabled boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  note text,
  constraint beta_signup_allowlist_email_check check (
    email = pg_catalog.lower(pg_catalog.btrim(email))
    and char_length(email) between 3 and 320
    and email !~ '[[:space:]]'
    and email like '%@%'
  ),
  constraint beta_signup_allowlist_note_check check (
    note is null or char_length(note) <= 200
  )
);

alter table public.beta_signup_allowlist enable row level security;
revoke all on table public.beta_signup_allowlist
  from public, anon, authenticated, service_role, supabase_auth_admin;

-- The Auth hook is SECURITY INVOKER. Give only Supabase Auth the two-column
-- read path it needs; app users and the Data API cannot enumerate invitees.
grant select (email, enabled) on table public.beta_signup_allowlist
  to supabase_auth_admin;
create policy beta_signup_allowlist_auth_hook_read
on public.beta_signup_allowlist
for select
to supabase_auth_admin
using (enabled);

comment on table public.beta_signup_allowlist is
  'Exact normalized emails permitted to create a Shudo friends-beta account; readable only by the Supabase Auth hook.';

-- The first release admits only the explicitly audited primary account. No
-- historical Auth row is implicitly promoted. This row intentionally survives
-- later account deletion so the owner can recreate the account with the same
-- verified email. Friends are added explicitly after review.
insert into public.beta_signup_allowlist (email, note)
values ('luke@yng.sh', 'Primary beta owner')
on conflict (email) do update
set enabled = true,
    note = excluded.note;

create or replace function public.hook_restrict_shudo_signup(event jsonb)
returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  signup_email text := pg_catalog.lower(
    pg_catalog.btrim(coalesce(event #>> '{user,email}', ''))
  );
begin
  if signup_email = '' or not exists (
    select 1
    from public.beta_signup_allowlist as allowed
    where allowed.email = signup_email
      and allowed.enabled
  ) then
    return pg_catalog.jsonb_build_object(
      'error',
      pg_catalog.jsonb_build_object(
        'http_code', 403,
        'message', 'This beta is invite-only.'
      )
    );
  end if;

  return '{}'::jsonb;
end;
$$;

revoke all on function public.hook_restrict_shudo_signup(jsonb)
  from public, anon, authenticated, service_role;
grant usage on schema public to supabase_auth_admin;
grant execute on function public.hook_restrict_shudo_signup(jsonb)
  to supabase_auth_admin;

comment on function public.hook_restrict_shudo_signup(jsonb) is
  'Supabase Before User Created hook: allows only an exact enabled email in public.beta_signup_allowlist.';

-- Keep the database budget safe even if hosted Auth hook configuration drifts.
-- Every real model-backed request inserts a user-owned reservation; synthetic
-- project-cap fixtures use a null user_id and remain available to operators.
create or replace function private.enforce_beta_ai_access()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.user_id is null then
    return new;
  end if;

  if not exists (
    select 1
    from auth.users as auth_user
    join public.beta_signup_allowlist as allowed
      on allowed.email = pg_catalog.lower(pg_catalog.btrim(auth_user.email))
      and allowed.enabled
    where auth_user.id = new.user_id
  ) then
    raise exception using
      errcode = 'P0001', message = 'beta_access_required';
  end if;

  return new;
end;
$$;

revoke all on function private.enforce_beta_ai_access()
  from public, anon, authenticated, service_role, supabase_auth_admin;

drop trigger if exists ai_job_usage_enforce_beta_access
  on private.ai_job_usage;
create trigger ai_job_usage_enforce_beta_access
before insert on private.ai_job_usage
for each row execute function private.enforce_beta_ai_access();
