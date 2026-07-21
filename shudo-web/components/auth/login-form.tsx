'use client'

import { useState, type FormEvent } from 'react'
import { ArrowRight, LoaderCircle, Mail } from 'lucide-react'
import { getBrowserClient } from '@/lib/supabase/client'

interface LoginFormProps {
  initialError: boolean
}

export function LoginForm({ initialError }: LoginFormProps) {
  const [email, setEmail] = useState('')
  const [isSending, setIsSending] = useState(false)
  const [message, setMessage] = useState(
    initialError ? 'That sign-in link could not be verified. Request a new one.' : '',
  )
  const [isSuccess, setIsSuccess] = useState(false)

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setIsSending(true)
    setMessage('')
    setIsSuccess(false)

    try {
      const supabase = getBrowserClient()
      const { error } = await supabase.auth.signInWithOtp({
        email,
        options: {
          emailRedirectTo: `${window.location.origin}/auth/callback`,
          shouldCreateUser: false,
        },
      })

      if (error) throw error

      setMessage('Check your email for a secure sign-in link.')
      setIsSuccess(true)
    } catch {
      setMessage('Unable to send a sign-in link. Check the address and try again.')
    } finally {
      setIsSending(false)
    }
  }

  return (
    <section aria-labelledby="login-heading" className="rounded-[2rem] bg-surface/80 p-7 shadow-2xl shadow-black/30 backdrop-blur-xl">
      <p className="mb-2 text-xs font-medium uppercase tracking-[0.18em] text-accent">Private companion</p>
      <h1 id="login-heading" className="text-3xl font-semibold tracking-tight text-ink">
        Welcome back.
      </h1>
      <p className="mt-2 text-sm leading-6 text-muted">
        Sign in with the email already connected to your Shudo account.
      </p>

      <form className="mt-8 space-y-4" onSubmit={handleSubmit}>
        <label className="block">
          <span className="sr-only">Email address</span>
          <span className="flex items-center gap-3 rounded-2xl bg-surface-strong px-4 py-3.5 focus-within:ring-2 focus-within:ring-accent/70">
            <Mail aria-hidden="true" className="h-4 w-4 text-muted" />
            <input
              aria-describedby={message ? 'login-status' : undefined}
              autoComplete="email"
              autoCapitalize="none"
              className="min-w-0 flex-1 bg-transparent text-sm text-ink outline-none placeholder:text-subtle"
              enterKeyHint="send"
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
          className="flex h-12 w-full items-center justify-center gap-2 rounded-2xl bg-accent px-4 text-sm font-semibold text-paper shadow-[0_12px_30px_rgba(118,221,167,0.16)] transition hover:bg-accent-bright focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper disabled:cursor-not-allowed disabled:opacity-60"
          disabled={isSending}
          type="submit"
        >
          {isSending ? (
            <LoaderCircle aria-hidden="true" className="h-4 w-4 animate-spin" />
          ) : (
            <ArrowRight aria-hidden="true" className="h-4 w-4" />
          )}
          {isSending ? 'Sending link' : 'Email me a sign-in link'}
        </button>
      </form>
    </section>
  )
}
