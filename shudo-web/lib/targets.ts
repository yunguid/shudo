import type { MacroTarget } from '@/types/database'

export interface DailyTargetSnapshot extends MacroTarget {
  target_day: string
}

export function effectiveMacroTarget(
  history: DailyTargetSnapshot[],
  localDay: string,
  fallback: MacroTarget,
): MacroTarget {
  let effective: MacroTarget = fallback
  let effectiveDay = ''
  for (const candidate of history) {
    if (candidate.target_day <= localDay && candidate.target_day >= effectiveDay) {
      effective = candidate
      effectiveDay = candidate.target_day
    }
  }
  return effective
}
