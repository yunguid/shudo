import {
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
    ["entry-images", new Set([`${userId}/photo.jpg`])],
    ["entry-audio", new Set([`u_${userId}/voice.m4a`])],
    ["profile-photos", new Set([`${userId}/avatar.jpg`])],
  ]);
  const admin = {
    storage: {
      from(bucket: string) {
        return {
          list(directory: string) {
            const prefix = `${directory}/`;
            const items = [...(objects.get(bucket) ?? [])]
              .filter((path) => path.startsWith(prefix))
              .map((path) => path.slice(prefix.length))
              .filter((name) => !name.includes("/"))
              .map((name) => ({ id: `${bucket}:${name}`, name }));
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

  assertEquals(await deleteAccountStorage(admin as never, userId), 3);
  assertEquals(await deleteAccountStorage(admin as never, userId), 0);
});
