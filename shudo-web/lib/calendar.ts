import { isLocalDay } from '@/lib/utils'

const MONTH_PATTERN = /^\d{4}-(0[1-9]|1[0-2])$/

export function isCalendarMonth(value: string | undefined): value is string {
  return Boolean(value && MONTH_PATTERN.test(value))
}

export function monthOf(localDay: string): string {
  if (!isLocalDay(localDay)) throw new Error(`Invalid local day: ${localDay}`)
  return localDay.slice(0, 7)
}

export function shiftMonth(month: string, amount: number): string {
  if (!isCalendarMonth(month)) throw new Error(`Invalid month: ${month}`)
  const [year, monthNumber] = month.split('-').map(Number)
  const date = new Date(Date.UTC(year, monthNumber - 1 + amount, 1))
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, '0')}`
}

/** Inclusive count of calendar months from startMonth through endMonth. */
export function monthsBetween(startMonth: string, endMonth: string): number {
  if (!isCalendarMonth(startMonth)) throw new Error(`Invalid month: ${startMonth}`)
  if (!isCalendarMonth(endMonth)) throw new Error(`Invalid month: ${endMonth}`)
  const [startYear, startMonthNumber] = startMonth.split('-').map(Number)
  const [endYear, endMonthNumber] = endMonth.split('-').map(Number)
  return (endYear - startYear) * 12 + (endMonthNumber - startMonthNumber) + 1
}

export function monthStart(month: string): string {
  if (!isCalendarMonth(month)) throw new Error(`Invalid month: ${month}`)
  return `${month}-01`
}

export function monthEnd(month: string): string {
  if (!isCalendarMonth(month)) throw new Error(`Invalid month: ${month}`)
  const [year, monthNumber] = month.split('-').map(Number)
  const lastDay = new Date(Date.UTC(year, monthNumber, 0)).getUTCDate()
  return `${month}-${String(lastDay).padStart(2, '0')}`
}

/**
 * Monday-start week rows for one month, with null pads so every row has
 * seven cells — the same shape a paper calendar page has.
 */
export function buildMonthGrid(month: string): (string | null)[][] {
  if (!isCalendarMonth(month)) throw new Error(`Invalid month: ${month}`)
  const [year, monthNumber] = month.split('-').map(Number)
  const dayCount = new Date(Date.UTC(year, monthNumber, 0)).getUTCDate()
  const firstWeekday = new Date(Date.UTC(year, monthNumber - 1, 1)).getUTCDay()
  const leadingPad = (firstWeekday || 7) - 1

  const cells: (string | null)[] = Array.from({ length: leadingPad }, () => null)
  for (let day = 1; day <= dayCount; day += 1) {
    cells.push(`${month}-${String(day).padStart(2, '0')}`)
  }
  while (cells.length % 7 !== 0) cells.push(null)

  const weeks: (string | null)[][] = []
  for (let index = 0; index < cells.length; index += 7) {
    weeks.push(cells.slice(index, index + 7))
  }
  return weeks
}

export function formatMonthLabel(month: string): string {
  if (!isCalendarMonth(month)) return month
  const [year, monthNumber] = month.split('-').map(Number)
  return new Intl.DateTimeFormat('en-US', {
    timeZone: 'UTC',
    month: 'long',
    year: 'numeric',
  }).format(new Date(Date.UTC(year, monthNumber - 1, 1)))
}

export interface MacroSplit {
  proteinShare: number
  carbsShare: number
  fatShare: number
}

/**
 * Caloric composition of a day (4/4/9 kcal per gram), so the bar answers
 * "what was this day made of" rather than comparing raw gram counts.
 */
export function macroCalorieSplit(
  proteinG: number,
  carbsG: number,
  fatG: number,
): MacroSplit | null {
  const protein = Math.max(0, proteinG) * 4
  const carbs = Math.max(0, carbsG) * 4
  const fat = Math.max(0, fatG) * 9
  const total = protein + carbs + fat
  if (!Number.isFinite(total) || total <= 0) return null

  return {
    proteinShare: (protein / total) * 100,
    carbsShare: (carbs / total) * 100,
    fatShare: (fat / total) * 100,
  }
}
