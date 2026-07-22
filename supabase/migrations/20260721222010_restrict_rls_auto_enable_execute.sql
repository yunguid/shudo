-- The downloaded legacy project included this dashboard helper in the exposed
-- public schema. Preserve it for platform compatibility, but remove every Data
-- API execution path because it runs with its owner's privileges.
do $migration$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    execute 'revoke execute on function public.rls_auto_enable() from public, anon, authenticated';
  end if;
end;
$migration$;
