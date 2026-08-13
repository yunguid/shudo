import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import {
  parseRecoveryFragment,
  requestPasswordRecovery,
  updateRecoveryPassword,
  urlWithoutFragment,
} from '../auth-recovery'

describe('requestPasswordRecovery', () => {
  it('posts to the implicit-flow recover endpoint so links work in any browser', async () => {
    let requestedUrl = ''
    let requestInit: RequestInit | undefined

    const didSend = await requestPasswordRecovery({
      projectUrl: 'https://project.supabase.co',
      publicKey: 'publishable-key',
      email: 'user@example.com',
      redirectTo: 'https://shudo.yng.sh/reset-password',
      fetcher: async (input, init) => {
        requestedUrl = input.toString()
        requestInit = init
        return new Response(null, { status: 200 })
      },
    })

    assert.equal(didSend, true)
    const url = new URL(requestedUrl)
    assert.equal(url.pathname, '/auth/v1/recover')
    assert.equal(url.searchParams.get('redirect_to'), 'https://shudo.yng.sh/reset-password')
    assert.equal(requestInit?.method, 'POST')
    assert.deepEqual(JSON.parse(String(requestInit?.body)), { email: 'user@example.com' })
    const headers = requestInit?.headers as Record<string, string>
    assert.equal(headers.apikey, 'publishable-key')
    // No code_challenge: a PKCE recovery link only opens in the requesting browser.
    assert.equal(url.searchParams.has('code_challenge'), false)
    assert.equal('code_challenge' in JSON.parse(String(requestInit?.body)), false)
  })

  it('reports failure instead of throwing when the endpoint rejects', async () => {
    const didSend = await requestPasswordRecovery({
      projectUrl: 'https://project.supabase.co',
      publicKey: 'publishable-key',
      email: 'user@example.com',
      redirectTo: 'https://shudo.yng.sh/reset-password',
      fetcher: async () => new Response(null, { status: 429 }),
    })

    assert.equal(didSend, false)
  })
})

describe('parseRecoveryFragment', () => {
  it('accepts only a recovery fragment with an access token', () => {
    assert.deepEqual(
      parseRecoveryFragment('#access_token=recovery-token&type=recovery&expires_in=3600'),
      { ok: true, accessToken: 'recovery-token' },
    )
    assert.deepEqual(parseRecoveryFragment('#access_token=login-token&type=magiclink'), {
      ok: false,
    })
    assert.deepEqual(parseRecoveryFragment('#type=recovery'), { ok: false })
  })

  it('rejects provider errors even if a token is also present', () => {
    assert.deepEqual(
      parseRecoveryFragment('#error=access_denied&access_token=token&type=recovery'),
      { ok: false },
    )
  })
})

describe('urlWithoutFragment', () => {
  it('preserves the path and query without retaining sensitive fragments', () => {
    assert.equal(urlWithoutFragment('/reset-password', '?source=email'), '/reset-password?source=email')
  })
})

describe('updateRecoveryPassword', () => {
  it('updates the authenticated user without placing credentials in the URL or body', async () => {
    let requestedUrl = ''
    let requestInit: RequestInit | undefined

    const didUpdate = await updateRecoveryPassword({
      projectUrl: 'https://project.supabase.co',
      publicKey: 'publishable-key',
      accessToken: 'recovery-token',
      password: 'correct horse battery staple',
      fetcher: async (input, init) => {
        requestedUrl = input.toString()
        requestInit = init
        return new Response(null, { status: 200 })
      },
    })

    assert.equal(didUpdate, true)
    assert.equal(requestedUrl, 'https://project.supabase.co/auth/v1/user')
    assert.equal(requestedUrl.includes('recovery-token'), false)
    assert.equal(requestInit?.method, 'PUT')
    assert.equal(requestInit?.credentials, 'omit')
    assert.equal(requestInit?.cache, 'no-store')
    assert.equal(requestInit?.redirect, 'error')
    assert.equal(requestInit?.referrerPolicy, 'no-referrer')
    assert.deepEqual(requestInit?.headers, {
      apikey: 'publishable-key',
      Authorization: 'Bearer recovery-token',
      'Content-Type': 'application/json',
    })
    assert.deepEqual(JSON.parse(String(requestInit?.body)), {
      password: 'correct horse battery staple',
    })
    assert.equal(String(requestInit?.body).includes('recovery-token'), false)
  })

  it('returns a generic failure for rejected requests and network errors', async () => {
    assert.equal(
      await updateRecoveryPassword({
        projectUrl: 'https://project.supabase.co',
        publicKey: 'publishable-key',
        accessToken: 'expired-token',
        password: 'a secure password',
        fetcher: async () => new Response(null, { status: 401 }),
      }),
      false,
    )

    assert.equal(
      await updateRecoveryPassword({
        projectUrl: 'https://project.supabase.co',
        publicKey: 'publishable-key',
        accessToken: 'recovery-token',
        password: 'a secure password',
        fetcher: async () => {
          throw new Error('offline')
        },
      }),
      false,
    )
  })
})
