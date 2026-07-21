import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { NextRequest } from 'next/server'
import { proxy } from '../../proxy'

describe('proxy system routes', () => {
  it('lets the Vercel keepalive reach its own bearer authentication', async () => {
    const response = await proxy(
      new NextRequest('https://shudo.example/api/cron/keepalive'),
    )

    assert.equal(response.status, 200)
    assert.equal(response.headers.get('location'), null)
    assert.equal(response.headers.get('x-middleware-next'), '1')
  })
})
