import {
  createClient,
  type SupabaseClient,
} from "jsr:@supabase/supabase-js@2.110.7";
import { HttpError } from "./errors.ts";

export { HttpError } from "./errors.ts";

export const CORS_HEADERS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type",
  "access-control-allow-methods": "POST, OPTIONS",
};

export type AuthenticatedContext = {
  admin: SupabaseClient;
  accessToken: string;
  userId: string;
};

type SupabaseEdgeRuntime = typeof globalThis & {
  EdgeRuntime: {
    waitUntil<T>(promise: Promise<T>): Promise<T>;
  };
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...CORS_HEADERS,
      "content-type": "application/json; charset=utf-8",
    },
  });
}

const cachedEnv = new Map<string, string>();

export function requiredEnv(name: string): string {
  const cached = cachedEnv.get(name);
  if (cached) return cached;
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing server configuration: ${name}`);
  cachedEnv.set(name, value);
  return value;
}

/**
 * Bounds a promise that has no native abort support (Supabase Auth/Storage/
 * PostgREST SDK calls). The underlying request may still complete in the
 * background; callers rely on fenced writes for correctness, so the timeout
 * only converts an indefinite hang into a clean, retryable failure.
 */
export function withTimeout<T>(
  promise: Promise<T>,
  timeoutMs: number,
  label: string,
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let settled = false;
    const timer = setTimeout(() => {
      settled = true;
      reject(new Error(`${label} timed out`));
    }, timeoutMs);
    promise.then(
      (value) => {
        clearTimeout(timer);
        if (!settled) resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        // A rejection after the timeout already surfaced must not become an
        // unhandled rejection that kills the isolate.
        if (!settled) reject(error);
      },
    );
  });
}

export function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

export function runInBackground(promise: Promise<unknown>): void {
  (globalThis as SupabaseEdgeRuntime).EdgeRuntime.waitUntil(promise);
}

export async function authenticate(
  req: Request,
): Promise<AuthenticatedContext> {
  const supabaseUrl = requiredEnv("SUPABASE_URL");
  const anonKey = requiredEnv("SUPABASE_ANON_KEY");
  const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");

  const token = (req.headers.get("authorization")?.trim() ?? "").replace(
    /^Bearer\s+/i,
    "",
  );
  if (!token) throw new HttpError(401, "Authentication required");

  const authClient = createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await withTimeout(
    authClient.auth.getUser(token),
    10_000,
    "Session validation",
  );
  if (error || !data.user) throw new HttpError(401, "Invalid session");

  return {
    admin: createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    }),
    accessToken: token,
    userId: data.user.id,
  };
}
