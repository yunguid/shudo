# Patched brace-expansion compatibility

[`CVE-2026-14257`](https://github.com/advisories/GHSA-mh99-v99m-4gvg)
is fixed only in `brace-expansion` 5.0.8. Shudo's current, peer-compatible
ESLint stack includes both legacy consumers that require a callable CommonJS
export and newer consumers that import the named `expand` function.

This private facade preserves both module shapes while delegating every
expansion to the exact upstream 5.0.8 implementation. The root npm override
ensures none of the older vulnerable implementations remain installed.

Remove the facade once all transitive ESLint and Next.js lint dependencies
accept the patched upstream API directly. Until then, keep the upstream alias
exactly pinned and preserve the compatibility and output-bound tests.
