import type { SupabaseClient } from "jsr:@supabase/supabase-js@2.110.7";
import { HttpError } from "./errors.ts";
import { isUuid } from "./http.ts";

const STORAGE_PAGE_SIZE = 100;
const STORAGE_REMOVE_BATCH = 100;
const ACCOUNT_BUCKETS = [
  "entry-images",
  "entry-audio",
  "profile-photos",
] as const;

export const ACCOUNT_DELETION_RETRY_MESSAGE =
  "Couldn’t finish deleting the account. Some uploaded files may already have been removed; it’s safe to try again.";

export const ACCOUNT_DELETION_FAILURE_MESSAGE =
  "Couldn’t delete the account. Please try again.";

type StorageListItem = {
  id?: string | null;
  name: string;
  metadata?: unknown;
};

export function requireAccountDeletionConfirmation(payload: unknown): void {
  if (
    !payload || typeof payload !== "object" || Array.isArray(payload) ||
    (payload as Record<string, unknown>).confirmation !== "DELETE"
  ) {
    throw new HttpError(400, "Type DELETE to confirm account deletion");
  }
}

export function accountDeletionFailureMessage(
  storageDeletionStarted: boolean,
): string {
  return storageDeletionStarted
    ? ACCOUNT_DELETION_RETRY_MESSAGE
    : ACCOUNT_DELETION_FAILURE_MESSAGE;
}

export function storageItemIsFile(item: StorageListItem): boolean {
  return typeof item.id === "string" && item.id.length > 0 ||
    item.metadata !== undefined && item.metadata !== null;
}

async function listAllFiles(
  admin: SupabaseClient,
  bucket: string,
  rootPrefix: string,
): Promise<string[]> {
  const directories = [rootPrefix.replace(/\/+$/, "")];
  const files: string[] = [];

  while (directories.length > 0) {
    const directory = directories.shift()!;
    let offset = 0;
    while (true) {
      const { data, error } = await admin.storage.from(bucket).list(directory, {
        limit: STORAGE_PAGE_SIZE,
        offset,
        sortBy: { column: "name", order: "asc" },
      });
      if (error) throw error;
      const page = (data ?? []) as StorageListItem[];
      for (const item of page) {
        const path = `${directory}/${item.name}`;
        if (storageItemIsFile(item)) files.push(path);
        else directories.push(path);
      }
      if (page.length < STORAGE_PAGE_SIZE) break;
      offset += page.length;
    }
  }

  return files;
}

async function removePaths(
  admin: SupabaseClient,
  bucket: string,
  paths: string[],
): Promise<void> {
  for (let index = 0; index < paths.length; index += STORAGE_REMOVE_BATCH) {
    const { error } = await admin.storage.from(bucket).remove(
      paths.slice(index, index + STORAGE_REMOVE_BATCH),
    );
    if (error) throw error;
  }
}

export async function deleteAccountStorage(
  admin: SupabaseClient,
  userId: string,
): Promise<number> {
  if (!isUuid(userId)) {
    throw new Error("Refusing unsafe account storage prefix");
  }
  // The bucket/prefix passes are independent; clearing them together keeps
  // deletion time bounded by the largest bucket instead of the sum of all six.
  const passes = ACCOUNT_BUCKETS.flatMap((bucket) =>
    [userId, `u_${userId}`].map(async (prefix) => {
      const paths = await listAllFiles(admin, bucket, prefix);
      await removePaths(admin, bucket, paths);
      return paths.length;
    })
  );
  const results = await Promise.allSettled(passes);
  const failure = results.find(
    (result): result is PromiseRejectedResult => result.status === "rejected",
  );
  if (failure) throw failure.reason;
  return results.reduce(
    (total, result) =>
      total + (result.status === "fulfilled" ? result.value : 0),
    0,
  );
}
