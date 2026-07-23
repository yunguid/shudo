import type { Metadata } from 'next'
import { AuthShell } from '@/components/auth/auth-shell'
import { LoginForm } from '@/components/auth/login-form'
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
    <AuthShell>
      <LoginForm
        initialError={error === 'auth'}
        initialErrorReason={reason}
        initialProviders={providers}
      />
    </AuthShell>
  )
}
