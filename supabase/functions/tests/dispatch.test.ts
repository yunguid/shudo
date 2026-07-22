import { scheduleStoredEntryDispatch } from "../_shared/dispatch.ts";
import { assertEquals } from "./assertions.ts";

Deno.test("stored entry dispatch is observed without delaying the request", async () => {
  const pendingDispatch = Promise.withResolvers<void>();
  let observed: Promise<unknown> | null = null;
  let started = false;
  let settled = false;

  scheduleStoredEntryDispatch(
    new Request("https://example.test/create"),
    "50000000-0000-4000-8000-000000000001",
    {
      dispatch: () => {
        started = true;
        return pendingDispatch.promise;
      },
      observe: (promise) => {
        observed = promise;
        promise.finally(() => {
          settled = true;
        });
      },
    },
  );

  assertEquals(started, true);
  assertEquals(observed !== null, true);
  assertEquals(settled, false);
  pendingDispatch.resolve();
  await observed;
});

Deno.test("background dispatch failures are observed and remain recoverable", async () => {
  let observed: Promise<unknown> | null = null;
  let failure = "";
  scheduleStoredEntryDispatch(
    new Request("https://example.test/resume"),
    "50000000-0000-4000-8000-000000000002",
    {
      dispatch: () => Promise.reject(new Error("nested timeout")),
      observe: (promise) => {
        observed = promise;
      },
      onFailure: (error) => {
        failure = error instanceof Error ? error.message : String(error);
      },
    },
  );
  if (!observed) {
    throw new Error("Dispatch was not registered as background work");
  }
  await observed;
  assertEquals(failure, "nested timeout");
});
