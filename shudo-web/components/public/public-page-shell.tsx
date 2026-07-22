import Link from 'next/link'
import type { ReactNode } from 'react'
import {
  PUBLIC_INFORMATION_LINKS,
  SHUDO_POLICY_UPDATED,
  SHUDO_SUPPORT_EMAIL,
  SHUDO_SUPPORT_MAILTO,
} from '@/lib/public-information'

interface PublicPageShellProps {
  children: ReactNode
  currentPath: (typeof PUBLIC_INFORMATION_LINKS)[number]['href']
  eyebrow: string
  summary: string
  title: string
}

interface PublicSectionProps {
  children: ReactNode
  title: string
}

export function PublicPageShell({
  children,
  currentPath,
  eyebrow,
  summary,
  title,
}: PublicPageShellProps) {
  return (
    <main className="relative min-h-screen overflow-hidden px-5 py-8 sm:px-8 sm:py-12" id="main-content" tabIndex={-1}>
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-0 bg-[radial-gradient(circle_at_50%_0%,rgba(236,227,211,0.08),transparent_34rem)]"
      />
      <div className="relative mx-auto w-full max-w-3xl">
        <header>
          <div className="flex items-center justify-between gap-4">
            <Link
              className="rounded-xl px-2 py-2 text-xl font-semibold tracking-[-0.035em] text-ink transition hover:text-accent focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent/70"
              href="/auth/login"
            >
              Shudo
            </Link>
            <Link
              className="rounded-xl bg-surface px-4 py-2.5 text-sm font-medium text-ink transition hover:bg-surface-strong focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent/70"
              href="/auth/login"
            >
              Sign in
            </Link>
          </div>

          <nav aria-label="Public information" className="mt-6 flex flex-wrap gap-2">
            {PUBLIC_INFORMATION_LINKS.map((item) => (
              <Link
                aria-current={item.href === currentPath ? 'page' : undefined}
                className={`rounded-xl px-3 py-2 text-sm transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent/70 ${
                  item.href === currentPath
                    ? 'bg-accent text-paper'
                    : 'bg-surface/75 text-muted hover:bg-surface-strong hover:text-ink'
                }`}
                href={item.href}
                key={item.href}
              >
                {item.label}
              </Link>
            ))}
          </nav>
        </header>

        <article className="mt-8 rounded-[2rem] bg-surface/88 px-6 py-8 shadow-[0_28px_90px_rgba(0,0,0,0.34)] backdrop-blur-xl sm:px-10 sm:py-11">
          <p className="text-xs font-medium uppercase tracking-[0.18em] text-subtle">{eyebrow}</p>
          <h1 className="mt-3 text-4xl font-semibold tracking-[-0.045em] text-ink sm:text-5xl">
            {title}
          </h1>
          <p className="mt-4 max-w-2xl text-base leading-7 text-muted">{summary}</p>
          <p className="mt-3 text-xs text-subtle">Updated {SHUDO_POLICY_UPDATED}</p>

          <div className="mt-10">{children}</div>
        </article>

        <footer className="flex flex-col gap-2 px-2 py-8 text-xs text-subtle sm:flex-row sm:items-center sm:justify-between">
          <p>Private, voice-first nutrition logging.</p>
          <a
            className="rounded-lg text-muted transition hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent/70"
            href={SHUDO_SUPPORT_MAILTO}
          >
            {SHUDO_SUPPORT_EMAIL}
          </a>
        </footer>
      </div>
    </main>
  )
}

export function PublicSection({ children, title }: PublicSectionProps) {
  return (
    <section className="mt-9 first:mt-0">
      <h2 className="text-xl font-semibold tracking-[-0.025em] text-ink">{title}</h2>
      <div className="mt-3 space-y-3 text-sm leading-7 text-muted [&_a]:font-medium [&_a]:text-ink [&_a]:underline [&_a]:decoration-subtle [&_a]:underline-offset-4 [&_a]:transition [&_a:hover]:text-accent [&_li]:pl-1 [&_ul]:list-disc [&_ul]:space-y-2 [&_ul]:pl-5">
        {children}
      </div>
    </section>
  )
}
