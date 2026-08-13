'use client'

import { useState, type FormEvent } from 'react'
import { ArrowRight, LoaderCircle, LockKeyhole, Mail } from 'lucide-react'
import { buildOAuthCallbackUrl, type ShudoOAuthProvider } from '@/lib/auth-oauth'
import {
  initialMagicLinkErrorMessage,
  magicLinkRequestErrorMessage,
  passwordSignInErrorMessage,
} from '@/lib/auth-errors'
import { requestPasswordRecovery } from '@/lib/auth-recovery'
import { getSupabasePublicConfig } from '@/lib/supabase/config'
import { getBrowserClient } from '@/lib/supabase/client'

interface LoginFormProps {
  initialError: boolean
  initialErrorReason?: string
  initialProviders: ShudoOAuthProvider[]
}

type PendingMethod = 'password' | 'link' | 'recovery' | ShudoOAuthProvider | null

const PROVIDER_LABELS: Record<ShudoOAuthProvider, string> = {
  google: 'Google',
  apple: 'Apple',
}

export function LoginForm({
  initialError,
  initialErrorReason,
  initialProviders,
}: LoginFormProps) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [pendingMethod, setPendingMethod] = useState<PendingMethod>(null)
  const enabledProviders = initialProviders
  const [message, setMessage] = useState(
    initialError ? initialMagicLinkErrorMessage(initialErrorReason) : '',
  )
  const [isSuccess, setIsSuccess] = useState(false)

  const isBusy = pendingMethod !== null

  function trimmedEmail(): string | null {
    const value = email.trim()
    if (!value) {
      setMessage('Enter your email address first.')
      setIsSuccess(false)
      return null
    }
    return value
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const address = trimmedEmail()
    if (!address || !password) return

    setPendingMethod('password')
    setMessage('')
    setIsSuccess(false)

    try {
      const supabase = getBrowserClient()
      const { error } = await supabase.auth.signInWithPassword({
        email: address,
        password,
      })

      if (error) throw error

      // Full navigation so the server sees the fresh auth cookies.
      window.location.assign('/')
    } catch (error) {
      setMessage(passwordSignInErrorMessage(error))
      setPendingMethod(null)
    }
  }

  async function handleMagicLink() {
    const address = trimmedEmail()
    if (!address) return

    setPendingMethod('link')
    setMessage('')
    setIsSuccess(false)

    try {
      const supabase = getBrowserClient()
      const { error } = await supabase.auth.signInWithOtp({
        email: address,
        options: {
          emailRedirectTo: `${window.location.origin}/auth/callback`,
          shouldCreateUser: false,
        },
      })

      if (error) throw error

      setMessage('Sign-in link sent. Open it in this browser.')
      setIsSuccess(true)
    } catch (error) {
      setMessage(magicLinkRequestErrorMessage(error))
    } finally {
      setPendingMethod(null)
    }
  }

  async function handleOAuth(provider: ShudoOAuthProvider) {
    setPendingMethod(provider)
    setMessage('')
    setIsSuccess(false)

    try {
      const supabase = getBrowserClient()
      const { error } = await supabase.auth.signInWithOAuth({
        provider,
        options: {
          redirectTo: buildOAuthCallbackUrl(window.location.origin),
        },
      })

      if (error) throw error
    } catch {
      setMessage(`${PROVIDER_LABELS[provider]} sign-in unavailable. Try email instead.`)
      setPendingMethod(null)
    }
  }

  async function handleForgotPassword() {
    const address = trimmedEmail()
    if (!address) return

    setPendingMethod('recovery')
    setMessage('')
    setIsSuccess(false)

    const { url, key } = getSupabasePublicConfig()
    const didSend = await requestPasswordRecovery({
      projectUrl: url,
      publicKey: key,
      email: address,
      redirectTo: `${window.location.origin}/reset-password`,
    })

    if (didSend) {
      setMessage('Password reset email sent. The link works in any browser.')
      setIsSuccess(true)
    } else {
      setMessage('Reset email unavailable. Wait a minute, then try again.')
    }
    setPendingMethod(null)
  }

  return (
    <section
      aria-labelledby="login-heading"
      className="rounded-[2rem] bg-surface/90 p-2 shadow-[0_28px_90px_rgba(0,0,0,0.44)] backdrop-blur-xl"
    >
      <div className="px-5 py-7 sm:px-6">
          <p className="text-xs font-medium uppercase tracking-[0.18em] text-subtle">
            Existing account
          </p>
          <h1 className="mt-2 text-3xl font-semibold tracking-[-0.035em] text-ink" id="login-heading">
            Sign in
          </h1>
          <p className="mt-3 text-sm leading-6 text-muted">
            Use the email and password from your Shudo account.
          </p>

          {enabledProviders.length > 0 ? (
            <>
              <div className="mt-7 grid gap-3 sm:grid-cols-2">
            {enabledProviders.map((provider) => {
              const label = PROVIDER_LABELS[provider]
              const isPending = pendingMethod === provider

              return (
                <button
                  className="flex min-h-12 items-center justify-center gap-2.5 rounded-2xl bg-surface-strong px-4 text-sm font-medium text-ink transition hover:bg-ink hover:text-paper focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent/70 disabled:cursor-not-allowed disabled:opacity-55"
                  disabled={isBusy}
                  key={provider}
                  onClick={() => handleOAuth(provider)}
                  type="button"
                >
                  {isPending ? (
                    <LoaderCircle aria-hidden="true" className="h-4 w-4 animate-spin" />
                  ) : (
                    <span
                      aria-hidden="true"
                      className="flex h-5 w-5 items-center justify-center rounded-full bg-paper/70 text-[10px] font-semibold"
                    >
                      {label.slice(0, 1)}
                    </span>
                  )}
                  {isPending ? 'Opening' : label}
                </button>
              )
            })}
              </div>

              <div className="my-6 flex items-center gap-3" role="presentation">
                <span className="h-px flex-1 bg-ink/[0.08]" />
                <span className="text-[11px] uppercase tracking-[0.16em] text-subtle">or use email</span>
                <span className="h-px flex-1 bg-ink/[0.08]" />
              </div>
            </>
          ) : null}

          <form className={`space-y-4 ${enabledProviders.length === 0 ? 'mt-7' : ''}`} onSubmit={handleSubmit}>
              <label className="block">
                <span className="sr-only">Email address</span>
                <span className="flex items-center gap-3 rounded-2xl bg-surface-strong px-4 py-3.5 focus-within:ring-2 focus-within:ring-accent/70">
                  <Mail aria-hidden="true" className="h-4 w-4 text-muted" />
                  <input
                    aria-describedby={message ? 'login-status' : undefined}
                    autoComplete="email"
                    autoCapitalize="none"
                    className="min-w-0 flex-1 bg-transparent text-sm text-ink outline-none placeholder:text-subtle"
                    inputMode="email"
                    onChange={(event) => setEmail(event.target.value)}
                    placeholder="you@example.com"
                    required
                    spellCheck={false}
                    type="email"
                    value={email}
                  />
                </span>
              </label>

              <label className="block">
                <span className="sr-only">Password</span>
                <span className="flex items-center gap-3 rounded-2xl bg-surface-strong px-4 py-3.5 focus-within:ring-2 focus-within:ring-accent/70">
                  <LockKeyhole aria-hidden="true" className="h-4 w-4 text-muted" />
                  <input
                    aria-describedby={message ? 'login-status' : undefined}
                    autoComplete="current-password"
                    className="min-w-0 flex-1 bg-transparent text-sm text-ink outline-none placeholder:text-subtle"
                    enterKeyHint="go"
                    onChange={(event) => setPassword(event.target.value)}
                    placeholder="Password"
                    required
                    type="password"
                    value={password}
                  />
                </span>
              </label>

              {message ? (
                <p
                  aria-live="polite"
                  className={`rounded-2xl px-4 py-3 text-sm ${
                    isSuccess ? 'bg-accent/10 text-accent' : 'bg-danger/10 text-danger'
                  }`}
                  id="login-status"
                  role="status"
                >
                  {message}
                </p>
              ) : null}

              <button
                className="flex min-h-12 w-full items-center justify-center gap-2 rounded-2xl bg-accent px-4 text-sm font-semibold text-paper shadow-[0_12px_32px_rgba(220,152,64,0.18)] transition hover:bg-accent-bright focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper disabled:cursor-not-allowed disabled:opacity-55"
                disabled={isBusy}
                type="submit"
              >
                {pendingMethod === 'password' ? (
                  <LoaderCircle aria-hidden="true" className="h-4 w-4 animate-spin" />
                ) : (
                  <ArrowRight aria-hidden="true" className="h-4 w-4" />
                )}
                {pendingMethod === 'password' ? 'Signing in' : 'Sign in'}
              </button>

              <div className="flex items-center justify-between gap-3 px-1 pt-1">
                <button
                  className="min-h-11 rounded-xl px-2 text-xs font-medium text-muted transition hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent disabled:cursor-not-allowed disabled:opacity-55"
                  disabled={isBusy}
                  onClick={handleForgotPassword}
                  type="button"
                >
                  {pendingMethod === 'recovery' ? 'Sending reset email…' : 'Forgot password?'}
                </button>
                <button
                  className="min-h-11 rounded-xl px-2 text-xs font-medium text-accent transition hover:text-accent-bright focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent disabled:cursor-not-allowed disabled:opacity-55"
                  disabled={isBusy}
                  onClick={handleMagicLink}
                  type="button"
                >
                  {pendingMethod === 'link' ? 'Sending link…' : 'Email me a sign-in link'}
                </button>
              </div>
            </form>
            <p className="mt-5 text-center text-xs leading-5 text-subtle">
              New to Shudo? Create your account in the iPhone app, then finish the quick voice setup there.
            </p>
      </div>
    </section>
  )
}
