import type { Metadata } from 'next'
import { AuthShell } from '@/components/auth/auth-shell'
import { LoginForm } from '@/components/auth/login-form'

export const metadata: Metadata = {
  title: 'Sign in',
}

interface LoginPageProps {
  searchParams: Promise<{ error?: string; reason?: string }>
}

export default async function LoginPage({ searchParams }: LoginPageProps) {
  const { error, reason } = await searchParams

  return (
    <AuthShell>
      <LoginForm initialError={error === 'auth'} initialErrorReason={reason} />
    </AuthShell>
  )
}
