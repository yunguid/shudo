'use client'

import { Entry } from '@/types/database'
import { summarizeEntry } from '@/lib/supabase/queries'
import { format, parseISO, isToday, isYesterday } from 'date-fns'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { useRouter } from 'next/navigation'

interface MealsTableProps {
  entries: Entry[]
  page: number
  totalPages: number
}

function groupByDay(entries: Entry[]): Map<string, Entry[]> {
  const groups = new Map<string, Entry[]>()
  for (const entry of entries) {
    const day = entry.local_day
    if (!groups.has(day)) groups.set(day, [])
    groups.get(day)!.push(entry)
  }
  return groups
}

function formatDayHeader(localDay: string): string {
  const date = parseISO(localDay)
  if (isToday(date)) return 'Today'
  if (isYesterday(date)) return 'Yesterday'
  return format(date, 'EEEE, MMM d')
}

export function MealsTable({ entries, page, totalPages }: MealsTableProps) {
  const router = useRouter()
  const grouped = groupByDay(entries)

  const goToPage = (newPage: number) => {
    router.push(`/meals?page=${newPage}`)
  }

  return (
    <div>
      {Array.from(grouped.entries()).map(([day, dayEntries]) => {
        const dayTotal = dayEntries.reduce((sum, e) => sum + (e.calories_kcal || 0), 0)
        const dayProtein = dayEntries.reduce((sum, e) => sum + (e.protein_g || 0), 0)
        
        return (
          <div key={day}>
            {/* Day header */}
            <div className="flex items-center justify-between px-4 py-2 bg-elevated/50 border-b border-rule">
              <span className="text-xs font-medium text-ink">{formatDayHeader(day)}</span>
              <span className="text-[10px] text-muted font-mono">{dayTotal.toFixed(0)} cal · {dayProtein.toFixed(0)}g</span>
            </div>
            
            {/* Day entries */}
            <div className="divide-y divide-rule">
              {dayEntries.map((entry) => (
                <div key={entry.id} className="flex items-center justify-between px-4 py-3 hover:bg-elevated/30">
                  <div className="flex-1 min-w-0">
                    <p className="text-sm text-ink truncate">{summarizeEntry(entry)}</p>
                    <p className="text-[10px] text-muted">{format(parseISO(entry.created_at), 'h:mm a')}</p>
                  </div>
                  <div className="flex items-center gap-3 ml-3 text-xs font-mono">
                    <span className="text-muted">{entry.calories_kcal?.toFixed(0)}</span>
                    <span className="text-ring-protein">{entry.protein_g?.toFixed(0)}g</span>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )
      })}

      {totalPages > 1 && (
        <div className="flex items-center justify-between px-4 py-3 border-t border-rule">
          <span className="text-xs text-muted">{page} / {totalPages}</span>
          <div className="flex gap-1">
            <button
              onClick={() => goToPage(page - 1)}
              disabled={page <= 1}
              className="p-1.5 rounded hover:bg-elevated disabled:opacity-30"
            >
              <ChevronLeft className="h-4 w-4 text-muted" />
            </button>
            <button
              onClick={() => goToPage(page + 1)}
              disabled={page >= totalPages}
              className="p-1.5 rounded hover:bg-elevated disabled:opacity-30"
            >
              <ChevronRight className="h-4 w-4 text-muted" />
            </button>
          </div>
        </div>
      )}
    </div>
  )
}



