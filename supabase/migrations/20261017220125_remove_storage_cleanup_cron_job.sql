-- Remove the hand-made 15-minute pg_cron caller of drain_storage_cleanup. It
-- was created directly in production on 2026-07-21, outside the migrations,
-- and sends a Vault copy of SHUDO_CLEANUP_SECRET that nothing keeps in sync
-- with the Edge Function secret, so the function rejects it with 401. The
-- queue does not depend on it: create_entry, delete_entry, resume_entry, and
-- the entry processor drain it inline, and the daily Vercel cron
-- (/api/cron/keepalive) is the documented fallback.
--
-- A no-op where pg_cron is absent (local and release-gate databases) or the
-- job is already gone, so it is safe to replay.
do $$
begin
  if pg_catalog.to_regclass('cron.job') is not null then
    perform cron.unschedule(job.jobid)
    from cron.job as job
    where job.jobname = 'shudo-drain-storage-cleanup';
  end if;
end;
$$;
