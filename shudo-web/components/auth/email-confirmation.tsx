'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import { CheckCircle2, LoaderCircle, TriangleAlert } from 'lucide-react'
import {
  confirmationUrlWithoutCredentials,
  parseEmailConfirmationUrl,
} from '@/lib/auth-confirmation'
import { getBrowserClient } from '@/lib/supabase/client'

type ConfirmationStatus = 'checking' | 'confirmed' | 'error'

export function EmailConfirmation() {
  const [status, setStatus] = useState<ConfirmationStatus>('checking')

  useEffect(() => {
    let active = true

    async function confirm() {
      const url = new URL(window.location.href)
      const state = parseEmailConfirmationUrl(url)
      window.history.replaceState({}, '', confirmationUrlWithoutCredentials(url))

      if (state.kind === 'confirmed') {
        if (active) setStatus('confirmed')
        return
      }
      if (state.kind === 'error') {
        if (active) setStatus('error')
        return
      }

      const supabase = getBrowserClient()
      const { error } = await supabase.auth.verifyOtp({
        token_hash: state.tokenHash,
        type: state.type,
      })
      if (!error) await supabase.auth.signOut({ scope: 'local' })
      if (active) setStatus(error ? 'error' : 'confirmed')
    }

    void confirm()
    return () => {
      active = false
    }
  }, [])

  if (status === 'checking') {
    return (
      <section className="rounded-[2rem] bg-surface/90 px-6 py-10 text-center shadow-[0_28px_90px_rgba(0,0,0,0.44)] backdrop-blur-xl">
        <LoaderCircle aria-hidden="true" className="mx-auto h-6 w-6 animate-spin text-accent" />
        <h1 className="mt-5 text-2xl font-semibold tracking-[-0.03em] text-ink">Confirming email</h1>
      </section>
    )
  }

  const confirmed = status === 'confirmed'
  return (
    <section className="rounded-[2rem] bg-surface/90 px-6 py-9 text-center shadow-[0_28px_90px_rgba(0,0,0,0.44)] backdrop-blur-xl">
      {confirmed ? (
        <CheckCircle2 aria-hidden="true" className="mx-auto h-7 w-7 text-accent" />
      ) : (
        <TriangleAlert aria-hidden="true" className="mx-auto h-7 w-7 text-danger" />
      )}
      <h1 className="mt-5 text-3xl font-semibold tracking-[-0.035em] text-ink">
        {confirmed ? 'Email confirmed' : 'Link unavailable'}
      </h1>
      <p className="mx-auto mt-3 max-w-sm text-sm leading-6 text-muted">
        {confirmed
          ? 'Return to the Shudo app and sign in with the password you created.'
          : 'This confirmation link is invalid or expired. Request a new one from the Shudo app.'}
      </p>
      <Link
        className="mt-7 inline-flex min-h-12 items-center justify-center rounded-2xl bg-accent px-6 text-sm font-semibold text-paper focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
        href="/auth/login"
      >
        Continue to sign in
      </Link>
    </section>
  )
}
