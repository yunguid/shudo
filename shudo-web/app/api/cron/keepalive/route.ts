import {
  cleanupFunctionURL,
  isAuthorizedCronRequest,
  isValidMaintenanceSecret,
  weeklySummaryFunctionURL,
} from '@/lib/cron'
import { getSupabasePublicConfig } from '@/lib/supabase/config'

export const dynamic = 'force-dynamic'
export const runtime = 'nodejs'
export const maxDuration = 120

const responseHeaders = {
  'Cache-Control': 'private, no-store, max-age=0',
}

export async function GET(request: Request) {
  const secret = process.env.CRON_SECRET
  if (!isAuthorizedCronRequest(request.headers.get('authorization'), secret)) {
    return Response.json(
      { ok: false },
      { status: 401, headers: responseHeaders },
    )
  }

  const cleanupSecret = process.env.SHUDO_CLEANUP_SECRET
  const weeklySecret = process.env.SHUDO_WEEKLY_SECRET
  if (!isValidMaintenanceSecret(cleanupSecret) || !isValidMaintenanceSecret(weeklySecret)) {
    return Response.json(
      { ok: false },
      { status: 503, headers: responseHeaders },
    )
  }

  try {
    const { url } = getSupabasePublicConfig()
    const [cleanup, weekly] = await Promise.all([
      fetch(cleanupFunctionURL(url), {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-shudo-cleanup-secret': cleanupSecret,
        },
        body: JSON.stringify({ limit: 25 }),
        cache: 'no-store',
        signal: AbortSignal.timeout(20_000),
      }),
      fetch(weeklySummaryFunctionURL(url), {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-shudo-weekly-secret': weeklySecret,
        },
        body: JSON.stringify({ limit: 5 }),
        cache: 'no-store',
        signal: AbortSignal.timeout(100_000),
      }),
    ])

    if (!cleanup.ok || !weekly.ok) {
      await Promise.all([cleanup.body?.cancel(), weekly.body?.cancel()])
      return Response.json(
        { ok: false, cleanup: cleanup.ok, weekly: weekly.ok },
        { status: 502, headers: responseHeaders },
      )
    }

    await Promise.all([cleanup.body?.cancel(), weekly.body?.cancel()])
    return Response.json(
      { ok: true, cleanup: true, weekly: true },
      { headers: responseHeaders },
    )
  } catch {
    return Response.json(
      { ok: false },
      { status: 503, headers: responseHeaders },
    )
  }
}
