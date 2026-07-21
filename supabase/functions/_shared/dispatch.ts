import { requiredEnv } from "./http.ts";

const DISPATCH_TIMEOUT_MS = 10_000;

/**
 * Starts processing in a fresh Edge Function worker so upload time does not
 * consume the processor's wall-clock budget. The original user's credentials
 * are forwarded; process_entry authenticates and applies the owner guard again.
 */
export async function dispatchStoredEntry(
  req: Request,
  entryId: string,
): Promise<void> {
  const authorization = req.headers.get("authorization")?.trim();
  if (!authorization) throw new Error("Cannot dispatch without authorization");

  // Use the trusted server configuration for the gateway key. The caller's
  // session is forwarded separately and is authenticated again by
  // process_entry; accepting a caller-supplied apikey would let a malformed
  // header break an otherwise durable capture's dispatch.
  const apikey = requiredEnv("SUPABASE_ANON_KEY");
  const supabaseUrl = requiredEnv("SUPABASE_URL").replace(/\/+$/, "");
  const response = await fetch(`${supabaseUrl}/functions/v1/process_entry`, {
    method: "POST",
    headers: {
      authorization,
      apikey,
      "content-type": "application/json",
    },
    body: JSON.stringify({ entry_id: entryId }),
    signal: AbortSignal.timeout(DISPATCH_TIMEOUT_MS),
  });

  if (!response.ok) {
    throw new Error(`Processing dispatch failed (${response.status})`);
  }
}
