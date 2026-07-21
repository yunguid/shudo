import { timingSafeEqual } from 'node:crypto'

const minimumSecretLength = 32

export function isAuthorizedCronRequest(
  authorization: string | null,
  secret: string | undefined,
): boolean {
  if (!secret || secret.length < minimumSecretLength || !authorization) {
    return false
  }

  const actual = Buffer.from(authorization)
  const expected = Buffer.from(`Bearer ${secret}`)
  return actual.length === expected.length && timingSafeEqual(actual, expected)
}

export function cleanupFunctionURL(supabaseURL: string): URL {
  const projectURL = new URL(supabaseURL)
  if (projectURL.protocol !== 'https:' && projectURL.hostname !== '127.0.0.1') {
    throw new Error('Supabase URL must use HTTPS')
  }

  return new URL('/functions/v1/drain_storage_cleanup', projectURL)
}
