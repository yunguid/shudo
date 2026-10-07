import { defineConfig, globalIgnores } from 'eslint/config'
import nextVitals from 'eslint-config-next/core-web-vitals'
import nextTypeScript from 'eslint-config-next/typescript'

export default defineConfig([
  ...nextVitals,
  ...nextTypeScript,
  {
    rules: {
      // Meal photos are hour-lived signed URLs to a private bucket; routing
      // them through the shared next/image optimizer would cache private
      // photos on shared infra and miss the cache on every re-sign anyway.
      '@next/next/no-img-element': 'off',
    },
  },
  {
    // The hardened braces fork stays CommonJS, like upstream, because
    // micromatch, fast-glob and chokidar require() it.
    files: ['vendor/braces-compat/**/*.js'],
    rules: {
      '@typescript-eslint/no-require-imports': 'off',
    },
  },
  globalIgnores([
    '.next/**',
    '.vercel/**',
    'coverage/**',
    'out/**',
    'next-env.d.ts',
  ]),
])
