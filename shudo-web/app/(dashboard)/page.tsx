import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { Card, CardContent } from '@/components/ui/card'
import { fetchTodayData, fetchDailyTotals, fetchProfile, summarizeEntry } from '@/lib/supabase/queries'
import { getDateRangeForDays } from '@/lib/utils'
import { format, parseISO } from 'date-fns'
import Link from 'next/link'

export default async function DashboardPage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  if (!user) redirect('/auth/login')

  const [profile, todayData, last7Days] = await Promise.all([
    fetchProfile(supabase, user.id),
    fetchTodayData(supabase, user.id),
    fetchDailyTotals(supabase, user.id, getDateRangeForDays(7).start, getDateRangeForDays(7).end),
  ])

  const targetProtein = profile?.daily_macro_target?.protein_g || 150
  const targetCalories = profile?.daily_macro_target?.calories_kcal || 2200
  const { totals: today, entries: todayEntries } = todayData

  const calPct = Math.min((today.total_calories / targetCalories) * 100, 100)
  const proteinPct = Math.min((today.total_protein / targetProtein) * 100, 100)

  return (
    <div className="min-h-screen p-6 space-y-6">
      {/* TODAY - Hero */}
      <div>
        <h1 className="text-sm font-medium text-muted mb-4">Today</h1>
        
        {/* Progress bars */}
        <div className="space-y-4">
          {/* Calories */}
          <div>
            <div className="flex justify-between items-baseline mb-1.5">
              <span className="text-2xl font-bold font-mono text-ink">{today.total_calories.toFixed(0)}</span>
              <span className="text-xs text-muted">/ {targetCalories} cal</span>
            </div>
            <div className="h-2 bg-elevated rounded-full overflow-hidden">
              <div 
                className="h-full bg-accent rounded-full transition-all duration-500" 
                style={{ width: `${calPct}%` }} 
              />
            </div>
          </div>

          {/* Protein */}
          <div>
            <div className="flex justify-between items-baseline mb-1.5">
              <span className="text-2xl font-bold font-mono text-ink">{today.total_protein.toFixed(0)}<span className="text-sm text-muted ml-1">g</span></span>
              <span className="text-xs text-muted">/ {targetProtein}g protein</span>
            </div>
            <div className="h-2 bg-elevated rounded-full overflow-hidden">
              <div 
                className="h-full bg-ring-protein rounded-full transition-all duration-500" 
                style={{ width: `${proteinPct}%` }} 
              />
            </div>
          </div>
        </div>
      </div>

      {/* Today's meals */}
      {todayEntries.length > 0 && (
        <Card>
          <CardContent className="p-0">
            <div className="divide-y divide-rule">
              {todayEntries.map((entry) => (
                <div key={entry.id} className="flex items-center justify-between px-4 py-3">
                  <div className="min-w-0 flex-1">
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
          </CardContent>
        </Card>
      )}

      {todayEntries.length === 0 && (
        <div className="text-center py-8 text-sm text-muted">
          No meals logged today
        </div>
      )}

      {/* 7-day history */}
      {last7Days.length > 1 && (
        <div>
          <div className="flex items-center justify-between mb-3">
            <h2 className="text-xs font-medium text-muted uppercase tracking-wide">This Week</h2>
            <Link href="/meals" className="text-[10px] text-accent hover:underline">All meals</Link>
          </div>
          <div className="grid grid-cols-7 gap-1">
            {last7Days.map((day) => {
              const pct = Math.min((day.total_calories / targetCalories) * 100, 100)
              return (
                <div key={day.local_day} className="text-center">
                  <div className="h-16 bg-elevated rounded relative overflow-hidden">
                    <div 
                      className="absolute bottom-0 left-0 right-0 bg-accent/60 transition-all"
                      style={{ height: `${pct}%` }}
                    />
                  </div>
                  <p className="text-[9px] text-muted mt-1">{format(parseISO(day.local_day), 'EEE')}</p>
                </div>
              )
            })}
          </div>
        </div>
      )}
    </div>
  )
}



