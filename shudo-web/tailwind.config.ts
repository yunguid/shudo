import type { Config } from 'tailwindcss'

const config: Config = {
  darkMode: 'class',
  content: [
    './pages/**/*.{js,ts,jsx,tsx,mdx}',
    './components/**/*.{js,ts,jsx,tsx,mdx}',
    './app/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {
      colors: {
        // Core backgrounds (true dark)
        paper: '#090A0E',
        elevated: '#0E1017',
        
        // Text
        ink: '#FFFFFF',
        muted: '#7A80A0',
        subtle: '#515868',
        
        // Surface / Fills
        rule: 'rgba(255, 255, 255, 0.08)',
        glass: {
          fill: 'rgba(25, 28, 38, 0.7)',
          elevated: 'rgba(30, 34, 46, 0.8)',
        },
        
        // Primary accent - Electric Blue
        accent: {
          DEFAULT: '#4385F4',
          primary: '#4385F4',
          secondary: '#649DF6',
        },
        
        // Success / Positive - Fresh Green
        success: '#46D279',
        
        // Macro rings
        ring: {
          protein: '#8BB5FE',
          carb: '#46D279',
          fat: '#F4C143',
        },
        
        // Warning / Danger
        danger: '#F95161',
        warning: '#F4C143',
      },
      fontFamily: {
        sans: ['var(--font-jakarta)', 'system-ui', 'sans-serif'],
        mono: ['var(--font-jetbrains)', 'monospace'],
      },
      borderRadius: {
        sm: '8px',
        DEFAULT: '12px',
        lg: '16px',
        xl: '24px',
      },
      animation: {
        'fade-in': 'fadeIn 0.5s ease-out forwards',
        'slide-up': 'slideUp 0.5s ease-out forwards',
        'pulse-glow': 'pulseGlow 2s ease-in-out infinite',
      },
      keyframes: {
        fadeIn: {
          '0%': { opacity: '0' },
          '100%': { opacity: '1' },
        },
        slideUp: {
          '0%': { opacity: '0', transform: 'translateY(10px)' },
          '100%': { opacity: '1', transform: 'translateY(0)' },
        },
        pulseGlow: {
          '0%, 100%': { boxShadow: '0 0 20px rgba(67, 133, 244, 0.3)' },
          '50%': { boxShadow: '0 0 30px rgba(67, 133, 244, 0.5)' },
        },
      },
      backgroundImage: {
        'gradient-radial': 'radial-gradient(var(--tw-gradient-stops))',
        'noise': "url('/noise.svg')",
      },
    },
  },
  plugins: [require('tailwindcss-animate')],
}
export default config



