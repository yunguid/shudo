import type { AnalysisItem, Json } from '@/types/database'

function finiteNonnegative(value: Json | undefined): number {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : 0
}

/**
 * Defensive read of entries.items: process_entry validates the shape on
 * write, but a malformed row should degrade to "no breakdown", not a 500.
 */
export function parseAnalysisItems(value: Json): AnalysisItem[] {
  if (!Array.isArray(value)) return []

  const items: AnalysisItem[] = []
  for (const candidate of value) {
    if (!candidate || typeof candidate !== 'object' || Array.isArray(candidate)) continue
    const item = candidate as Record<string, Json | undefined>
    if (typeof item.name !== 'string' || !item.name.trim()) continue
    items.push({
      name: item.name.trim(),
      amount: typeof item.amount === 'string' ? item.amount.trim() : '',
      protein_g: finiteNonnegative(item.protein_g),
      carbs_g: finiteNonnegative(item.carbs_g),
      fat_g: finiteNonnegative(item.fat_g),
      calories_kcal: finiteNonnegative(item.calories_kcal),
      confidence: finiteNonnegative(item.confidence),
    })
  }
  return items
}
