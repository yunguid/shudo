import Link from 'next/link'
import { SignOutButton } from '@/components/auth/sign-out-button'

const navigation = [
  { href: '/', label: 'Day' },
  { href: '/meals', label: 'History' },
] as const

export function TopBar() {
  return (
    <header className="sticky top-0 z-40 bg-paper/80 backdrop-blur-xl">
      <div className="mx-auto flex h-16 w-full max-w-5xl items-center justify-between px-5 sm:px-8">
        <div className="flex items-center gap-4 sm:gap-6">
          <Link
            aria-label="Shudo dashboard"
            className="flex items-center gap-2.5 rounded-xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
            href="/"
          >
            <span className="flex h-8 w-8 items-center justify-center rounded-xl bg-accent text-xs font-bold text-paper shadow-[0_0_24px_rgba(118,221,167,0.15)]">
              S
            </span>
            <span className="text-sm font-semibold tracking-tight text-ink">shudo</span>
          </Link>

          <nav aria-label="Primary navigation" className="flex items-center gap-1">
            {navigation.map((item) => (
              <Link
                className="flex min-h-11 items-center rounded-xl px-3 py-2 text-sm text-muted transition hover:bg-surface hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
                href={item.href}
                key={item.href}
              >
                {item.label}
              </Link>
            ))}
          </nav>
        </div>

        <SignOutButton />
      </div>
    </header>
  )
}
