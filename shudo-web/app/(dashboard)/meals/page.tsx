import type { Metadata } from 'next'
import Link from 'next/link'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { redirect } from 'next/navigation'
import { getCurrentUser } from '@/lib/auth'
import {
  buildMonthGrid,
  formatMonthLabel,
  macroCalorieSplit,
  monthEnd,
  monthOf,
  monthStart,
  monthsBetween,
  shiftMonth,
} from '@/lib/calendar'
import {
  fetchDayTotalsInRange,
  fetchEarliestEntryDay,
  fetchEntryCount,
  fetchProfileSettings,
} from '@/lib/supabase/queries'
import { createServerSupabaseClient } from '@/lib/supabase/server'
import { formatDayLabel, formatLocalDay } from '@/lib/utils'
import type { DayTotals } from '@/types/database'

export const metadata: Metadata = {
  title: 'History',
}

const MONTHS_PER_PAGE = 3
const WEEKDAY_LETTERS = ['M', 'T', 'W', 'T', 'F', 'S', 'S']

interface MealsPageProps {
  searchParams: Promise<{ page?: string | string[] }>
}

function parsePage(value: string | string[] | undefined): number {
  const rawValue = Array.isArray(value) ? value[0] : value
  const page = Number.parseInt(rawValue ?? '1', 10)
  return Number.isSafeInteger(page) && page > 0 ? page : 1
}

function DayCell({
  day,
  todayDay,
  totals,
}: {
  day: string | null
  todayDay: string
  totals: DayTotals | undefined
}) {
  if (day === null) {
    return <span aria-hidden="true" className="aspect-square" />
  }

  const dayNumber = Number.parseInt(day.slice(8), 10)
  const isToday = day === todayDay
  const todayRing = isToday ? 'ring-1 ring-accent/70' : ''

  if (day > todayDay || !totals || totals.entry_count === 0) {
    return (
      <span
        className={`flex aspect-square items-start justify-end rounded-xl bg-surface/30 p-1.5 font-mono text-[10px] ${
          day > todayDay ? 'text-subtle/40' : 'text-subtle'
        } ${todayRing}`}
      >
        {dayNumber}
      </span>
    )
  }

  const split = macroCalorieSplit(totals.total_protein, totals.total_carbs, totals.total_fat)
  const calories = Math.round(totals.total_calories)

  return (
    <Link
      aria-label={`${formatDayLabel(day, true)}: ${calories.toLocaleString()} calories, ${Math.round(totals.total_protein)} grams protein, ${totals.entry_count} ${totals.entry_count === 1 ? 'meal' : 'meals'}`}
      className={`group flex aspect-square flex-col justify-between rounded-xl bg-surface-strong/70 p-1.5 shadow-[inset_0_0_14px_rgba(220,152,64,0.05)] transition hover:bg-surface-strong focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent sm:p-2 ${todayRing}`}
      href={`/?day=${day}`}
    >
      <span className="self-end font-mono text-[10px] text-muted">{dayNumber}</span>
      <span className="space-y-1">
        <span className="block truncate font-mono text-[11px] font-medium tracking-tight text-ink sm:text-xs">
          {calories.toLocaleString()}
        </span>
        {split ? (
          <span aria-hidden="true" className="flex h-1 overflow-hidden rounded-full">
            <span className="bg-protein" style={{ width: `${split.proteinShare}%` }} />
            <span className="bg-carbs" style={{ width: `${split.carbsShare}%` }} />
            <span className="bg-fat" style={{ width: `${split.fatShare}%` }} />
          </span>
        ) : null}
      </span>
    </Link>
  )
}

