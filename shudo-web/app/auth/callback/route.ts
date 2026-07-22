import { createServerClient, type CookieOptions } from '@supabase/ssr'
import type { EmailOtpType } from '@supabase/supabase-js'
import { cookies } from 'next/headers'
import { NextResponse } from 'next/server'
import { authCallbackErrorReason } from '@/lib/auth-errors'
import { getSupabasePublicConfig } from '@/lib/supabase/config'
import { safeInternalPath } from '@/lib/utils'
import type { Database } from '@/types/database'

const EMAIL_OTP_TYPES = new Set<EmailOtpType>([
  'email',
  'email_change',
  'invite',
  'magiclink',
  'recovery',
  'signup',
])

type AuthCookie = { name: string; value: string; options: CookieOptions }

export async function GET(request: Request) {
  const { searchParams, origin } = new URL(request.url)
  const code = searchParams.get('code')
  const token_hash = searchParams.get('token_hash')
  const type = searchParams.get('type')
  const returnPath = safeInternalPath(searchParams.get('next'))

  const cookieStore = await cookies()
  const { url, key } = getSupabasePublicConfig()
  const authCookies: AuthCookie[] = []
  const authHeaders: Record<string, string> = {}
  let callbackError: unknown

  function redirectWithAuthState(path: string) {
    const response = NextResponse.redirect(new URL(path, origin))
    authCookies.forEach(({ name, value, options }) => {
      response.cookies.set(name, value, options)
    })
    Object.entries(authHeaders).forEach(([name, value]) => {
      response.headers.set(name, value)
    })
    if (!response.headers.has('Cache-Control')) {
      response.headers.set('Cache-Control', 'private, no-store')
    }
    return response
  }

  const supabase = createServerClient<Database>(url, key, {
    cookies: {
      getAll() {
        return cookieStore.getAll()
      },
      setAll(cookiesToSet, headersToSet) {
        authCookies.push(...cookiesToSet)
        Object.assign(authHeaders, headersToSet)
      },
    },
  })

  // Handle PKCE code exchange
  if (code) {
    const { error } = await supabase.auth.exchangeCodeForSession(code)
    if (!error) {
      return redirectWithAuthState(returnPath)
    }
    callbackError = error
  }

  // Handle magic link token hash (email OTP)
  if (token_hash && type && EMAIL_OTP_TYPES.has(type as EmailOtpType)) {
    const { error } = await supabase.auth.verifyOtp({
      token_hash,
      type: type as EmailOtpType,
    })
    if (!error) {
      return redirectWithAuthState(returnPath)
    }
    callbackError = error
  }

  // Return the user to an error page with instructions
  const reason = authCallbackErrorReason(callbackError)
  return redirectWithAuthState(`/auth/login?error=auth&reason=${reason}`)
}
