import type { Metadata, Viewport } from 'next'
import { Geist, Geist_Mono } from 'next/font/google'
import './globals.css'

const geistSans = Geist({
  subsets: ['latin'],
  variable: '--font-geist-sans',
})

const geistMono = Geist_Mono({
  subsets: ['latin'],
  variable: '--font-geist-mono',
})

export const metadata: Metadata = {
  applicationName: 'Shudo',
  title: {
    default: 'Shudo',
    template: '%s · Shudo',
  },
  description: 'A private, calm view of your nutrition log.',
  robots: {
    index: false,
    follow: false,
  },
}

export const viewport: Viewport = {
  colorScheme: 'dark',
  themeColor: '#090b0a',
}

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html className={`${geistSans.variable} ${geistMono.variable}`} lang="en">
      <body>
        <a
          className="fixed left-4 top-4 z-50 -translate-y-24 rounded-xl bg-accent px-4 py-3 text-sm font-semibold text-paper transition-transform focus:translate-y-0 focus:outline-none focus:ring-2 focus:ring-accent-bright focus:ring-offset-2 focus:ring-offset-paper"
          href="#main-content"
        >
          Skip to content
        </a>
        {children}
      </body>
    </html>
  )
}
