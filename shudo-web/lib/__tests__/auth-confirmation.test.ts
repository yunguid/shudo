import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import {
  confirmationUrlWithoutCredentials,
  parseEmailConfirmationUrl,
} from '../auth-confirmation'

describe('email confirmation landing', () => {
  it('accepts a completed signup fragment without retaining credentials', () => {
    const url = new URL(
      'https://shudo.yng.sh/auth/confirm#access_token=secret&type=signup&refresh_token=private',
    )
    assert.deepEqual(parseEmailConfirmationUrl(url), { kind: 'confirmed' })
    assert.equal(confirmationUrlWithoutCredentials(url), '/auth/confirm')
  })

  it('supports token-hash templates and rejects errors or unrelated fragments', () => {
    assert.deepEqual(
      parseEmailConfirmationUrl(
        new URL('https://shudo.yng.sh/auth/confirm?token_hash=hash&type=signup'),
      ),
      { kind: 'verify', tokenHash: 'hash', type: 'signup' },
    )
    assert.deepEqual(
      parseEmailConfirmationUrl(
        new URL('https://shudo.yng.sh/auth/confirm#error=access_denied&type=signup'),
      ),
      { kind: 'error' },
    )
  })
})
