import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";

const CLEANUP_LEASE_SECONDS = 120;
const MAX_CLEANUP_BATCH = 50;

type CleanupJob = {
  id: string;
  bucket: "entry-images" | "entry-audio";
  mode: "object" | "prefix";
  object_path: string;
  lease_token: string;
  attempts: number;
};

export type CleanupDrainResult = {
  claimed: number;
  completed: number;
  failed: number;
};

function cleanupMessage(error: unknown): string {
  return (error instanceof Error ? error.message : String(error)).slice(0, 500);
}

async function removeCleanupTarget(
  admin: SupabaseClient,
  job: CleanupJob,
): Promise<void> {
  const storage = admin.storage.from(job.bucket);
  if (job.mode === "object") {
    const { error } = await storage.remove([job.object_path]);
    if (error) throw error;
    return;
  }

  // Stale upload tokens each own a private folder containing at most one object
  // per bucket. Prefix jobs are delayed in SQL until the stale Edge worker's
  // hard lifetime has elapsed, so an empty listing is a durable success.
  const folder = job.object_path.replace(/\/+$/, "");
  const { data, error: listError } = await storage.list(folder, { limit: 20 });
  if (listError) throw listError;
  const paths = (data ?? []).map((item) => `${folder}/${item.name}`);
  if (!paths.length) return;
  const { error: removeError } = await storage.remove(paths);
  if (removeError) throw removeError;
}

export async function drainStorageCleanup(
  admin: SupabaseClient,
  requestedLimit = 10,
): Promise<CleanupDrainResult> {
  const normalizedLimit = Number.isFinite(requestedLimit)
    ? Math.trunc(requestedLimit)
    : 10;
  const limit = Math.max(1, Math.min(MAX_CLEANUP_BATCH, normalizedLimit));
  const { data, error } = await admin.rpc("claim_storage_cleanup", {
    p_limit: limit,
    p_lease_seconds: CLEANUP_LEASE_SECONDS,
  });
  if (error) throw error;

  const jobs = Array.isArray(data) ? data as CleanupJob[] : [];
  const result: CleanupDrainResult = {
    claimed: jobs.length,
    completed: 0,
    failed: 0,
  };

  for (const job of jobs) {
    try {
      await removeCleanupTarget(admin, job);
      const { data: completed, error: completeError } = await admin.rpc(
        "complete_storage_cleanup",
        { p_job_id: job.id, p_lease_token: job.lease_token },
      );
      if (completeError) throw completeError;
      if (completed !== true) {
        throw new Error("Storage cleanup lease was replaced");
      }
      result.completed += 1;
    } catch (error) {
      result.failed += 1;
      const message = cleanupMessage(error);
      console.error("storage_cleanup_job_failed", {
        jobId: job.id,
        bucket: job.bucket,
        attempts: job.attempts,
        message,
      });
      const { error: failError } = await admin.rpc("fail_storage_cleanup", {
        p_job_id: job.id,
        p_lease_token: job.lease_token,
        p_error_message: message,
      });
      if (failError) {
        console.error("storage_cleanup_failure_state_failed", {
          jobId: job.id,
          message: failError.message,
        });
      }
    }
  }

  return result;
}
