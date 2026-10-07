import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { readFileSync, realpathSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join, resolve } from 'node:path'
import { describe, it } from 'node:test'
import { fileURLToPath } from 'node:url'
import braces from 'braces'

const require = createRequire(import.meta.url)
const webRoot = resolve(fileURLToPath(new URL('.', import.meta.url)), '../..')
const forkRoot = join(webRoot, 'vendor/braces-compat')

// Transitive consumers, loaded the way Tailwind and eslint-config-next load them.
const micromatch = require('micromatch') as {
  braces: (pattern: string, options?: braces.Options) => string[]
  braceExpand: (pattern: string, options?: braces.Options) => string[]
}
const fastGlob = require('fast-glob') as typeof import('fast-glob')

const nested = (depth: number, open = '{', close = '}') =>
  `${open.repeat(depth)}a,b${close.repeat(depth)}`
const depthError = /nesting depth exceeds the maximum of 100\b/
const countError = /maximum of 100000 generated values/

describe('hardened braces fork', () => {
  it('is the only braces implementation every consumer resolves', () => {
    const lockfile = JSON.parse(readFileSync(join(webRoot, 'package-lock.json'), 'utf8')) as {
      packages: Record<string, { link?: boolean; resolved?: string; version?: string }>
    }
    const installs = Object.entries(lockfile.packages).filter(([path]) =>
      /(^|\/)node_modules\/braces$/.test(path),
    )

    assert.deepEqual(installs, [
      ['node_modules/braces', { resolved: 'vendor/braces-compat', link: true }],
    ])
    assert.equal(lockfile.packages['vendor/braces-compat']?.version, '3.0.3-shudo.1')

    for (const consumer of ['micromatch', 'chokidar']) {
      const consumerRequire = createRequire(require.resolve(consumer))
      assert.equal(
        realpathSync(consumerRequire.resolve('braces')),
        join(realpathSync(forkRoot), 'index.js'),
        `${consumer} must load the hardened fork`,
      )
    }
  })

  it('expands, compiles and matches ordinary patterns like upstream 3.0.3', () => {
    assert.deepEqual(braces('a/{b,c}/d'), ['a/(b|c)/d'])
    assert.deepEqual(braces('a/{b,c}/d', { expand: true }), ['a/b/d', 'a/c/d'])
    assert.deepEqual(braces.expand('{1..3}'), ['1', '2', '3'])
    assert.deepEqual(braces.expand('{a,b}{c,d}'), ['ac', 'ad', 'bc', 'bd'])
    assert.equal(
      braces.compile('user-{200..300}/project-{a,b,c}-{1..10}'),
      'user-(20[0-9]|2[1-9][0-9]|300)/project-(a|b|c)-([1-9]|10)',
    )
    assert.deepEqual(braces('./app/**/*.{js,ts,jsx,tsx,mdx}', { expand: true }), [
      './app/**/*.js',
      './app/**/*.ts',
      './app/**/*.jsx',
      './app/**/*.tsx',
      './app/**/*.mdx',
    ])
    assert.deepEqual(micromatch.braceExpand('meal-{breakfast,lunch}.ts'), [
      'meal-breakfast.ts',
      'meal-lunch.ts',
    ])

    const matcher = new RegExp(`^${micromatch.braces('meal-{breakfast,lunch}')[0]}$`)
    assert.ok(matcher.test('meal-lunch'))
    assert.ok(!matcher.test('meal-dinner'))

    assert.deepEqual(
      fastGlob.sync('lib/__tests__/{brace-expansion,braces}-compat.test.ts', { cwd: webRoot }).sort(),
      ['lib/__tests__/brace-expansion-compat.test.ts', 'lib/__tests__/braces-compat.test.ts'],
    )
  })

  it('rejects attack-shaped nesting before any walker can exhaust the stack', () => {
    const braceAttacks = [nested(4_990), `${'{a,'.repeat(2_400)}b${'}'.repeat(2_400)}`]
    const attacks = [...braceAttacks, nested(4_990, '(', ')')]

    for (const pattern of attacks) {
      assert.ok(pattern.length <= 10_000, 'attack fits under the upstream input limit')
      assert.throws(() => braces(pattern), { name: 'RangeError', message: depthError })
      assert.throws(() => braces(pattern, { expand: true }), { name: 'RangeError', message: depthError })
      assert.throws(() => braces.parse(pattern), { name: 'RangeError', message: depthError })
    }

    // micromatch only hands patterns that contain a brace group to braces.
    for (const pattern of braceAttacks) {
      assert.throws(() => micromatch.braces(pattern), { name: 'RangeError', message: depthError })
      assert.throws(() => micromatch.braceExpand(pattern), { name: 'RangeError', message: depthError })
    }

    // Like Bash, only the innermost group expands; the outer braces stay literal.
    const literal = (value: string) => `${'{'.repeat(99)}${value}${'}'.repeat(99)}`
    assert.deepEqual(braces(nested(100), { expand: true }), [literal('a'), literal('b')])
    assert.throws(() => braces(nested(101), { expand: true }), { name: 'RangeError', message: depthError })
    assert.throws(() => braces('{a,{b,c}}', { maxDepth: 1 }), RangeError)
    assert.throws(() => braces(nested(101), { maxDepth: 1_000_000 }), { message: depthError })
  })

  it('guards walkers that receive a hand-built AST', () => {
    const root: braces.Node = { type: 'root', nodes: [] }
    let parent = root
    for (let level = 0; level < 5_000; level += 1) {
      const child: braces.Node = { type: 'paren', nodes: [] }
      parent.nodes?.push(child)
      parent = child
    }
    parent.nodes?.push({ type: 'text', value: 'a' })

    assert.throws(() => braces.compile(root), { name: 'RangeError', message: depthError })
    assert.throws(() => braces.stringify(root), { name: 'RangeError', message: depthError })
    assert.throws(() => braces.expand(root), { name: 'RangeError', message: depthError })
  })

  it('keeps patterns at the depth limit well inside a reduced call stack', () => {
    const script = `
      const braces = require(${JSON.stringify(forkRoot)})
      const pattern = '{a,('.repeat(50) + 'b' + ')}'.repeat(50)
      braces(pattern)
      braces(pattern, { expand: true })
      braces.stringify(pattern)
      process.stdout.write('ok')
    `
    const child = spawnSync(process.execPath, ['--stack-size=200', '-e', script], {
      encoding: 'utf8',
    })

    assert.equal(child.status, 0, child.stderr)
    assert.equal(child.stdout, 'ok')
  })

  it('bounds the values and characters a single expansion may generate', () => {
    assert.throws(() => braces('{a,b}'.repeat(40), { expand: true }), {
      name: 'RangeError',
      message: countError,
    })
    assert.throws(() => micromatch.braceExpand(`{${'{a,b}'.repeat(16)},${'{c,d}'.repeat(16)}}`), {
      message: countError,
    })
    assert.throws(() => braces.expand(`{${'x'.repeat(4_000)},y}${'{a,b}'.repeat(10)}`), {
      name: 'RangeError',
      message: /maximum of 4000000 generated characters/,
    })

    assert.equal(braces.expand('{a,b}'.repeat(12)).length, 4_096)
    assert.throws(() => braces.expand('{a,b}{c,d}', { maxExpansions: 4 }), RangeError)
    assert.throws(() => braces.expand('{aaaa,bbbb}{cccc,dddd}', { maxExpandedLength: 10 }), RangeError)
    assert.throws(() => braces.expand('{a,b}'.repeat(40), { maxExpansions: Infinity }), {
      message: countError,
    })
  })

  it('keeps the upstream input-length and range limits', () => {
    assert.throws(() => braces(`{${'a'.repeat(10_000)},b}`), SyntaxError)
    assert.throws(() => braces(`{${'a'.repeat(10_000)},b}`, { maxLength: 50_000 }), SyntaxError)
    assert.throws(() => braces.expand('{1..2000}'), /exceeds range limit/)
  })
})
