export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type EntryStatus =
  | 'queued'
  | 'transcribing'
  | 'analyzing'
  | 'complete'
  | 'failed'
  | 'deleting'

export interface MacroTarget {
  calories_kcal: number
  protein_g: number
  carbs_g: number
  fat_g: number
}

export type EntryRow = {
  id: string
  occurred_at: string
  created_at: string
  user_id: string
  local_day: string
  status: EntryStatus
  title: string | null
  raw_text: string | null
  protein_g: number
  carbs_g: number
  fat_g: number
  calories_kcal: number
  image_path: string | null
}

export type ProfileRow = {
  user_id: string
  timezone: string
  daily_macro_target: Json
}

export interface Database {
  public: {
    Tables: {
      entries: {
        Row: EntryRow
        Insert: Partial<EntryRow> & Pick<EntryRow, 'user_id' | 'local_day'>
        Update: Partial<EntryRow>
        Relationships: []
      }
      profiles: {
        Row: ProfileRow
        Insert: Partial<ProfileRow> & Pick<ProfileRow, 'user_id'>
        Update: Partial<ProfileRow>
        Relationships: []
      }
    }
    Views: Record<string, never>
    Functions: Record<string, never>
    Enums: Record<string, never>
    CompositeTypes: Record<string, never>
  }
}

export type EntryListItem = Pick<
  EntryRow,
  | 'id'
  | 'occurred_at'
  | 'created_at'
  | 'local_day'
  | 'title'
  | 'raw_text'
  | 'protein_g'
  | 'carbs_g'
  | 'fat_g'
  | 'calories_kcal'
  | 'image_path'
>

export interface ProfileSettings {
  timezone: string
  dailyMacroTarget: MacroTarget
}

export interface DayTotals {
  local_day: string
  total_calories: number
  total_protein: number
  total_carbs: number
  total_fat: number
  entry_count: number
}
