import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import {
  buildOAuthCallbackUrl,
  enabledOAuthProvidersFromSettings,
  SHUDO_OAUTH_PROVIDERS,
} from '../auth-oauth'

describe('OAuth configuration', () => {
  it('keeps the provider list intentionally narrow', () => {
    assert.deepEqual(SHUDO_OAUTH_PROVIDERS, ['google', 'apple'])
  })

  it('builds a same-origin PKCE callback with a safe return path', () => {
    assert.equal(
      buildOAuthCallbackUrl('https://shudo.example', '/meals?day=2026-07-21'),
      'https://shudo.example/auth/callback?next=%2Fmeals%3Fday%3D2026-07-21',
    )
    assert.equal(
      buildOAuthCallbackUrl('https://shudo.example', 'https://attacker.example'),
      'https://shudo.example/auth/callback?next=%2F',
    )
  })

  it('shows only providers enabled by the live auth settings response', () => {
    assert.deepEqual(
      enabledOAuthProvidersFromSettings({
        external: { email: true, google: true, apple: false, github: true },
      }),
      ['google'],
    )
    assert.deepEqual(enabledOAuthProvidersFromSettings({}), [])
  })
})
