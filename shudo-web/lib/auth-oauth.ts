import { safeInternalPath } from '@/lib/utils'

export const SHUDO_OAUTH_PROVIDERS = ['google', 'apple'] as const

export type ShudoOAuthProvider = (typeof SHUDO_OAUTH_PROVIDERS)[number]

export function enabledOAuthProvidersFromSettings(value: unknown): ShudoOAuthProvider[] {
  if (!value || typeof value !== 'object' || !('external' in value)) return []
  const external = value.external
  if (!external || typeof external !== 'object') return []
  return SHUDO_OAUTH_PROVIDERS.filter(
    (provider) => provider in external && external[provider as keyof typeof external] === true,
  )
}

export async function fetchEnabledOAuthProviders(
  signal?: AbortSignal,
): Promise<ShudoOAuthProvider[]> {
  const baseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
  const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
  if (!baseUrl || !publishableKey) return []

  try {
    const response = await fetch(`${baseUrl}/auth/v1/settings`, {
      cache: 'no-store',
      headers: { apikey: publishableKey },
      signal,
    })
    if (!response.ok) return []
    return enabledOAuthProvidersFromSettings(await response.json())
  } catch {
    return []
  }
}

export function buildOAuthCallbackUrl(origin: string, nextPath = '/'): string {
  const callback = new URL('/auth/callback', origin)
  callback.searchParams.set('next', safeInternalPath(nextPath))
  return callback.toString()
}
