import type { Metadata } from 'next'
import { AuthShell } from '@/components/auth/auth-shell'
import { LoginForm } from '@/components/auth/login-form'

export const metadata: Metadata = {
  title: 'Sign in',
}

interface LoginPageProps {
  searchParams: Promise<{ error?: string }>
}

export default async function LoginPage({ searchParams }: LoginPageProps) {
  const { error } = await searchParams

  return (
    <AuthShell>
      <LoginForm initialError={error === 'auth'} />
      <section
        aria-labelledby="product-summary-heading"
        className="mt-5 rounded-[1.6rem] bg-surface/55 px-5 py-5 text-center"
      >
        <h2 className="text-sm font-semibold text-ink" id="product-summary-heading">
          Built for quick meal capture
        </h2>
        <p className="mt-2 text-sm leading-6 text-muted">
          Speak, add a photo, or type a note. Get a calorie and macro estimate, then review each
          day at a glance.
        </p>
      </section>
    </AuthShell>
  )
}
