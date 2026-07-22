import type { Config } from 'tailwindcss'

const config: Config = {
  content: [
    './app/**/*.{js,ts,jsx,tsx,mdx}',
    './components/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {
      colors: {
        paper: '#0d0c0a',
        surface: '#17140f',
        'surface-strong': '#231e16',
        ink: '#fff3dd',
        muted: '#b8aa93',
        subtle: '#897b68',
        accent: '#dc9840',
        'accent-bright': '#ffc968',
        danger: '#ff9487',
        protein: '#f2b85e',
        carbs: '#98c995',
        fat: '#d89572',
      },
      fontFamily: {
        sans: ['var(--font-geist-sans)', 'system-ui', 'sans-serif'],
        mono: ['var(--font-geist-mono)', 'ui-monospace', 'monospace'],
      },
    },
  },
  plugins: [],
}

export default config
