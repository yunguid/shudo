import { cleanupFunctionURL, isAuthorizedCronRequest } from '@/lib/cron'
import { getSupabasePublicConfig } from '@/lib/supabase/config'

export const dynamic = 'force-dynamic'
export const runtime = 'nodejs'
export const maxDuration = 20

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

  try {
    const { url } = getSupabasePublicConfig()
    const upstream = await fetch(cleanupFunctionURL(url), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-shudo-cleanup-secret': secret!,
      },
      body: JSON.stringify({ limit: 25 }),
      cache: 'no-store',
      signal: AbortSignal.timeout(15_000),
    })

    if (!upstream.ok) {
      await upstream.body?.cancel()
      return Response.json(
        { ok: false },
        { status: 502, headers: responseHeaders },
      )
    }

    await upstream.body?.cancel()
    return Response.json({ ok: true }, { headers: responseHeaders })
  } catch {
    return Response.json(
      { ok: false },
      { status: 503, headers: responseHeaders },
    )
  }
}
