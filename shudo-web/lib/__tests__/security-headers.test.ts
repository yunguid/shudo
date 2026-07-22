import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import nextConfig from '../../next.config.mjs'

describe('response security headers', () => {
  it('applies the hardened policy to every route', async () => {
    assert.equal(typeof nextConfig.headers, 'function')

    const rules = await nextConfig.headers!()
    assert.equal(rules.length, 1)
    assert.equal(rules[0].source, '/:path*')

    const headers = new Map(rules[0].headers.map(({ key, value }) => [key, value]))
    assert.equal(headers.get('X-Content-Type-Options'), 'nosniff')
    assert.equal(headers.get('X-Frame-Options'), 'DENY')
    assert.equal(headers.get('Referrer-Policy'), 'strict-origin-when-cross-origin')
    assert.match(headers.get('Permissions-Policy') ?? '', /camera=\(\)/)
    assert.match(headers.get('Permissions-Policy') ?? '', /microphone=\(\)/)
    assert.equal(
      headers.get('Content-Security-Policy'),
      "base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'",
    )
  })

  it('does not constrain Next.js assets, Supabase connections, or meal images', async () => {
    const rules = await nextConfig.headers!()
    const csp = rules[0].headers.find(({ key }) => key === 'Content-Security-Policy')?.value ?? ''

    assert.doesNotMatch(csp, /(?:^|;)\s*(?:default|script|style|connect|img|font)-src\b/)
  })
})
