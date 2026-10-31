import type { Metadata } from 'next'
import Link from 'next/link'
import { AuthShell } from '@/components/auth/auth-shell'
import { LoginForm } from '@/components/auth/login-form'
import { BrandMark } from '@/components/brand-mark'
import { TodayDemo } from '@/components/stage/today-demo'
import { fetchEnabledOAuthProviders } from '@/lib/auth-oauth'

export const metadata: Metadata = {
  title: 'Sign in',
}

interface LoginPageProps {
  searchParams: Promise<{ error?: string; reason?: string }>
}

export default async function LoginPage({ searchParams }: LoginPageProps) {
  // Resolving providers on the server means the buttons render with the
  // card instead of popping in after a client fetch.
  const [{ error, reason }, providers] = await Promise.all([
    searchParams,
    fetchEnabledOAuthProviders(),
  ])

  return (
    <AuthShell aside={<ProductAside />}>
      <LoginForm
        initialError={error === 'auth'}
        initialErrorReason={reason}
        initialProviders={providers}
      />
    </AuthShell>
  )
}

/** The product beside the card: what Shudo is, then the app doing it. */
function ProductAside() {
  return (
    <div className="flex flex-col gap-10 xl:flex-row xl:items-start xl:gap-10">
      <div className="max-w-md xl:flex-1 xl:pt-8">
        <Link
          className="-ml-2 inline-flex items-center gap-3 rounded-xl px-2 py-1 text-xl font-semibold tracking-[-0.035em] text-ink transition hover:text-accent-bright focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent/70"
          href="/auth/login"
        >
          <BrandMark className="h-7 w-7 text-accent" />
          Shudo
        </Link>
        <p className="mt-8 text-4xl font-semibold tracking-[-0.045em] text-ink">
          A coach in your pocket.
        </p>
        <p className="mt-4 text-base leading-7 text-muted">
          Shudo texts you through the day and reacts to everything you log. Say what you ate, and
          the numbers land before you’ve put the fork down.
        </p>
      </div>
      <div className="w-full max-w-[25rem] xl:flex-none">
        <TodayDemo />
      </div>
    </div>
  )
}
