'use client'

import Link from 'next/link'
import { useEffect, useRef, useState, type FormEvent } from 'react'
import { ArrowRight, Check, KeyRound, LoaderCircle, LockKeyhole } from 'lucide-react'
import {
  parseRecoveryFragment,
  updateRecoveryPassword,
  urlWithoutFragment,
} from '@/lib/auth-recovery'
import { getSupabasePublicConfig } from '@/lib/supabase/config'

type ViewState = 'checking' | 'ready' | 'invalid' | 'saving' | 'error' | 'success'

const MINIMUM_PASSWORD_LENGTH = 10

export function ResetPasswordForm() {
  const accessTokenRef = useRef<string | null>(null)
  const initializedRef = useRef(false)
  const [viewState, setViewState] = useState<ViewState>('checking')
  const [password, setPassword] = useState('')
  const [confirmation, setConfirmation] = useState('')
  const [validationMessage, setValidationMessage] = useState('')

  useEffect(() => {
    if (initializedRef.current) return
    initializedRef.current = true

    const result = parseRecoveryFragment(window.location.hash)
    if (window.location.hash) {
      window.history.replaceState(
        window.history.state,
        '',
        urlWithoutFragment(window.location.pathname, window.location.search),
      )
    }

    if (!result.ok) {
      queueMicrotask(() => setViewState('invalid'))
      return
    }

    accessTokenRef.current = result.accessToken
    queueMicrotask(() => setViewState('ready'))

    return () => {
      accessTokenRef.current = null
    }
  }, [])

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setValidationMessage('')

    if (password.length < MINIMUM_PASSWORD_LENGTH) {
      setValidationMessage(`Use at least ${MINIMUM_PASSWORD_LENGTH} characters.`)
      return
    }

    if (password !== confirmation) {
      setValidationMessage('The passwords do not match.')
      return
    }

    const accessToken = accessTokenRef.current
    if (!accessToken) {
      setViewState('invalid')
      return
    }

    setViewState('saving')
    let didUpdate = false

    try {
      const { url, key } = getSupabasePublicConfig()
      didUpdate = await updateRecoveryPassword({
        projectUrl: url,
        publicKey: key,
        accessToken,
        password,
      })
    } catch {
      // Configuration and request failures intentionally share one user-safe state.
    }

    if (!didUpdate) {
      setViewState('error')
      return
    }

    accessTokenRef.current = null
    setPassword('')
    setConfirmation('')
    setViewState('success')
  }

  if (viewState === 'checking') {
    return (
      <section
        aria-busy="true"
        aria-labelledby="reset-heading"
        className="rounded-[2rem] bg-surface/90 p-7 shadow-[0_28px_90px_rgba(0,0,0,0.44)] backdrop-blur-xl"
      >
        <LoaderCircle aria-hidden="true" className="h-5 w-5 animate-spin text-muted" />
        <h1 className="mt-5 text-3xl font-semibold tracking-[-0.035em] text-ink" id="reset-heading">
          Verifying reset link
        </h1>
        <p aria-live="polite" className="mt-2 text-sm leading-6 text-muted" role="status">
          Keep this tab open.
        </p>
      </section>
    )
  }

  if (viewState === 'invalid') {
    return (
      <section
        aria-labelledby="reset-heading"
        className="rounded-[2rem] bg-surface/90 p-7 shadow-[0_28px_90px_rgba(0,0,0,0.44)] backdrop-blur-xl"
      >
        <KeyRound aria-hidden="true" className="h-6 w-6 text-muted" />
        <h1 className="mt-5 text-3xl font-semibold tracking-[-0.035em] text-ink" id="reset-heading">
          Reset link unavailable
        </h1>
        <p className="mt-2 text-sm leading-6 text-muted">
          This link is invalid or expired. Request another reset email.
        </p>
        <Link
          className="mt-7 flex min-h-12 w-full items-center justify-center gap-2 rounded-2xl bg-accent px-4 text-sm font-semibold text-paper transition hover:bg-accent-bright focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
          href="/auth/login"
        >
          Back to sign in
          <ArrowRight aria-hidden="true" className="h-4 w-4" />
        </Link>
      </section>
    )
  }

  if (viewState === 'success') {
    return (
      <section
        aria-labelledby="reset-heading"
        className="rounded-[2rem] bg-surface/90 p-7 shadow-[0_28px_90px_rgba(0,0,0,0.44)] backdrop-blur-xl"
      >
        <span className="flex h-10 w-10 items-center justify-center rounded-2xl bg-accent/10 text-accent">
          <Check aria-hidden="true" className="h-5 w-5" />
        </span>
        <h1 className="mt-5 text-3xl font-semibold tracking-[-0.035em] text-ink" id="reset-heading">
          Password updated
        </h1>
        <p aria-live="polite" className="mt-2 text-sm leading-6 text-muted" role="status">
          Sign in with the new password.
        </p>
        <Link
          className="mt-7 flex min-h-12 w-full items-center justify-center gap-2 rounded-2xl bg-accent px-4 text-sm font-semibold text-paper transition hover:bg-accent-bright focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper"
          href="/auth/login"
        >
          Continue to sign in
          <ArrowRight aria-hidden="true" className="h-4 w-4" />
        </Link>
      </section>
    )
  }

  const isSaving = viewState === 'saving'

  return (
    <section
      aria-labelledby="reset-heading"
      className="rounded-[2rem] bg-surface/90 p-7 shadow-[0_28px_90px_rgba(0,0,0,0.44)] backdrop-blur-xl"
    >
      <p className="mb-2 text-xs font-medium uppercase tracking-[0.18em] text-subtle">
        Password reset
      </p>
      <h1 className="text-3xl font-semibold tracking-[-0.035em] text-ink" id="reset-heading">
        Set a new password
      </h1>
      <p className="mt-2 text-sm leading-6 text-muted">
        Use {MINIMUM_PASSWORD_LENGTH} or more characters. The recovery token is cleared from the
        address bar.
      </p>

      <form className="mt-8 space-y-4" onSubmit={handleSubmit}>
        <label className="block">
          <span className="mb-2 block text-xs font-medium text-muted">New password</span>
          <span className="flex items-center gap-3 rounded-2xl bg-surface-strong px-4 py-3.5 focus-within:ring-2 focus-within:ring-accent/70">
            <LockKeyhole aria-hidden="true" className="h-4 w-4 text-muted" />
            <input
              aria-describedby="password-requirements reset-status"
              aria-invalid={Boolean(validationMessage)}
              autoComplete="new-password"
              className="min-w-0 flex-1 bg-transparent text-sm text-ink outline-none placeholder:text-subtle"
              minLength={MINIMUM_PASSWORD_LENGTH}
              onChange={(event) => setPassword(event.target.value)}
              placeholder="New password"
              required
              type="password"
              value={password}
            />
          </span>
        </label>

        <label className="block">
          <span className="mb-2 block text-xs font-medium text-muted">Confirm password</span>
          <span className="flex items-center gap-3 rounded-2xl bg-surface-strong px-4 py-3.5 focus-within:ring-2 focus-within:ring-accent/70">
            <LockKeyhole aria-hidden="true" className="h-4 w-4 text-muted" />
            <input
              aria-describedby="reset-status"
              aria-invalid={Boolean(validationMessage)}
              autoComplete="new-password"
              className="min-w-0 flex-1 bg-transparent text-sm text-ink outline-none placeholder:text-subtle"
              minLength={MINIMUM_PASSWORD_LENGTH}
              onChange={(event) => setConfirmation(event.target.value)}
              placeholder="Repeat password"
              required
              type="password"
              value={confirmation}
            />
          </span>
        </label>

        <p className="sr-only" id="password-requirements">
          Password must contain at least {MINIMUM_PASSWORD_LENGTH} characters.
        </p>

        {validationMessage || viewState === 'error' ? (
          <p
            aria-live="polite"
            className="rounded-2xl bg-danger/10 px-4 py-3 text-sm text-danger"
            id="reset-status"
            role="alert"
          >
            {validationMessage ||
              'Password update failed. Try again or request a new reset email.'}
          </p>
        ) : (
          <span className="sr-only" id="reset-status" />
        )}

        <button
          className="flex min-h-12 w-full items-center justify-center gap-2 rounded-2xl bg-accent px-4 text-sm font-semibold text-paper shadow-[0_12px_32px_rgba(220,152,64,0.18)] transition hover:bg-accent-bright focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent focus-visible:ring-offset-2 focus-visible:ring-offset-paper disabled:cursor-not-allowed disabled:opacity-55"
          disabled={isSaving}
          type="submit"
        >
          {isSaving ? (
            <LoaderCircle aria-hidden="true" className="h-4 w-4 animate-spin" />
          ) : (
            <ArrowRight aria-hidden="true" className="h-4 w-4" />
          )}
          {isSaving ? 'Saving password' : 'Save new password'}
        </button>
      </form>
    </section>
  )
}
