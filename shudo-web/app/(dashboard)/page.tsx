import Link from 'next/link'
import { Camera, MoveRight } from 'lucide-react'
import { redirect } from 'next/navigation'
import { DayNavigator } from '@/components/day-navigator'
import { getCurrentUser } from '@/lib/auth'
import {
  fetchDashboardWindow,
  fetchDailyTargetHistory,
  fetchProfileSettings,
  summarizeEntry,
} from '@/lib/supabase/queries'
import { createServerSupabaseClient } from '@/lib/supabase/server'
import { effectiveMacroTarget } from '@/lib/targets'
import {
  clampPercent,
  formatEntryTime,
  formatLocalDay,
  formatShortDay,
  isLocalDay,
  resolveEntryTimestamp,
  shiftLocalDay,
} from '@/lib/utils'

interface DashboardPageProps {
  searchParams: Promise<{ day?: string | string[] }>
}

export default async function DashboardPage({ searchParams }: DashboardPageProps) {
  const user = await getCurrentUser()
  if (!user) redirect('/auth/login')

  const supabase = await createServerSupabaseClient()
  const profile = await fetchProfileSettings(supabase, user.id)
  const todayDay = formatLocalDay(new Date(), profile.timezone)
  const { day } = await searchParams
  const requestedDay = Array.isArray(day) ? day[0] : day
  const selectedDay = isLocalDay(requestedDay) && requestedDay <= todayDay ? requestedDay : todayDay

  const windowStart = shiftLocalDay(selectedDay, -6)
  const [{ totals, entries, recentDays }, targetHistory] = await Promise.all([
    fetchDashboardWindow(supabase, user.id, selectedDay, selectedDay),
    fetchDailyTargetHistory(supabase, user.id, selectedDay, windowStart),
  ])

  const target = effectiveMacroTarget(targetHistory, selectedDay, profile.dailyMacroTarget)
  const calorieProgress = clampPercent((totals.total_calories / target.calories_kcal) * 100)
  const macroMetrics = [
    { label: 'Protein', value: totals.total_protein, target: target.protein_g, color: 'text-protein' },
    { label: 'Carbs', value: totals.total_carbs, target: target.carbs_g, color: 'text-carbs' },
    { label: 'Fat', value: totals.total_fat, target: target.fat_g, color: 'text-fat' },
  ] as const

  return (
    <div className="space-y-8">
      <header className="flex flex-col items-start justify-between gap-4 sm:flex-row sm:items-center">
        <DayNavigator selectedDay={selectedDay} todayDay={todayDay} />
        <p className="text-xs text-subtle">Day boundary · {profile.timezone}</p>
      </header>

      <section aria-labelledby="daily-total-heading" className="rounded-[2rem] bg-surface/75 p-6 shadow-2xl shadow-black/20 sm:p-8">
        <div className="flex flex-col justify-between gap-8 md:flex-row md:items-end">
          <div>
            <p className="text-xs font-medium uppercase tracking-[0.18em] text-muted">Daily energy</p>
            <div className="mt-3 flex items-baseline gap-2">
              <h1 id="daily-total-heading" className="font-mono text-5xl font-medium tracking-[-0.06em] text-ink sm:text-6xl">
                {Math.round(totals.total_calories).toLocaleString()}
              </h1>
              <span className="text-sm text-muted">/ {target.calories_kcal.toLocaleString()} kcal</span>
            </div>
            <div
              aria-label={`${Math.round(calorieProgress)} percent of calorie target`}
              aria-valuemax={100}
              aria-valuemin={0}
              aria-valuenow={Math.round(calorieProgress)}
              className="mt-5 h-2 w-full overflow-hidden rounded-full bg-surface-strong sm:w-96"
              role="progressbar"
            >
              <div
                className="h-full rounded-full bg-accent transition-[width]"
                style={{ width: `${calorieProgress}%` }}
              />
            </div>
          </div>

          <dl className="grid grid-cols-3 gap-7 sm:gap-10">
            {macroMetrics.map((macro) => (
              <div key={macro.label}>
                <dt className="text-xs text-muted">{macro.label}</dt>
                <dd className={`mt-1 font-mono text-xl font-medium ${macro.color}`}>
                  {Math.round(macro.value)}g
                </dd>
                <dd className="mt-0.5 text-[11px] text-subtle">of {macro.target}g</dd>
              </div>
            ))}
          </dl>
        </div>
      </section>

      <div className="grid gap-8 lg:grid-cols-[minmax(0,1.35fr)_minmax(16rem,0.65fr)]">
        <section aria-labelledby="entries-heading">
          <div className="mb-3 flex items-center justify-between px-1">
            <h2 id="entries-heading" className="text-sm font-medium text-ink">Meals</h2>
            <span className="text-xs text-subtle">{totals.entry_count} logged</span>
          </div>

          {entries.length ? (
            <div className="overflow-hidden rounded-[1.75rem] bg-surface/60">
              {entries.map((entry) => (
                <article className="flex items-center gap-4 px-5 py-4 transition hover:bg-surface-strong/70" key={entry.id}>
                  <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-surface-strong text-muted">
                    {entry.image_path ? (
                      <Camera aria-hidden="true" className="h-4 w-4" />
                    ) : (
                      <span className="h-2 w-2 rounded-full bg-accent/80" />
                    )}
                  </div>
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-sm text-ink">{summarizeEntry(entry)}</p>
                    <time className="mt-1 block text-xs text-subtle" dateTime={resolveEntryTimestamp(entry.occurred_at, entry.created_at)}>
                      {formatEntryTime(resolveEntryTimestamp(entry.occurred_at, entry.created_at), profile.timezone)}
                    </time>
                  </div>
                  <div className="shrink-0 text-right font-mono">
                    <p className="text-sm text-ink">{Math.round(entry.calories_kcal ?? 0)}</p>
                    <p className="mt-1 text-[11px] text-protein">{Math.round(entry.protein_g ?? 0)}g protein</p>
                  </div>
                </article>
              ))}
            </div>
          ) : (
            <div className="rounded-[1.75rem] bg-surface/50 px-6 py-14 text-center">
              <p className="text-sm text-muted">Nothing logged for this day.</p>
              <p className="mt-1 text-xs text-subtle">Entries added on your phone will appear here.</p>
            </div>
          )}
        </section>

        <section aria-labelledby="recent-heading">
          <div className="mb-3 flex items-center justify-between px-1">
            <h2 id="recent-heading" className="text-sm font-medium text-ink">Seven days</h2>
            <Link
              className="flex min-h-11 items-center gap-1 rounded-xl px-2 text-xs text-accent hover:bg-accent/10 hover:text-accent-bright focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
              href="/meals"
            >
              History <MoveRight aria-hidden="true" className="h-3.5 w-3.5" />
            </Link>
          </div>

          <div className="rounded-[1.75rem] bg-surface/60 px-4 pb-4 pt-6">
            <div className="grid h-36 grid-cols-7 items-end gap-2">
              {recentDays.map((dayTotal) => {
                const dayTarget = effectiveMacroTarget(
                  targetHistory,
                  dayTotal.local_day,
                  profile.dailyMacroTarget,
                )
                const height = clampPercent(
                  (dayTotal.total_calories / dayTarget.calories_kcal) * 100,
                )
                const isSelected = dayTotal.local_day === selectedDay
                return (
                  <Link
                    aria-label={`${formatShortDay(dayTotal.local_day)}: ${Math.round(dayTotal.total_calories)} calories`}
                    className="group flex h-full items-end rounded-xl bg-surface-strong/55 p-1 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
                    href={`/?day=${dayTotal.local_day}`}
                    key={dayTotal.local_day}
                  >
                    <span
                      className={`block w-full rounded-lg transition group-hover:brightness-110 ${isSelected ? 'bg-accent' : 'bg-accent/35'}`}
                      style={{ height: `${Math.max(height, dayTotal.entry_count ? 4 : 0)}%` }}
                    />
                  </Link>
                )
              })}
            </div>
            <div aria-hidden="true" className="mt-3 grid grid-cols-7 gap-2 text-center text-[10px] uppercase tracking-wide text-subtle">
              {recentDays.map((dayTotal) => (
                <span key={dayTotal.local_day}>{formatShortDay(dayTotal.local_day)}</span>
              ))}
            </div>
          </div>
        </section>
      </div>
    </div>
  )
}
