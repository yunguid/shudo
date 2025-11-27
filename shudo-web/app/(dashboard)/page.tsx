import { createClient } from '@/lib/supabase/server'
import { redirect } from 'next/navigation'
import { RecentMeals } from '@/components/dashboard/recent-meals'
import { MacroSparkline } from '@/components/charts/macro-sparkline'
import { Card, CardContent } from '@/components/ui/card'
import { fetchDailyTotals, fetchProfile, fetchRecentEntries } from '@/lib/supabase/queries'
import { calculateStreak, getDateRangeForDays } from '@/lib/utils'
import { Flame } from 'lucide-react'

export default async function DashboardPage() {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  if (!user) redirect('/auth/login')

  const [profile, last7Days, last14Days, recentEntries] = await Promise.all([
    fetchProfile(supabase, user.id),
    fetchDailyTotals(supabase, user.id, getDateRangeForDays(7).start, getDateRangeForDays(7).end),
    fetchDailyTotals(supabase, user.id, getDateRangeForDays(14).start, getDateRangeForDays(14).end),
    fetchRecentEntries(supabase, user.id, 5),
  ])

  const targetProtein = profile?.daily_macro_target?.protein_g || 180
  const targetCalories = profile?.daily_macro_target?.calories_kcal || 2800
  const streak = calculateStreak(last14Days, targetProtein, targetCalories)

  return (
    <div className="min-h-screen p-6 space-y-4">
      {/* Streak */}
      {streak > 0 && (
        <div className="flex items-center gap-2 text-sm text-muted">
          <Flame className="h-4 w-4 text-warning" />
          <span>{streak} day streak</span>
        </div>
      )}

      {/* Charts */}
      <div className="grid grid-cols-2 gap-4">
        <Card>
          <CardContent className="p-4">
            <p className="text-[10px] font-semibold uppercase tracking-wide text-muted mb-2">Calories</p>
            <MacroSparkline data={last7Days} dataKey="total_calories" color="#4385F4" target={targetCalories} />
          </CardContent>
        </Card>
        <Card>
          <CardContent className="p-4">
            <p className="text-[10px] font-semibold uppercase tracking-wide text-muted mb-2">Protein</p>
            <MacroSparkline data={last7Days} dataKey="total_protein" color="#8BB5FE" target={targetProtein} unit="g" />
          </CardContent>
        </Card>
      </div>

      {/* Recent */}
      <RecentMeals entries={recentEntries} />
    </div>
  )
}



