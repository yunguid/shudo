import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { describe, it } from 'node:test'
import braceExpand, { expand } from 'brace-expansion'

const require = createRequire(import.meta.url)

describe('patched brace expansion compatibility', () => {
  it('preserves both the legacy callable and modern named APIs', () => {
    const legacyExpand = require('brace-expansion') as typeof braceExpand & {
      expand: typeof expand
    }

    assert.deepEqual(legacyExpand('meal-{breakfast,lunch}.ts'), [
      'meal-breakfast.ts',
      'meal-lunch.ts',
    ])
    assert.deepEqual(legacyExpand.expand('{1..3}'), ['1', '2', '3'])
    assert.deepEqual(expand('item-{a,b}'), ['item-a', 'item-b'])
  })

  it('bounds the total output for attack-shaped chained groups', () => {
    const maxLength = 1_024
    const expansions = expand('{a,b}'.repeat(30), { maxLength })
    const outputLength = expansions.reduce((total, value) => total + value.length, 0)

    assert.ok(expansions.length > 0)
    assert.ok(outputLength <= maxLength)
  })

  it('delegates to the exact patched upstream release', () => {
    const compatibilityPackage = require('brace-expansion/package.json') as {
      version: string
    }
    const patchedPackage = require('brace-expansion-patched/package.json') as {
      version: string
    }

    assert.equal(compatibilityPackage.version, '5.0.8-shudo.1')
    assert.equal(patchedPackage.version, '5.0.8')
  })
})
