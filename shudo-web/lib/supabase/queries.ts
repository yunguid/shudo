import 'server-only'

import type { PostgrestError, SupabaseClient } from '@supabase/supabase-js'
import { normalizeTimeZone, shiftLocalDay } from '@/lib/utils'
import type {
  Database,
  DayTotals,
  EntryListItem,
  Json,
  MacroTarget,
  ProfileSettings,
} from '@/types/database'

const ENTRY_COLUMNS =
  'id,occurred_at,created_at,local_day,title,raw_text,protein_g,carbs_g,fat_g,calories_kcal,image_path'

const DEFAULT_MACRO_TARGET: MacroTarget = {
  calories_kcal: 2200,
  protein_g: 150,
  carbs_g: 250,
  fat_g: 70,
}

type ShudoSupabaseClient = SupabaseClient<Database>

function queryError(context: string, error: PostgrestError): Error {
  return new Error(`${context}: ${error.message}`, { cause: error })
}

function numberFromJson(value: Json | undefined, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

function parseMacroTarget(value: Json | null): MacroTarget {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return DEFAULT_MACRO_TARGET
  }

  return {
    calories_kcal: numberFromJson(value.calories_kcal, DEFAULT_MACRO_TARGET.calories_kcal),
    protein_g: numberFromJson(value.protein_g, DEFAULT_MACRO_TARGET.protein_g),
    carbs_g: numberFromJson(value.carbs_g, DEFAULT_MACRO_TARGET.carbs_g),
    fat_g: numberFromJson(value.fat_g, DEFAULT_MACRO_TARGET.fat_g),
  }
}

export async function fetchProfileSettings(
  supabase: ShudoSupabaseClient,
  userId: string,
): Promise<ProfileSettings> {
  const { data, error } = await supabase
    .from('profiles')
    .select('timezone,daily_macro_target')
    .eq('user_id', userId)
    .maybeSingle()

  if (error) throw queryError('Unable to load profile settings', error)
  if (!data) throw new Error('Profile settings are missing for the current user.')

  return {
    timezone: normalizeTimeZone(data.timezone),
    dailyMacroTarget: parseMacroTarget(data.daily_macro_target),
  }
}

export async function fetchDayData(
  supabase: ShudoSupabaseClient,
  userId: string,
  localDay: string,
): Promise<{ totals: DayTotals; entries: EntryListItem[] }> {
  const { data, error } = await supabase
    .from('entries')
    .select(ENTRY_COLUMNS)
    .eq('user_id', userId)
    .eq('status', 'complete')
    .eq('local_day', localDay)
    .order('occurred_at', { ascending: false })
    .order('id', { ascending: false })

  if (error) throw queryError('Unable to load daily entries', error)

  const entries = data ?? []
  return {
    totals: entries.reduce<DayTotals>(
      (totals, entry) => ({
        ...totals,
        total_calories: totals.total_calories + (entry.calories_kcal ?? 0),
        total_protein: totals.total_protein + (entry.protein_g ?? 0),
        total_carbs: totals.total_carbs + (entry.carbs_g ?? 0),
        total_fat: totals.total_fat + (entry.fat_g ?? 0),
        entry_count: totals.entry_count + 1,
      }),
      {
        local_day: localDay,
        total_calories: 0,
        total_protein: 0,
        total_carbs: 0,
        total_fat: 0,
        entry_count: 0,
      },
    ),
    entries,
  }
}

export async function fetchDayTotals(
  supabase: ShudoSupabaseClient,
  userId: string,
  endDay: string,
  dayCount = 7,
): Promise<DayTotals[]> {
  const startDay = shiftLocalDay(endDay, -(dayCount - 1))
  const { data, error } = await supabase
    .from('entries')
    .select('local_day,calories_kcal,protein_g,carbs_g,fat_g')
    .eq('user_id', userId)
    .eq('status', 'complete')
    .gte('local_day', startDay)
    .lte('local_day', endDay)

  if (error) throw queryError('Unable to load recent totals', error)

  const totalsByDay = new Map<string, DayTotals>()
  for (const entry of data ?? []) {
    const totals = totalsByDay.get(entry.local_day) ?? {
      local_day: entry.local_day,
      total_calories: 0,
      total_protein: 0,
      total_carbs: 0,
      total_fat: 0,
      entry_count: 0,
    }
    totals.total_calories += entry.calories_kcal ?? 0
    totals.total_protein += entry.protein_g ?? 0
    totals.total_carbs += entry.carbs_g ?? 0
    totals.total_fat += entry.fat_g ?? 0
    totals.entry_count += 1
    totalsByDay.set(entry.local_day, totals)
  }

  return Array.from({ length: dayCount }, (_, index) => {
    const localDay = shiftLocalDay(startDay, index)
    return (
      totalsByDay.get(localDay) ?? {
        local_day: localDay,
        total_calories: 0,
        total_protein: 0,
        total_carbs: 0,
        total_fat: 0,
        entry_count: 0,
      }
    )
  })
}

export async function fetchAllEntries(
  supabase: ShudoSupabaseClient,
  userId: string,
  options: { limit: number; offset: number },
): Promise<{ entries: EntryListItem[]; total: number }> {
  const { data, count, error } = await supabase
    .from('entries')
    .select(ENTRY_COLUMNS, { count: 'exact' })
    .eq('user_id', userId)
    .eq('status', 'complete')
    .order('occurred_at', { ascending: false })
    .order('id', { ascending: false })
    .range(options.offset, options.offset + options.limit - 1)

  if (error) throw queryError('Unable to load entry history', error)

  return { entries: data ?? [], total: count ?? 0 }
}

export function summarizeEntry(entry: EntryListItem): string {
  const title = entry.title?.trim().replace(/\s+/g, ' ')
  if (title) return title

  const firstLine = entry.raw_text
    ?.split('\n')
    .map((line) => line.trim())
    .find(Boolean)
    ?.replace(/\s+/g, ' ')

  if (firstLine) return firstLine
  return entry.image_path ? 'Photo meal' : 'Meal entry'
}
