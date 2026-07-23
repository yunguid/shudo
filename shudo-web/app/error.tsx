'use client'

interface RootErrorProps {
  error: Error & { digest?: string }
  reset: () => void
}

/**
 * Catches failures thrown above the dashboard segment (layout auth checks,
 * public pages) so they render the same styled card instead of Next's
 * unstyled default error screen.
 */
export default function RootError({ error, reset }: RootErrorProps) {
  return (
    <div className="flex min-h-screen items-center justify-center px-5">
      <section className="max-w-md rounded-[2rem] bg-surface/75 p-8 text-center shadow-2xl shadow-black/20">
        <p className="text-xs font-medium uppercase tracking-[0.18em] text-danger">Something went wrong</p>
        <h1 className="mt-3 text-2xl font-semibold tracking-tight text-ink">Shudo could not load this page.</h1>
        <p className="mt-3 text-sm leading-6 text-muted">
          Try again in a moment. Your saved entries have not been changed.
        </p>
        {error.digest ? <p className="mt-3 font-mono text-[10px] text-subtle">Reference {error.digest}</p> : null}
        <button
          className="mt-7 rounded-2xl bg-accent px-5 py-3 text-sm font-semibold text-paper hover:bg-accent-bright focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
          onClick={reset}
          type="button"
        >
          Try again
        </button>
      </section>
    </div>
  )
}
