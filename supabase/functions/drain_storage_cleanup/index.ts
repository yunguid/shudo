import "jsr:@supabase/functions-js@2.110.7/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2.110.7";
import { drainStorageCleanup } from "../_shared/storage_cleanup.ts";
import { json, requiredEnv } from "../_shared/http.ts";

async function secretMatches(
  actual: string,
  expected: string,
): Promise<boolean> {
  const encoder = new TextEncoder();
  const [actualDigest, expectedDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(actual)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const left = new Uint8Array(actualDigest);
  const right = new Uint8Array(expectedDigest);
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference === 0;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const suppliedSecret = req.headers.get("x-shudo-cleanup-secret")?.trim() ??
      "";
    const expectedSecret = requiredEnv("SHUDO_CLEANUP_SECRET");
    if (expectedSecret.length < 32) {
      throw new Error(
        "SHUDO_CLEANUP_SECRET must contain at least 32 characters",
      );
    }
    if (
      !suppliedSecret || !await secretMatches(suppliedSecret, expectedSecret)
    ) {
      return json({ error: "Authentication required" }, 401);
    }

    const payload = await req.json().catch(() => null) as
      | { limit?: unknown }
      | null;
    const requestedLimit = typeof payload?.limit === "number"
      ? Math.trunc(payload.limit)
      : 25;
    const admin = createClient(
      requiredEnv("SUPABASE_URL"),
      requiredEnv("SUPABASE_SERVICE_ROLE_KEY"),
      { auth: { persistSession: false, autoRefreshToken: false } },
    );
    const result = await drainStorageCleanup(admin, requestedLimit);
    return json(result);
  } catch (error) {
    console.error("scheduled_storage_cleanup_failed", {
      message: error instanceof Error ? error.message : String(error),
    });
    return json({ error: "Could not drain Storage cleanup jobs" }, 500);
  }
});
