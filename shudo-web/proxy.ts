import { createServerClient, type CookieOptions } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'
import { getSupabasePublicConfig } from '@/lib/supabase/config'
import type { Database } from '@/types/database'

type AuthCookie = { name: string; value: string; options: CookieOptions }

export async function proxy(request: NextRequest) {
  const path = request.nextUrl.pathname
  // Vercel invokes this system route with CRON_SECRET, not a Supabase user
  // cookie. The route performs its own timing-safe Bearer authentication.
  if (path === '/api/cron/keepalive') {
    return NextResponse.next({ request })
  }

  let response = NextResponse.next({ request })
  const { url, key } = getSupabasePublicConfig()
  const authCookies: AuthCookie[] = []
  const authHeaders: Record<string, string> = {}

  function applyAuthState(target: NextResponse) {
    authCookies.forEach(({ name, value, options }) => {
      target.cookies.set(name, value, options)
    })
    Object.entries(authHeaders).forEach(([name, value]) => {
      target.headers.set(name, value)
    })
    return target
  }

  const supabase = createServerClient<Database>(url, key, {
    cookies: {
      getAll() {
        return request.cookies.getAll()
      },
      setAll(cookiesToSet, headersToSet) {
        authCookies.push(...cookiesToSet)
        Object.assign(authHeaders, headersToSet)
        cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value))
        response = NextResponse.next({ request })
        applyAuthState(response)
      },
    },
  })

  const {
    data: { user },
    error,
  } = await supabase.auth.getUser()

  const isAuthRoute = path.startsWith('/auth/')

  const sessionIsMissing = error && [400, 401, 403].includes(error.status ?? 0)

  if (!user && (!error || sessionIsMissing) && !isAuthRoute) {
    const loginUrl = request.nextUrl.clone()
    loginUrl.pathname = '/auth/login'
    loginUrl.search = ''
    return applyAuthState(NextResponse.redirect(loginUrl))
  }

  if (user && path === '/auth/login') {
    const dashboardUrl = request.nextUrl.clone()
    dashboardUrl.pathname = '/'
    dashboardUrl.search = ''
    return applyAuthState(NextResponse.redirect(dashboardUrl))
  }

  return response
}

export const config = {
  matcher: [
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)',
  ],
}
