import type { Config } from 'tailwindcss'

const config: Config = {
  content: [
    './app/**/*.{js,ts,jsx,tsx,mdx}',
    './components/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {
      colors: {
        paper: '#0b0a09',
        surface: '#141210',
        'surface-strong': '#1d1a17',
        ink: '#f4efe6',
        muted: '#aaa196',
        subtle: '#7f776d',
        accent: '#e8ded0',
        'accent-bright': '#fff8ec',
        danger: '#ff8f8f',
        protein: '#8eb8ff',
        carbs: '#76dda7',
        fat: '#eccb78',
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
