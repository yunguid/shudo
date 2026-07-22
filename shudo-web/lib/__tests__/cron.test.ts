import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import {
  cleanupFunctionURL,
  isAuthorizedCronRequest,
  isValidMaintenanceSecret,
  weeklySummaryFunctionURL,
} from '../cron'

describe('cron authorization', () => {
  const secret = 'a'.repeat(32)

  it('accepts only the exact bearer secret', () => {
    assert.equal(isAuthorizedCronRequest(`Bearer ${secret}`, secret), true)
    assert.equal(isAuthorizedCronRequest(`Bearer ${'b'.repeat(32)}`, secret), false)
    assert.equal(isAuthorizedCronRequest(secret, secret), false)
  })

  it('fails closed for missing or short configuration', () => {
    assert.equal(isAuthorizedCronRequest(null, secret), false)
    assert.equal(isAuthorizedCronRequest(`Bearer ${secret}`, undefined), false)
    assert.equal(isAuthorizedCronRequest('Bearer short', 'short'), false)
  })

  it('requires separate maintenance credentials to be high entropy', () => {
    assert.equal(isValidMaintenanceSecret('a'.repeat(32)), true)
    assert.equal(isValidMaintenanceSecret('short'), false)
    assert.equal(isValidMaintenanceSecret(undefined), false)
  })
})

describe('cleanup function URL', () => {
  it('pins the request to the configured Supabase origin', () => {
    assert.equal(
      cleanupFunctionURL('https://example.supabase.co/ignored').href,
      'https://example.supabase.co/functions/v1/drain_storage_cleanup',
    )
  })

  it('pins weekly generation to the same configured origin', () => {
    assert.equal(
      weeklySummaryFunctionURL('https://example.supabase.co/ignored').href,
      'https://example.supabase.co/functions/v1/generate_weekly_summaries',
    )
  })

  it('rejects an insecure remote origin', () => {
    assert.throws(
      () => cleanupFunctionURL('http://example.supabase.co'),
      /must use HTTPS/,
    )
  })
})
