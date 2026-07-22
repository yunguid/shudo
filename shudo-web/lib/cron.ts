import { timingSafeEqual } from 'node:crypto'

const minimumSecretLength = 32

export function isValidMaintenanceSecret(secret: string | undefined): secret is string {
  return Boolean(secret && secret.length >= minimumSecretLength)
}

export function isAuthorizedCronRequest(
  authorization: string | null,
  secret: string | undefined,
): boolean {
  if (!isValidMaintenanceSecret(secret) || !authorization) {
    return false
  }

  const actual = Buffer.from(authorization)
  const expected = Buffer.from(`Bearer ${secret}`)
  return actual.length === expected.length && timingSafeEqual(actual, expected)
}

export function cleanupFunctionURL(supabaseURL: string): URL {
  return maintenanceFunctionURL(supabaseURL, 'drain_storage_cleanup')
}

export function weeklySummaryFunctionURL(supabaseURL: string): URL {
  return maintenanceFunctionURL(supabaseURL, 'generate_weekly_summaries')
}

function maintenanceFunctionURL(supabaseURL: string, functionName: string): URL {
  const projectURL = new URL(supabaseURL)
  if (projectURL.protocol !== 'https:' && projectURL.hostname !== '127.0.0.1') {
    throw new Error('Supabase URL must use HTTPS')
  }

  return new URL(`/functions/v1/${functionName}`, projectURL)
}
