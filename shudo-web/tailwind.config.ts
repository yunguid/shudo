import type { Config } from 'tailwindcss'

const config: Config = {
  content: [
    './app/**/*.{js,ts,jsx,tsx,mdx}',
    './components/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {
      colors: {
        paper: '#090b0a',
        surface: '#111411',
        'surface-strong': '#181c18',
        ink: '#f6f8f3',
        muted: '#98a098',
        subtle: '#818a81',
        accent: '#76dda7',
        'accent-bright': '#95ebbd',
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
