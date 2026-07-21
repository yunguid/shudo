const LOCAL_DAY_PATTERN = /^\d{4}-\d{2}-\d{2}$/

export function normalizeTimeZone(timeZone: string | null | undefined): string {
  if (!timeZone) return 'UTC'

  try {
    new Intl.DateTimeFormat('en-US', { timeZone }).format()
    return timeZone
  } catch {
    return 'UTC'
  }
}

export function formatLocalDay(date: Date, timeZone = 'UTC'): string {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: normalizeTimeZone(timeZone),
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(date)

  const values = Object.fromEntries(parts.map(({ type, value }) => [type, value]))
  return `${values.year}-${values.month}-${values.day}`
}

export function isLocalDay(value: string | undefined): value is string {
  if (!value || !LOCAL_DAY_PATTERN.test(value)) return false

  const [year, month, day] = value.split('-').map(Number)
  const candidate = new Date(Date.UTC(year, month - 1, day))
  return (
    candidate.getUTCFullYear() === year &&
    candidate.getUTCMonth() === month - 1 &&
    candidate.getUTCDate() === day
  )
}

export function shiftLocalDay(localDay: string, amount: number): string {
  if (!isLocalDay(localDay)) throw new Error(`Invalid local day: ${localDay}`)

  const [year, month, day] = localDay.split('-').map(Number)
  const date = new Date(Date.UTC(year, month - 1, day + amount))
  return date.toISOString().slice(0, 10)
}

export function formatDayLabel(localDay: string, includeYear = false): string {
  if (!isLocalDay(localDay)) return localDay

  const [year, month, day] = localDay.split('-').map(Number)
  return new Intl.DateTimeFormat('en-US', {
    timeZone: 'UTC',
    weekday: 'long',
    month: 'long',
    day: 'numeric',
    ...(includeYear ? { year: 'numeric' } : {}),
  }).format(new Date(Date.UTC(year, month - 1, day)))
}

export function formatShortDay(localDay: string): string {
  if (!isLocalDay(localDay)) return localDay

  const [year, month, day] = localDay.split('-').map(Number)
  return new Intl.DateTimeFormat('en-US', {
    timeZone: 'UTC',
    weekday: 'short',
  }).format(new Date(Date.UTC(year, month - 1, day)))
}

export function formatEntryTime(timestamp: string, timeZone: string): string {
  return new Intl.DateTimeFormat('en-US', {
    timeZone: normalizeTimeZone(timeZone),
    hour: 'numeric',
    minute: '2-digit',
  }).format(new Date(timestamp))
}

export function resolveEntryTimestamp(
  occurredAt: string | null | undefined,
  createdAt: string,
): string {
  if (!occurredAt || Number.isNaN(Date.parse(occurredAt))) return createdAt
  return occurredAt
}

export function safeInternalPath(value: string | null | undefined): string {
  if (!value) return '/'

  const baseUrl = new URL('https://shudo.invalid')

  try {
    const destination = new URL(value, baseUrl)
    if (destination.origin !== baseUrl.origin) return '/'

    return `${destination.pathname}${destination.search}${destination.hash}`
  } catch {
    return '/'
  }
}

export function clampPercent(value: number): number {
  return Math.max(0, Math.min(value, 100))
}
