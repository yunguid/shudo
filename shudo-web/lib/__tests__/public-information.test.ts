import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import {
  PUBLIC_INFORMATION_LINKS,
  SHUDO_SUPPORT_EMAIL,
  SHUDO_SUPPORT_MAILTO,
} from '../public-information'

describe('public information pages', () => {
  it('publishes stable, unique policy and support routes', () => {
    assert.deepEqual(
      PUBLIC_INFORMATION_LINKS.map(({ href }) => href),
      ['/terms', '/support'],
    )
    assert.equal(new Set(PUBLIC_INFORMATION_LINKS.map(({ href }) => href)).size, 2)
  })

  it('uses the requested support address without exposing credentials', () => {
    assert.equal(SHUDO_SUPPORT_EMAIL, 'luke@yng.sh')
    assert.match(SHUDO_SUPPORT_MAILTO, /^mailto:luke@yng\.sh\?subject=/)
  })
})
