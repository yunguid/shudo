import Link from 'next/link'
import type { ReactNode } from 'react'
import { BrandMark } from '@/components/brand-mark'
import { PUBLIC_INFORMATION_LINKS } from '@/lib/public-information'

interface AuthShellProps {
  children: ReactNode
}

export function AuthShell({ children }: AuthShellProps) {
  return (
    <main
      className="relative flex min-h-screen items-center justify-center overflow-hidden px-5 py-12 sm:px-8"
      id="main-content"
      tabIndex={-1}
    >
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-0 bg-[radial-gradient(circle_at_50%_12%,rgba(236,227,211,0.09),transparent_32rem)]"
      />
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-accent/30 to-transparent"
      />

      <div className="relative w-full max-w-[26rem]">
        <header className="mb-8 text-center">
          <Link
            className="inline-flex items-center gap-3 rounded-xl px-2 py-1 text-xl font-semibold tracking-[-0.035em] text-ink transition hover:text-accent-bright focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent/70"
            href="/auth/login"
          >
            <BrandMark className="h-7 w-7 text-accent" />
            Shudo
          </Link>
        </header>

        {children}

        <footer className="mt-6 text-center text-xs text-subtle">
          <nav aria-label="Legal and support" className="flex justify-center gap-4">
            {PUBLIC_INFORMATION_LINKS.map((item) => (
              <Link
                className="inline-flex min-h-11 items-center rounded-md text-muted transition hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent/70"
                href={item.href}
                key={item.href}
              >
                {item.label}
              </Link>
            ))}
          </nav>
        </footer>
      </div>
    </main>
  )
}
