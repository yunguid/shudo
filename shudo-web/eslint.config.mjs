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
  {
    // The vendored stageshow kit (components/stage/kit) keeps its upstream
    // source: it drives DOM and refs directly for frame-accurate motion,
    // which the React Compiler rules flag by design. Lint our own demo code
    // around it in full.
    files: ['components/stage/kit/**/*.{ts,tsx}'],
    linterOptions: { reportUnusedDisableDirectives: 'off' },
    rules: {
      'react-hooks/refs': 'off',
      'react-hooks/set-state-in-effect': 'off',
      'react-hooks/exhaustive-deps': 'off',
      '@typescript-eslint/no-explicit-any': 'off',
      '@typescript-eslint/no-unused-vars': 'off',
      '@typescript-eslint/no-unused-expressions': 'off',
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
