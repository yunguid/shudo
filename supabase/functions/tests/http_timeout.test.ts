import { withTimeout } from "../_shared/http.ts";
import { assertEquals } from "./assertions.ts";

Deno.test("withTimeout passes through a fast success and failure", async () => {
  assertEquals(await withTimeout(Promise.resolve("ok"), 1_000, "fast"), "ok");

  let message = "";
  try {
    await withTimeout(Promise.reject(new Error("boom")), 1_000, "fast");
  } catch (error) {
    message = error instanceof Error ? error.message : "";
  }
  assertEquals(message, "boom");
});

Deno.test("withTimeout converts a hang into a labeled failure", async () => {
  let resolveLater: (value: string) => void = () => {};
  const hung = new Promise<string>((resolve) => {
    resolveLater = resolve;
  });

  let message = "";
  try {
    await withTimeout(hung, 10, "Session validation");
  } catch (error) {
    message = error instanceof Error ? error.message : "";
  }
  assertEquals(message, "Session validation timed out");
  // A late settle after the timeout must be absorbed silently — a rejection
  // here would otherwise surface as an unhandled rejection in the worker.
  resolveLater("late");
  await new Promise((resolve) => setTimeout(resolve, 20));
});

Deno.test("withTimeout absorbs a rejection that loses the race", async () => {
  let rejectLater: (error: Error) => void = () => {};
  const hung = new Promise<string>((_, reject) => {
    rejectLater = reject;
  });

  let timedOut = false;
  try {
    await withTimeout(hung, 10, "Photo upload");
  } catch {
    timedOut = true;
  }
  assertEquals(timedOut, true);
  rejectLater(new Error("late failure"));
  // Give the microtask queue a beat; an unhandled rejection would fail the
  // test run under Deno's default unhandled-rejection behavior.
  await new Promise((resolve) => setTimeout(resolve, 20));
});
