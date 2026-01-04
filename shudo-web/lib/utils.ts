import { type ClassValue, clsx } from 'clsx'
import { twMerge } from 'tailwind-merge'

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

export function formatNumber(value: number, decimals = 0): string {
  return value.toLocaleString('en-US', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })
}

export function calculateStreak(
  days: { local_day: string; total_protein: number; total_calories: number }[],
  targetProtein: number,
  targetCalories: number
): number {
  if (!days.length) return 0
  
  // Sort days in descending order (most recent first)
  const sorted = [...days].sort((a, b) => 
    new Date(b.local_day).getTime() - new Date(a.local_day).getTime()
  )
  
  let streak = 0
  for (const day of sorted) {
    const hitProtein = day.total_protein >= targetProtein * 0.9 // 90% threshold
    const hitCalories = day.total_calories >= targetCalories * 0.85 && 
                        day.total_calories <= targetCalories * 1.15 // within 15%
    
    if (hitProtein && hitCalories) {
      streak++
    } else {
      break
    }
  }
  
  return streak
}

export function getDateRangeForDays(days: number): { start: Date; end: Date } {
  const end = new Date()
  const start = new Date()
  start.setDate(start.getDate() - days + 1)
  start.setHours(0, 0, 0, 0)
  end.setHours(23, 59, 59, 999)
  return { start, end }
}

/**
 * Formats a date as YYYY-MM-DD in the user's local timezone.
 * IMPORTANT: Do NOT use toISOString() as it converts to UTC first,
 * which causes dates to shift by a day for users not in UTC.
 */
export function formatLocalDay(date: Date, timezone?: string): string {
  if (timezone) {
    // Use specified timezone
    return date.toLocaleDateString('en-CA', { timeZone: timezone }) // en-CA gives YYYY-MM-DD format
  }
  // Use local timezone - manually construct to avoid UTC conversion
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

export function parseLocalDay(localDay: string): Date {
  const [year, month, day] = localDay.split('-').map(Number)
  return new Date(year, month - 1, day)
}



