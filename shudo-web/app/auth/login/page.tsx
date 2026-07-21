import { LoginForm } from '@/components/auth/login-form'

interface LoginPageProps {
  searchParams: Promise<{ error?: string }>
}

export default async function LoginPage({ searchParams }: LoginPageProps) {
  const { error } = await searchParams

  return (
    <main
      className="relative flex min-h-screen items-center justify-center overflow-hidden px-5 py-12"
      id="main-content"
      tabIndex={-1}
    >
      <div className="pointer-events-none absolute inset-0 bg-[radial-gradient(circle_at_50%_20%,rgba(118,221,167,0.12),transparent_34%)]" />
      <div className="relative w-full max-w-sm">
        <div className="mb-10 flex items-center gap-3">
          <div className="flex h-10 w-10 items-center justify-center rounded-2xl bg-accent text-sm font-bold text-paper shadow-[0_0_34px_rgba(118,221,167,0.22)]">
            S
          </div>
          <div>
            <p className="text-lg font-semibold tracking-tight text-ink">shudo</p>
            <p className="text-xs text-muted">Your nutrition log</p>
          </div>
        </div>

        <LoginForm initialError={error === 'auth'} />
      </div>
    </main>
  )
}
