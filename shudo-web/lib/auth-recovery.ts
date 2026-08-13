export type RecoveryFragmentResult =
  | { ok: true; accessToken: string }
  | { ok: false }

type Fetcher = (
  input: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>

export function parseRecoveryFragment(fragment: string): RecoveryFragmentResult {
  const params = new URLSearchParams(fragment.startsWith('#') ? fragment.slice(1) : fragment)
  const accessToken = params.get('access_token')?.trim()

  if (params.has('error') || params.get('type') !== 'recovery' || !accessToken) {
    return { ok: false }
  }

  return { ok: true, accessToken }
}

export function urlWithoutFragment(pathname: string, search: string): string {
  return `${pathname}${search}`
}

interface RequestPasswordRecoveryOptions {
  projectUrl: string
  publicKey: string
  email: string
  redirectTo: string
  fetcher?: Fetcher
}

/**
 * Raw REST call instead of the PKCE browser client: without a code
 * challenge, the recovery email carries hash tokens that work in whatever
 * browser opens the link — same contract the iOS recovery flow relies on.
 */
export async function requestPasswordRecovery({
  projectUrl,
  publicKey,
  email,
  redirectTo,
  fetcher = fetch,
}: RequestPasswordRecoveryOptions): Promise<boolean> {
  try {
    const endpoint = new URL('/auth/v1/recover', `${projectUrl.replace(/\/$/, '')}/`)
    endpoint.searchParams.set('redirect_to', redirectTo)
    const response = await fetcher(endpoint, {
      method: 'POST',
      headers: {
        apikey: publicKey,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ email }),
      cache: 'no-store',
      credentials: 'omit',
      redirect: 'error',
      referrerPolicy: 'no-referrer',
    })

    return response.ok
  } catch {
    return false
  }
}

interface UpdateRecoveryPasswordOptions {
  projectUrl: string
  publicKey: string
  accessToken: string
  password: string
  fetcher?: Fetcher
}

export async function updateRecoveryPassword({
  projectUrl,
  publicKey,
  accessToken,
  password,
  fetcher = fetch,
}: UpdateRecoveryPasswordOptions): Promise<boolean> {
  try {
    const endpoint = new URL('/auth/v1/user', `${projectUrl.replace(/\/$/, '')}/`)
    const response = await fetcher(endpoint, {
      method: 'PUT',
      headers: {
        apikey: publicKey,
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ password }),
      cache: 'no-store',
      credentials: 'omit',
      redirect: 'error',
      referrerPolicy: 'no-referrer',
    })

    return response.ok
  } catch {
    return false
  }
}
