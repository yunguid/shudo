import { Card, CardContent } from '@/components/ui/card'
import { Entry } from '@/types/database'
import { summarizeEntry } from '@/lib/supabase/queries'
import { format, parseISO } from 'date-fns'
import Link from 'next/link'

interface RecentMealsProps {
  entries: Entry[]
}

export function RecentMeals({ entries }: RecentMealsProps) {
  if (!entries.length) return null

  return (
    <Card>
      <CardContent className="p-4">
        <div className="flex items-center justify-between mb-3">
          <p className="text-[10px] font-semibold uppercase tracking-wide text-muted">Recent</p>
          <Link href="/meals" className="text-[10px] text-accent hover:underline">View all</Link>
        </div>
        <div className="space-y-2">
          {entries.map((entry) => (
            <div key={entry.id} className="flex items-center justify-between">
              <div className="min-w-0 flex-1">
                <p className="text-sm text-ink truncate">{summarizeEntry(entry)}</p>
                <p className="text-[10px] text-muted">{format(parseISO(entry.created_at), 'MMM d · h:mma').toLowerCase()}</p>
              </div>
              <span className="text-xs font-mono text-muted ml-2">{entry.calories_kcal?.toFixed(0)}</span>
            </div>
          ))}
        </div>
      </CardContent>
    </Card>
  )
}



