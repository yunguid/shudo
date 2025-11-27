export interface Entry {
  id: string
  created_at: string
  user_id: string
  local_day: string
  status: 'pending' | 'processing' | 'complete' | 'failed'
  raw_text: string | null
  model_output: Record<string, unknown> | null
  protein_g: number
  carbs_g: number
  fat_g: number
  calories_kcal: number
  image_path: string | null
}

export interface Profile {
  user_id: string
  timezone: string
  units: 'imperial' | 'metric'
  height_cm: number | null
  weight_kg: number | null
  target_weight_kg: number | null
  activity_level: string | null
  cutoff_time_local: string | null
  daily_macro_target: MacroTarget
}

export interface MacroTarget {
  calories_kcal: number
  protein_g: number
  carbs_g: number
  fat_g: number
}

export interface DayTotals {
  local_day: string
  total_calories: number
  total_protein: number
  total_carbs: number
  total_fat: number
  entry_count: number
}



