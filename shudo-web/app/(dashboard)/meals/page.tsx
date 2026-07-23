import type { Metadata } from 'next'
import Link from 'next/link'
import { Camera, ChevronLeft, ChevronRight } from 'lucide-react'
import { redirect } from 'next/navigation'
import { getCurrentUser } from '@/lib/auth'
import {
  fetchAllEntries,
  fetchDayTotalsInRange,
  fetchProfileSettings,
  summarizeEntry,
} from '@/lib/supabase/queries'
import { createServerSupabaseClient } from '@/lib/supabase/server'
import { formatDayLabel, formatEntryTime, resolveEntryTimestamp } from '@/lib/utils'
import type { EntryListItem } from '@/types/database'

export const metadata: Metadata = {
  title: 'History',
}

interface MealsPageProps {
  searchParams: Promise<{ page?: string | string[] }>
}

function parsePage(value: string | string[] | undefined): number {
  const rawValue = Array.isArray(value) ? value[0] : value
  const page = Number.parseInt(rawValue ?? '1', 10)
  return Number.isSafeInteger(page) && page > 0 ? page : 1
}

function groupEntries(entries: EntryListItem[]): Map<string, EntryListItem[]> {
  const groups = new Map<string, EntryListItem[]>()
  for (const entry of entries) {
    const dayEntries = groups.get(entry.local_day) ?? []
    dayEntries.push(entry)
    groups.set(entry.local_day, dayEntries)
  }
  return groups
}

export default async function MealsPage({ searchParams }: MealsPageProps) {
  const user = await getCurrentUser()
  if (!user) redirect('/auth/login')

  const { page: pageValue } = await searchParams
  const page = parsePage(pageValue)
  const limit = 30
  const supabase = await createServerSupabaseClient()
  const [profile, { entries, total }] = await Promise.all([
    fetchProfileSettings(supabase, user.id),
    fetchAllEntries(supabase, user.id, { limit, offset: (page - 1) * limit }),
  ])
  const totalPages = Math.max(1, Math.ceil(total / limit))
  if (total > 0 && page > totalPages) redirect(`/meals?page=${totalPages}`)

  const groupedEntries = groupEntries(entries)
  // Entries are ordered newest-first, so the page's day range is
  // [last entry's day, first entry's day]. True day totals keep a day that
  // straddles a pagination boundary from showing a partial sum.
  const dayTotals = entries.length
    ? await fetchDayTotalsInRange(
      supabase,
      user.id,
      entries[entries.length - 1].local_day,
      entries[0].local_day,
    )
    : new Map()

  return (
    <div className="space-y-7">
      <header className="flex items-end justify-between gap-4">
        <div>
          <p className="text-xs font-medium uppercase tracking-[0.18em] text-accent">Archive</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight text-ink">Meal history</h1>
          <p className="mt-2 text-sm text-muted">{total.toLocaleString()} completed entries · {profile.timezone}</p>
        </div>
      </header>

      {entries.length ? (
        <div className="space-y-5">
          {Array.from(groupedEntries.entries()).map(([day, dayEntries]) => {
            const totals = dayTotals.get(day)
            const calories = totals?.total_calories ??
              dayEntries.reduce((sum, entry) => sum + (entry.calories_kcal ?? 0), 0)
            const protein = totals?.total_protein ??
              dayEntries.reduce((sum, entry) => sum + (entry.protein_g ?? 0), 0)

            return (
              <section aria-labelledby={`day-${day}`} className="overflow-hidden rounded-[1.75rem] bg-surface/60" key={day}>
                <div className="flex items-center justify-between gap-4 bg-surface px-5 py-4">
                  <div>
                    <h2 className="text-sm font-medium text-ink" id={`day-${day}`}>
                      {formatDayLabel(day, true)}
                    </h2>
                    <p className="mt-1 font-mono text-[11px] text-subtle">
                      {Math.round(calories).toLocaleString()} kcal · {Math.round(protein)}g protein
                    </p>
                  </div>
                  <Link
                    className="flex min-h-11 items-center rounded-xl px-3 py-2 text-xs font-medium text-accent hover:bg-accent/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
                    href={`/?day=${day}`}
                  >
                    Open day
                  </Link>
                </div>

                {dayEntries.map((entry) => (
                  <article className="flex items-center gap-4 px-5 py-4 transition hover:bg-surface-strong/70" key={entry.id}>
                    <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-surface-strong text-muted">
                      {entry.image_path ? (
                        <Camera aria-hidden="true" className="h-4 w-4" />
                      ) : (
                        <span className="h-1.5 w-1.5 rounded-full bg-accent/70" />
                      )}
                    </div>
                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm text-ink">{summarizeEntry(entry)}</p>
                      <time className="mt-1 block text-xs text-subtle" dateTime={resolveEntryTimestamp(entry.occurred_at, entry.created_at)}>
                        {formatEntryTime(resolveEntryTimestamp(entry.occurred_at, entry.created_at), profile.timezone)}
                      </time>
                    </div>
                    <div className="shrink-0 text-right font-mono text-xs">
                      <p className="text-ink">{Math.round(entry.calories_kcal ?? 0)} kcal</p>
                      <p className="mt-1 text-protein">{Math.round(entry.protein_g ?? 0)}g</p>
                    </div>
                  </article>
                ))}
              </section>
            )
          })}
        </div>
      ) : (
        <div className="rounded-[1.75rem] bg-surface/50 px-6 py-20 text-center">
          <p className="text-sm text-muted">No completed meals yet.</p>
          <p className="mt-1 text-xs text-subtle">Your phone entries will collect here automatically.</p>
        </div>
      )}

      {totalPages > 1 ? (
        <nav aria-label="History pages" className="flex items-center justify-between pt-2">
          {page > 1 ? (
            <Link
              className="flex min-h-11 items-center gap-1 rounded-xl px-3 py-2 text-sm text-muted hover:bg-surface hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
              href={`/meals?page=${page - 1}`}
            >
              <ChevronLeft aria-hidden="true" className="h-4 w-4" /> Previous
            </Link>
          ) : (
            <span />
          )}
          <span className="text-xs text-subtle">{page} of {totalPages}</span>
          {page < totalPages ? (
            <Link
              className="flex min-h-11 items-center gap-1 rounded-xl px-3 py-2 text-sm text-muted hover:bg-surface hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
              href={`/meals?page=${page + 1}`}
            >
              Next <ChevronRight aria-hidden="true" className="h-4 w-4" />
            </Link>
          ) : (
            <span />
          )}
        </nav>
      ) : null}
    </div>
  )
}
