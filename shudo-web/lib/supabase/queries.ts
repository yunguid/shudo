import { SupabaseClient } from '@supabase/supabase-js'
import { Entry, Profile, DayTotals } from '@/types/database'
import { formatLocalDay } from '@/lib/utils'

export async function fetchProfile(supabase: SupabaseClient, userId: string): Promise<Profile | null> {
  const { data } = await supabase.from('profiles').select('*').eq('user_id', userId).single()
  return data as Profile | null
}

export async function fetchTodayData(supabase: SupabaseClient, userId: string): Promise<{ totals: DayTotals; entries: Entry[] }> {
  const today = formatLocalDay(new Date())
  
  const { data } = await supabase
    .from('entries')
    .select('*')
    .eq('user_id', userId)
    .eq('status', 'complete')
    .eq('local_day', today)
    .order('created_at', { ascending: false })

  const entries = (data as Entry[]) || []
  const totals: DayTotals = {
    local_day: today,
    total_calories: entries.reduce((sum, e) => sum + (e.calories_kcal || 0), 0),
    total_protein: entries.reduce((sum, e) => sum + (e.protein_g || 0), 0),
    total_carbs: entries.reduce((sum, e) => sum + (e.carbs_g || 0), 0),
    total_fat: entries.reduce((sum, e) => sum + (e.fat_g || 0), 0),
    entry_count: entries.length,
  }
  return { totals, entries }
}

export async function fetchDailyTotals(supabase: SupabaseClient, userId: string, startDate: Date, endDate: Date): Promise<DayTotals[]> {
  const { data } = await supabase
    .from('entries')
    .select('local_day, calories_kcal, protein_g, carbs_g, fat_g')
    .eq('user_id', userId)
    .eq('status', 'complete')
    .gte('local_day', formatLocalDay(startDate))
    .lte('local_day', formatLocalDay(endDate))

  if (!data) return []

  const dayMap = new Map<string, DayTotals>()
  for (const e of data) {
    const d = dayMap.get(e.local_day)
    if (d) {
      d.total_calories += e.calories_kcal || 0
      d.total_protein += e.protein_g || 0
      d.total_carbs += e.carbs_g || 0
      d.total_fat += e.fat_g || 0
      d.entry_count += 1
    } else {
      dayMap.set(e.local_day, {
        local_day: e.local_day,
        total_calories: e.calories_kcal || 0,
        total_protein: e.protein_g || 0,
        total_carbs: e.carbs_g || 0,
        total_fat: e.fat_g || 0,
        entry_count: 1,
      })
    }
  }
  return Array.from(dayMap.values()).sort((a, b) => a.local_day.localeCompare(b.local_day))
}

export async function fetchAllEntries(
  supabase: SupabaseClient,
  userId: string,
  options?: { limit?: number; offset?: number }
): Promise<{ entries: Entry[]; total: number }> {
  let query = supabase
    .from('entries')
    .select('*', { count: 'exact' })
    .eq('user_id', userId)
    .eq('status', 'complete')
    .order('created_at', { ascending: false })

  if (options?.limit) query = query.limit(options.limit)
  if (options?.offset) query = query.range(options.offset, options.offset + (options.limit || 25) - 1)

  const { data, count } = await query
  return { entries: (data as Entry[]) || [], total: count || 0 }
}

export function summarizeEntry(entry: Entry): string {
  if (entry.model_output) {
    const mo = entry.model_output as Record<string, unknown>
    const parsed = (mo.parsed as Record<string, unknown>) ?? mo
    if (typeof parsed.food_name === 'string' && parsed.food_name) return parsed.food_name
    if (typeof parsed.name === 'string' && parsed.name) return parsed.name
    if (Array.isArray(parsed.items) && parsed.items.length > 0) {
      const names = parsed.items.map((i: unknown) => (i as Record<string, unknown>)?.name).filter((n): n is string => typeof n === 'string')
      return names.length <= 2 ? names.join(', ') : `${names.slice(0, 2).join(', ')} +${names.length - 2}`
    }
  }
  return entry.raw_text?.split('\n')[0] || 'Entry'
}



