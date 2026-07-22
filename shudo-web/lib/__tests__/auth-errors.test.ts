import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import {
  authCallbackErrorReason,
  initialMagicLinkErrorMessage,
  magicLinkRequestErrorMessage,
} from '@/lib/auth-errors'

describe('magic-link errors', () => {
  it('explains the Supabase resend cooldown instead of blaming the address', () => {
    assert.equal(
      magicLinkRequestErrorMessage({ status: 429, code: 'over_email_send_rate_limit' }),
      'Too many links requested. Wait a minute, then try again.',
    )
    assert.equal(
      magicLinkRequestErrorMessage(new Error('Too many requests')),
      'Too many links requested. Wait a minute, then try again.',
    )
  })

  it('keeps a non-enumerating fallback for other send failures', () => {
    assert.equal(
      magicLinkRequestErrorMessage({ status: 400, message: 'User not found' }),
      'Sign-in link unavailable. Check the address and try again.',
    )
  })

  it('distinguishes a lost PKCE browser handshake from an expired link', () => {
    assert.equal(authCallbackErrorReason({ code: 'flow_state_not_found' }), 'browser')
    assert.equal(authCallbackErrorReason({ message: 'code verifier missing' }), 'browser')
    assert.equal(authCallbackErrorReason({ code: 'otp_expired' }), 'expired')
    assert.match(initialMagicLinkErrorMessage('browser'), /same browser/)
    assert.match(initialMagicLinkErrorMessage('expired'), /invalid or expired/)
  })
})
