'use client'

import { useState } from 'react'
import { LogOut } from 'lucide-react'
import { useRouter } from 'next/navigation'
import { getBrowserClient } from '@/lib/supabase/client'

export function SignOutButton() {
  const [isSigningOut, setIsSigningOut] = useState(false)
  const [errorMessage, setErrorMessage] = useState('')
  const router = useRouter()

  async function handleSignOut() {
    setIsSigningOut(true)
    setErrorMessage('')

    try {
      const supabase = getBrowserClient()
      const { error } = await supabase.auth.signOut()

      if (error) throw error

      router.replace('/auth/login')
      router.refresh()
    } catch {
      setErrorMessage('Sign-out failed. Check the connection and try again.')
      setIsSigningOut(false)
    }
  }

  return (
    <>
      <button
        aria-label={isSigningOut ? 'Signing out' : 'Sign out'}
        className="flex h-11 w-11 items-center justify-center rounded-xl text-muted transition hover:bg-surface hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent disabled:opacity-50"
        disabled={isSigningOut}
        onClick={handleSignOut}
        title="Sign out"
        type="button"
      >
        <LogOut aria-hidden="true" className="h-4 w-4" />
      </button>
      {errorMessage ? (
        <p
          className="fixed bottom-5 left-1/2 z-50 w-[min(22rem,calc(100vw-2.5rem))] -translate-x-1/2 rounded-2xl bg-danger px-4 py-3 text-center text-sm font-medium text-paper shadow-2xl shadow-black/40"
          role="alert"
        >
          {errorMessage}
        </p>
      ) : null}
    </>
  )
}
