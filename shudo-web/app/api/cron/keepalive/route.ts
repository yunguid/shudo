import {
  cleanupFunctionURL,
  isAuthorizedCronRequest,
  isValidMaintenanceSecret,
  scheduledCleanupLimit,
  weeklySummaryFunctionURL,
} from '@/lib/cron'
import { getSupabasePublicConfig } from '@/lib/supabase/config'

export const dynamic = 'force-dynamic'
export const runtime = 'nodejs'
export const maxDuration = 120

const responseHeaders = {
  'Cache-Control': 'private, no-store, max-age=0',
}

type CronLog = {
  event: string
  request_id: string
  elapsed_ms: number
  [key: string]: string | number | boolean
}

function logCron(level: 'info' | 'warn' | 'error', payload: CronLog) {
  console[level](JSON.stringify(payload))
}

export async function GET(request: Request) {
  const startedAt = performance.now()
  const requestId = request.headers.get('x-vercel-id') ?? crypto.randomUUID()
  const elapsed = () => Math.round(performance.now() - startedAt)
  const secret = process.env.CRON_SECRET
  if (!isAuthorizedCronRequest(request.headers.get('authorization'), secret)) {
    logCron('warn', {
      event: 'shudo_cron_rejected',
      request_id: requestId,
      elapsed_ms: elapsed(),
      status: 401,
      authorization_present: request.headers.has('authorization'),
    })
    return Response.json(
      { ok: false },
      { status: 401, headers: responseHeaders },
    )
  }

  const cleanupSecret = process.env.SHUDO_CLEANUP_SECRET
  const weeklySecret = process.env.SHUDO_WEEKLY_SECRET
  if (!isValidMaintenanceSecret(cleanupSecret) || !isValidMaintenanceSecret(weeklySecret)) {
    logCron('error', {
      event: 'shudo_cron_misconfigured',
      request_id: requestId,
      elapsed_ms: elapsed(),
      status: 503,
      cleanup_secret_valid: isValidMaintenanceSecret(cleanupSecret),
      weekly_secret_valid: isValidMaintenanceSecret(weeklySecret),
    })
    return Response.json(
      { ok: false },
      { status: 503, headers: responseHeaders },
    )
  }

  try {
    logCron('info', {
      event: 'shudo_cron_started',
      request_id: requestId,
      elapsed_ms: elapsed(),
    })
    const { url } = getSupabasePublicConfig()
    const [cleanup, weekly] = await Promise.all([
      fetch(cleanupFunctionURL(url), {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-shudo-cleanup-secret': cleanupSecret,
        },
        body: JSON.stringify({ limit: scheduledCleanupLimit }),
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
      const cleanupStatus = cleanup.status
      const weeklyStatus = weekly.status
      await Promise.all([cleanup.body?.cancel(), weekly.body?.cancel()])
      logCron('error', {
        event: 'shudo_cron_downstream_failed',
        request_id: requestId,
        elapsed_ms: elapsed(),
        status: 502,
        cleanup_status: cleanupStatus,
        weekly_status: weeklyStatus,
      })
      return Response.json(
        { ok: false, cleanup: cleanup.ok, weekly: weekly.ok },
        { status: 502, headers: responseHeaders },
      )
    }

    await Promise.all([cleanup.body?.cancel(), weekly.body?.cancel()])
    logCron('info', {
      event: 'shudo_cron_succeeded',
      request_id: requestId,
      elapsed_ms: elapsed(),
      cleanup_status: cleanup.status,
      weekly_status: weekly.status,
    })
    return Response.json(
      { ok: true, cleanup: true, weekly: true },
      { headers: responseHeaders },
    )
  } catch (error) {
    logCron('error', {
      event: 'shudo_cron_exception',
      request_id: requestId,
      elapsed_ms: elapsed(),
      status: 503,
      error_name: error instanceof Error ? error.name : 'UnknownError',
    })
    return Response.json(
      { ok: false },
      { status: 503, headers: responseHeaders },
    )
  }
}
