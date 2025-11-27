'use client'

import { Entry } from '@/types/database'
import { summarizeEntry } from '@/lib/supabase/queries'
import { format, parseISO } from 'date-fns'
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { useRouter } from 'next/navigation'

interface MealsTableProps {
  entries: Entry[]
  page: number
  totalPages: number
}

export function MealsTable({ entries, page, totalPages }: MealsTableProps) {
  const router = useRouter()

  const goToPage = (newPage: number) => {
    router.push(`/meals?page=${newPage}`)
  }

  return (
    <div>
      <div className="divide-y divide-rule">
        {entries.map((entry) => (
          <div key={entry.id} className="flex items-center justify-between px-4 py-3 hover:bg-elevated/50">
            <div className="flex-1 min-w-0">
              <p className="text-sm font-medium text-ink truncate">{summarizeEntry(entry)}</p>
              <p className="text-xs text-muted">
                {format(parseISO(entry.created_at), 'MMM d')} · {format(parseISO(entry.created_at), 'h:mma').toLowerCase()}
              </p>
            </div>
            <div className="flex items-center gap-4 ml-4 text-xs font-mono">
              <span className="text-ink">{entry.calories_kcal?.toFixed(0) || '—'}</span>
              <span className="text-ring-protein">{entry.protein_g?.toFixed(0) || '—'}p</span>
              <span className="text-ring-carb">{entry.carbs_g?.toFixed(0) || '—'}c</span>
              <span className="text-ring-fat">{entry.fat_g?.toFixed(0) || '—'}f</span>
            </div>
          </div>
        ))}
      </div>

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



