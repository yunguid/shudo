# Hardened braces fork

[`GHSA-vfj7-8cjw-p6xm`](https://github.com/advisories/GHSA-vfj7-8cjw-p6xm)
(CVE-2026-93687) affects every published `braces` release: the parser,
compiler, expander and stringifier recurse once per level of nesting with no
depth guard, so a pattern such as `'{'.repeat(5000) + '}'.repeat(5000)` fits
under the 10,000-character input limit and can exhaust the call stack. No
patched upstream release exists. Tailwind CSS 3 (`chokidar`, `fast-glob`,
`micromatch`) and `eslint-config-next` (`@next/eslint-plugin-next` →
`fast-glob` → `micromatch`) still depend on it.

This is the `braces` 3.0.3 source (MIT, see `LICENSE`) with the same public
API: `braces()`, `.parse()`, `.stringify()`, `.compile()`, `.expand()` and
`.create()`. The root npm override (`"braces": "$braces"`) routes every
consumer to it. Changes from upstream:

- `maxDepth` (default and ceiling 100): brace/parenthesis nesting deeper than
  this throws a `RangeError` while parsing, and every recursive AST walker
  checks the same limit, so ASTs built by hand are covered too.
- `maxExpansions` (default and ceiling 100,000) and `maxExpandedLength`
  (default and ceiling 4,000,000): the strings, and total characters, one
  `expand` call may generate, intermediate combinations included. Exceeding
  either throws a `RangeError` before the product is built. Upstream only
  bounded single ranges (`rangeLimit`), not chained groups such as
  `'{a,b}'.repeat(40)`.
- `maxLength` (input length, still 10,000) and the new limits can be lowered
  through options but never raised; non-numeric values fall back to the
  default.
- Removed upstream's stray `console.log` in the compiler.

Remove this fork once a patched `braces` release exists and Tailwind and
`eslint-config-next` no longer pull a vulnerable version. Until then, keep the
override in place and keep `lib/__tests__/braces-compat.test.ts` passing.