export default async function MealsPage({ searchParams }: MealsPageProps) {
  const user = await getCurrentUser()
  if (!user) redirect('/auth/login')

  const { page: pageValue } = await searchParams
  const page = parsePage(pageValue)
  const supabase = await createServerSupabaseClient()
  const [profile, earliestDay, total] = await Promise.all([
    fetchProfileSettings(supabase, user.id),
    fetchEarliestEntryDay(supabase, user.id),
    fetchEntryCount(supabase, user.id),
  ])

  const todayDay = formatLocalDay(new Date(), profile.timezone)
  const currentMonth = monthOf(todayDay)
  const earliestMonth = earliestDay ? monthOf(earliestDay) : currentMonth
  const totalPages = Math.max(1, Math.ceil(monthsBetween(earliestMonth, currentMonth) / MONTHS_PER_PAGE))
  if (page > totalPages) redirect(`/meals?page=${totalPages}`)

  const newestMonth = shiftMonth(currentMonth, -(page - 1) * MONTHS_PER_PAGE)
  const monthCount = Math.min(MONTHS_PER_PAGE, monthsBetween(earliestMonth, newestMonth))
  const months = Array.from({ length: monthCount }, (_, index) => shiftMonth(newestMonth, -index))

  const dayTotals = months.length
    ? await fetchDayTotalsInRange(
      supabase,
      user.id,
      monthStart(months[months.length - 1]),
      monthEnd(months[0]),
    )
    : new Map<string, DayTotals>()

  return (
    <div className="space-y-7">
      <header className="flex items-end justify-between gap-4">
        <div>
          <p className="text-xs font-medium uppercase tracking-[0.18em] text-accent">Archive</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-tight text-ink">History</h1>
          <p className="mt-2 text-sm text-muted">
            {total.toLocaleString()} completed {total === 1 ? 'meal' : 'meals'} · {profile.timezone}
          </p>
        </div>
      </header>

      {total > 0 ? (
        <div className="grid gap-6 sm:grid-cols-2">
          {months.map((month) => (
            <section
              aria-labelledby={`month-${month}`}
              className="rounded-[1.75rem] bg-surface/60 p-4 sm:p-5"
              key={month}
            >
              <h2 className="px-1 text-sm font-medium text-ink" id={`month-${month}`}>
                {formatMonthLabel(month)}
              </h2>
              <div aria-hidden="true" className="mt-4 grid grid-cols-7 gap-1.5 px-0.5 text-center font-mono text-[10px] uppercase text-subtle">
                {WEEKDAY_LETTERS.map((letter, index) => (
                  <span key={`${month}-${letter}-${index}`}>{letter}</span>
                ))}
              </div>
              <div className="mt-2 space-y-1.5">
                {buildMonthGrid(month).map((week, weekIndex) => (
                  <div className="grid grid-cols-7 gap-1.5" key={`${month}-w${weekIndex}`}>
                    {week.map((day, dayIndex) => (
                      <DayCell
                        day={day}
                        key={day ?? `${month}-w${weekIndex}-${dayIndex}`}
                        todayDay={todayDay}
                        totals={day ? dayTotals.get(day) : undefined}
                      />
                    ))}
                  </div>
                ))}
              </div>
            </section>
          ))}
        </div>
      ) : (
        <div className="rounded-[1.75rem] bg-surface/50 px-6 py-20 text-center">
          <p className="text-sm text-muted">No completed meals yet.</p>
          <p className="mt-1 text-xs text-subtle">Your phone entries will collect here automatically.</p>
        </div>
      )}

      <div aria-hidden="true" className="flex flex-wrap items-center gap-x-4 gap-y-1 px-1 text-[11px] text-subtle">
        <span className="flex items-center gap-1.5">
          <span className="h-1.5 w-4 rounded-full bg-protein" /> Protein
        </span>
        <span className="flex items-center gap-1.5">
          <span className="h-1.5 w-4 rounded-full bg-carbs" /> Carbs
        </span>
        <span className="flex items-center gap-1.5">
          <span className="h-1.5 w-4 rounded-full bg-fat" /> Fat
        </span>
        <span className="ml-auto">Share of each day&apos;s calories</span>
      </div>

      {totalPages > 1 ? (
        <nav aria-label="History pages" className="flex items-center justify-between pt-2">
          {page > 1 ? (
            <Link
              className="flex min-h-11 items-center gap-1 rounded-xl px-3 py-2 text-sm text-muted hover:bg-surface hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
              href={`/meals?page=${page - 1}`}
            >
              <ChevronLeft aria-hidden="true" className="h-4 w-4" /> Newer
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
              Older <ChevronRight aria-hidden="true" className="h-4 w-4" />
            </Link>
          ) : (
            <span />
          )}
        </nav>
      ) : null}
    </div>
  )
}
