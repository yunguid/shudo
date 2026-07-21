import Link from 'next/link'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { formatDayLabel, shiftLocalDay } from '@/lib/utils'

interface DayNavigatorProps {
  selectedDay: string
  todayDay: string
}

export function DayNavigator({ selectedDay, todayDay }: DayNavigatorProps) {
  const previousDay = shiftLocalDay(selectedDay, -1)
  const nextDay = shiftLocalDay(selectedDay, 1)
  const isToday = selectedDay === todayDay
  const canMoveForward = selectedDay < todayDay

  return (
    <div className="flex flex-wrap items-center gap-3">
      <div className="flex items-center rounded-2xl bg-surface p-1">
        <Link
          aria-label="Previous day"
          className="flex h-11 w-11 items-center justify-center rounded-xl text-muted transition hover:bg-surface-strong hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
          href={`/?day=${previousDay}`}
        >
          <ChevronLeft aria-hidden="true" className="h-4 w-4" />
        </Link>
        <time className="min-w-36 px-2 text-center text-sm font-medium text-ink sm:min-w-44 sm:px-3" dateTime={selectedDay}>
          {isToday
            ? 'Today'
            : formatDayLabel(selectedDay, selectedDay.slice(0, 4) !== todayDay.slice(0, 4))}
        </time>
        {canMoveForward ? (
          <Link
            aria-label="Next day"
            className="flex h-11 w-11 items-center justify-center rounded-xl text-muted transition hover:bg-surface-strong hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
            href={`/?day=${nextDay}`}
          >
            <ChevronRight aria-hidden="true" className="h-4 w-4" />
          </Link>
        ) : (
          <span aria-hidden="true" className="flex h-11 w-11 items-center justify-center text-subtle/60">
            <ChevronRight className="h-4 w-4" />
          </span>
        )}
      </div>

      {!isToday ? (
        <Link
          className="flex min-h-11 items-center rounded-xl px-3 py-2 text-xs font-medium text-accent transition hover:bg-accent/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent"
          href="/"
        >
          Jump to today
        </Link>
      ) : null}
    </div>
  )
}
