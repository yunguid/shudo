import {
  ACCOUNT_BUCKETS,
  ACCOUNT_DELETION_FAILURE_MESSAGE,
  ACCOUNT_DELETION_RETRY_MESSAGE,
  accountDeletionFailureMessage,
  deleteAccountStorage,
  requireAccountDeletionConfirmation,
  storageItemIsFile,
} from "../_shared/account_deletion.ts";
import { assert, assertEquals, assertThrows } from "./assertions.ts";

Deno.test("account deletion requires an explicit destructive confirmation", () => {
  requireAccountDeletionConfirmation({ confirmation: "DELETE" });
  assertThrows(
    () => requireAccountDeletionConfirmation({ confirmation: "delete" }),
    400,
    "Type DELETE",
  );
});

Deno.test("storage traversal distinguishes folder placeholders from files", () => {
  assert(!storageItemIsFile({ id: null, name: "entry-folder" }));
  assert(storageItemIsFile({ id: "object-id", name: "photo.jpg" }));
  assert(storageItemIsFile({ name: "voice.m4a", metadata: { size: 10 } }));
});

Deno.test("account deletion failure copy distinguishes pre-storage and partial deletion", () => {
  assertEquals(
    accountDeletionFailureMessage(false),
    ACCOUNT_DELETION_FAILURE_MESSAGE,
  );
  assertEquals(
    accountDeletionFailureMessage(true),
    ACCOUNT_DELETION_RETRY_MESSAGE,
  );
  assert(
    ACCOUNT_DELETION_RETRY_MESSAGE.includes("may already have been removed"),
  );
  assert(ACCOUNT_DELETION_RETRY_MESSAGE.includes("safe to try again"));
});

Deno.test("storage-first account deletion is idempotent across retries", async () => {
  const userId = "00000000-0000-4000-8000-000000000001";
  const objects = new Map<string, Set<string>>([
    ["entry-images", new Set([`${userId}/photo.jpg`, `${userId}/other.jpg`])],
    ["entry-audio", new Set([`u_${userId}/voice.m4a`])],
    ["profile-photos", new Set([`${userId}/avatar.jpg`])],
    [
      "weight-checkin-photos",
      new Set([`${userId}/2026-10-06/progress-photo.jpg`]),
    ],
    [
      "coach-media",
      new Set([
        `${userId}/2026-10-06/chat-photo.jpg`,
        `${userId}/2026-10-06/activity-photo.jpg`,
      ]),
    ],
  ]);
  const admin = {
    storage: {
      from(bucket: string) {
        return {
          list(directory: string) {
            // Storage lists direct children: files carry an id, nested
            // folders (dated check-in and coach-media paths) do not.
            const prefix = `${directory}/`;
            const children = new Map<string, string | null>();
            for (const path of objects.get(bucket) ?? []) {
              if (!path.startsWith(prefix)) continue;
              const [name, ...rest] = path.slice(prefix.length).split("/");
              children.set(name, rest.length ? null : `${bucket}:${name}`);
            }
            const items = [...children].map(([name, id]) => ({ id, name }));
            return { data: items, error: null };
          },
          remove(paths: string[]) {
            const bucketObjects = objects.get(bucket);
            for (const path of paths) bucketObjects?.delete(path);
            return { error: null };
          },
        };
      },
    },
  };

  assertEquals(await deleteAccountStorage(admin as never, userId), 7);
  assertEquals(await deleteAccountStorage(admin as never, userId), 0);
  for (const [bucket, paths] of objects) {
    assertEquals([bucket, paths.size], [bucket, 0]);
  }
});

Deno.test("account deletion covers every private user bucket", () => {
  // Auth refuses to delete a user who still owns Storage objects, so each
  // bucket that stores user uploads must be drained before the Auth delete.
  assertEquals([...ACCOUNT_BUCKETS].sort(), [
    "coach-media",
    "entry-audio",
    "entry-images",
    "profile-photos",
    "weight-checkin-photos",
  ]);
});

Deno.test("account deletion never lists outside the user's own prefixes", async () => {
  const listed: Array<[string, string]> = [];
  const admin = {
    storage: {
      from(bucket: string) {
        return {
          list(directory: string) {
            listed.push([bucket, directory]);
            return { data: [], error: null };
          },
          remove() {
            throw new Error("Nothing should be removed");
          },
        };
      },
    },
  };
  const userId = "00000000-0000-4000-8000-0000000000c1";
  assertEquals(await deleteAccountStorage(admin as never, userId), 0);
  assertEquals(listed.length, ACCOUNT_BUCKETS.length * 2);
  assert(
    listed.every(([, directory]) =>
      directory === userId || directory === `u_${userId}`
    ),
  );
  await assertRejects(
    () => deleteAccountStorage(admin as never, "../other-user"),
    "unsafe account storage prefix",
  );
});

async function assertRejects(
  action: () => Promise<unknown>,
  messageIncludes: string,
): Promise<void> {
  try {
    await action();
  } catch (error) {
    assert(error instanceof Error && error.message.includes(messageIncludes));
    return;
  }
  throw new Error("Expected action to reject");
}
