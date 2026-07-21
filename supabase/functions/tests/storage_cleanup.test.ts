import { drainStorageCleanup } from "../_shared/storage_cleanup.ts";
import { assertEquals } from "./assertions.ts";

type CleanupJobFixture = {
  id: string;
  bucket: "entry-images" | "entry-audio";
  mode: "object" | "prefix";
  object_path: string;
  lease_token: string;
  attempts: number;
};

type RpcCall = {
  name: string;
  args: Record<string, unknown>;
};

type StorageCall = {
  operation: "list" | "remove";
  bucket: string;
  paths: string[];
};

function cleanupAdmin(
  jobs: CleanupJobFixture[],
  options: {
    listedNames?: string[];
    removeError?: Error;
    completeResult?: boolean;
  } = {},
) {
  const rpcCalls: RpcCall[] = [];
  const storageCalls: StorageCall[] = [];
  const admin = {
    rpc(name: string, args: Record<string, unknown>) {
      rpcCalls.push({ name, args });
      if (name === "claim_storage_cleanup") {
        return { data: jobs, error: null };
      }
      if (name === "complete_storage_cleanup") {
        return { data: options.completeResult ?? true, error: null };
      }
      if (name === "fail_storage_cleanup") {
        return { data: true, error: null };
      }
      throw new Error(`Unexpected RPC: ${name}`);
    },
    storage: {
      from(bucket: string) {
        return {
          list(folder: string) {
            storageCalls.push({
              operation: "list" as const,
              bucket,
              paths: [folder],
            });
            return {
              data: (options.listedNames ?? []).map((name) => ({ name })),
              error: null,
            };
          },
          remove(paths: string[]) {
            storageCalls.push({
              operation: "remove" as const,
              bucket,
              paths,
            });
            return { error: options.removeError ?? null };
          },
        };
      },
    },
  };
  return { admin, rpcCalls, storageCalls };
}

function job(
  overrides: Partial<CleanupJobFixture> = {},
): CleanupJobFixture {
  return {
    id: "job-1",
    bucket: "entry-images",
    mode: "object",
    object_path: "user/entry/photo.jpg",
    lease_token: "lease-1",
    attempts: 1,
    ...overrides,
  };
}

Deno.test("cleanup batch limits are clamped before claiming jobs", async () => {
  const upper = cleanupAdmin([]);
  assertEquals(
    await drainStorageCleanup(upper.admin as never, 5_000),
    { claimed: 0, completed: 0, failed: 0 },
  );
  assertEquals(upper.rpcCalls[0], {
    name: "claim_storage_cleanup",
    args: { p_limit: 50, p_lease_seconds: 120 },
  });

  const lower = cleanupAdmin([]);
  await drainStorageCleanup(lower.admin as never, 0);
  assertEquals(lower.rpcCalls[0].args.p_limit, 1);

  const fractional = cleanupAdmin([]);
  await drainStorageCleanup(fractional.admin as never, 4.9);
  assertEquals(fractional.rpcCalls[0].args.p_limit, 4);

  const invalid = cleanupAdmin([]);
  await drainStorageCleanup(invalid.admin as never, Number.NaN);
  assertEquals(invalid.rpcCalls[0].args.p_limit, 10);
});

Deno.test("object cleanup removes the exact path then completes its lease", async () => {
  const fake = cleanupAdmin([job()]);
  assertEquals(
    await drainStorageCleanup(fake.admin as never, 10),
    { claimed: 1, completed: 1, failed: 0 },
  );
  assertEquals(fake.storageCalls, [{
    operation: "remove",
    bucket: "entry-images",
    paths: ["user/entry/photo.jpg"],
  }]);
  assertEquals(fake.rpcCalls[1], {
    name: "complete_storage_cleanup",
    args: { p_job_id: "job-1", p_lease_token: "lease-1" },
  });
});

Deno.test("prefix cleanup lists one folder and removes every returned object", async () => {
  const fake = cleanupAdmin([
    job({
      bucket: "entry-audio",
      mode: "prefix",
      object_path: "user/entry/upload-token///",
    }),
  ], { listedNames: ["voice.m4a", "retry.m4a"] });

  assertEquals(
    await drainStorageCleanup(fake.admin as never),
    { claimed: 1, completed: 1, failed: 0 },
  );
  assertEquals(fake.storageCalls, [
    {
      operation: "list",
      bucket: "entry-audio",
      paths: ["user/entry/upload-token"],
    },
    {
      operation: "remove",
      bucket: "entry-audio",
      paths: [
        "user/entry/upload-token/voice.m4a",
        "user/entry/upload-token/retry.m4a",
      ],
    },
  ]);
});

Deno.test("cleanup failure is durably recorded with the active lease", async () => {
  const fake = cleanupAdmin([job()], {
    removeError: new Error("storage unavailable"),
  });
  const originalError = console.error;
  console.error = () => {};
  try {
    assertEquals(
      await drainStorageCleanup(fake.admin as never),
      { claimed: 1, completed: 0, failed: 1 },
    );
  } finally {
    console.error = originalError;
  }
  assertEquals(fake.rpcCalls[1], {
    name: "fail_storage_cleanup",
    args: {
      p_job_id: "job-1",
      p_lease_token: "lease-1",
      p_error_message: "storage unavailable",
    },
  });
});

Deno.test("a replaced completion lease is treated as a failed job", async () => {
  const fake = cleanupAdmin([job()], { completeResult: false });
  const originalError = console.error;
  console.error = () => {};
  try {
    assertEquals(
      await drainStorageCleanup(fake.admin as never),
      { claimed: 1, completed: 0, failed: 1 },
    );
  } finally {
    console.error = originalError;
  }
  assertEquals(fake.rpcCalls.map((call) => call.name), [
    "claim_storage_cleanup",
    "complete_storage_cleanup",
    "fail_storage_cleanup",
  ]);
});
