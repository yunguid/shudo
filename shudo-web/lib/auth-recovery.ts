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
