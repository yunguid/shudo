import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { isPublicAuthPath, isPublicInformationPath } from '../auth-paths'

describe('isPublicAuthPath', () => {
  it('keeps recovery and auth routes reachable without a session', () => {
    assert.equal(isPublicAuthPath('/reset-password'), true)
    assert.equal(isPublicAuthPath('/auth/login'), true)
    assert.equal(isPublicAuthPath('/auth/callback'), true)
  })

  it('does not exempt similarly named or private routes', () => {
    assert.equal(isPublicAuthPath('/reset-password/other'), false)
    assert.equal(isPublicAuthPath('/meals'), false)
  })
})

describe('isPublicInformationPath', () => {
  it('keeps policy and support routes public without widening the match', () => {
    assert.equal(isPublicInformationPath('/terms'), true)
    assert.equal(isPublicInformationPath('/support'), true)
    assert.equal(isPublicInformationPath('/privacy'), true)
    assert.equal(isPublicInformationPath('/meals'), false)
  })
})
