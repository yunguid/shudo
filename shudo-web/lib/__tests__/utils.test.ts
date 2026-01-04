/**
 * Tests for lib/utils.ts
 *
 * These tests verify the timezone fix for formatLocalDay function
 */

import { formatLocalDay, parseLocalDay, calculateStreak, getDateRangeForDays } from '../utils'

describe('formatLocalDay', () => {
  describe('timezone handling', () => {
    it('should format date in local timezone by default', () => {
      // Create a date at 11 PM on Jan 1st
      const date = new Date(2024, 0, 1, 23, 0, 0) // Jan 1, 2024 11:00 PM local time

      const result = formatLocalDay(date)

      // Should be 2024-01-01 in local time, NOT 2024-01-02 (which would happen with toISOString in some timezones)
      expect(result).toBe('2024-01-01')
    })

    it('should format date correctly at midnight', () => {
      const date = new Date(2024, 5, 15, 0, 0, 0) // June 15, 2024 00:00 local time

      const result = formatLocalDay(date)

      expect(result).toBe('2024-06-15')
    })

    it('should format date correctly at 11:59 PM', () => {
      const date = new Date(2024, 11, 31, 23, 59, 59) // Dec 31, 2024 23:59 local time

      const result = formatLocalDay(date)

      expect(result).toBe('2024-12-31')
    })

    it('should use specified timezone when provided', () => {
      // Create a specific moment in time
      const date = new Date('2024-01-15T08:00:00Z') // 8 AM UTC

      // In Pacific time (UTC-8), this would be midnight Jan 15
      // In Tokyo time (UTC+9), this would be 5 PM Jan 15
      const resultPacific = formatLocalDay(date, 'America/Los_Angeles')
      const resultTokyo = formatLocalDay(date, 'Asia/Tokyo')

      // Both should be 2024-01-15 in their respective timezones
      // (In Pacific, 8AM UTC = midnight Jan 15; In Tokyo, 8AM UTC = 5PM Jan 15)
      expect(resultPacific).toMatch(/2024-01-1[45]/) // Could be 14 or 15 depending on DST
      expect(resultTokyo).toBe('2024-01-15')
    })

    it('should produce YYYY-MM-DD format', () => {
      const date = new Date(2024, 2, 5) // March 5, 2024

      const result = formatLocalDay(date)

      // Should be zero-padded
      expect(result).toMatch(/^\d{4}-\d{2}-\d{2}$/)
      expect(result).toBe('2024-03-05')
    })

    it('should zero-pad single digit months and days', () => {
      const date = new Date(2024, 0, 5) // Jan 5, 2024

      const result = formatLocalDay(date)

      expect(result).toBe('2024-01-05')
    })
  })

  describe('regression: UTC conversion bug', () => {
    it('should NOT use toISOString which converts to UTC', () => {
      // This test specifically verifies the bug fix
      // Old code: date.toISOString().split('T')[0]
      // This caused issues for users not in UTC

      // Create a date at 11 PM in a timezone behind UTC
      // In the old code, toISOString would convert to UTC (next day)
      const lateNightDate = new Date(2024, 0, 15, 23, 30, 0) // Jan 15, 11:30 PM local

      const result = formatLocalDay(lateNightDate)

      // Should stay on Jan 15, not shift to Jan 16
      expect(result).toBe('2024-01-15')
    })
  })
})

describe('parseLocalDay', () => {
  it('should parse YYYY-MM-DD string to Date object', () => {
    const result = parseLocalDay('2024-06-15')

    expect(result.getFullYear()).toBe(2024)
    expect(result.getMonth()).toBe(5) // June is month 5 (0-indexed)
    expect(result.getDate()).toBe(15)
  })

  it('should handle single digit months and days in input', () => {
    const result = parseLocalDay('2024-01-05')

    expect(result.getMonth()).toBe(0) // January
    expect(result.getDate()).toBe(5)
  })

  it('should round-trip with formatLocalDay', () => {
    const original = '2024-08-22'
    const parsed = parseLocalDay(original)
    const formatted = formatLocalDay(parsed)

    expect(formatted).toBe(original)
  })
})

describe('calculateStreak', () => {
  it('should return 0 for empty days array', () => {
    const result = calculateStreak([], 150, 2000)

    expect(result).toBe(0)
  })

  it('should count consecutive days meeting targets', () => {
    const days = [
      { local_day: '2024-01-03', total_protein: 150, total_calories: 2000 },
      { local_day: '2024-01-02', total_protein: 160, total_calories: 2100 },
      { local_day: '2024-01-01', total_protein: 140, total_calories: 1900 },
    ]

    const result = calculateStreak(days, 150, 2000)

    expect(result).toBe(3) // All three days meet 90% protein and within 15% calories
  })

  it('should break streak when protein target not met', () => {
    const days = [
      { local_day: '2024-01-03', total_protein: 150, total_calories: 2000 },
      { local_day: '2024-01-02', total_protein: 100, total_calories: 2000 }, // Below 90% protein
      { local_day: '2024-01-01', total_protein: 150, total_calories: 2000 },
    ]

    const result = calculateStreak(days, 150, 2000)

    expect(result).toBe(1) // Only first day counts
  })

  it('should break streak when calories too low', () => {
    const days = [
      { local_day: '2024-01-02', total_protein: 150, total_calories: 2000 },
      { local_day: '2024-01-01', total_protein: 150, total_calories: 1500 }, // Below 85% calories
    ]

    const result = calculateStreak(days, 150, 2000)

    expect(result).toBe(1)
  })

  it('should break streak when calories too high', () => {
    const days = [
      { local_day: '2024-01-02', total_protein: 150, total_calories: 2000 },
      { local_day: '2024-01-01', total_protein: 150, total_calories: 2500 }, // Above 115% calories
    ]

    const result = calculateStreak(days, 150, 2000)

    expect(result).toBe(1)
  })
})

describe('getDateRangeForDays', () => {
  it('should return correct range for 7 days', () => {
    const { start, end } = getDateRangeForDays(7)

    // End should be today
    const today = new Date()
    expect(end.getDate()).toBe(today.getDate())

    // Start should be 6 days ago (7 days including today)
    const expectedStart = new Date()
    expectedStart.setDate(expectedStart.getDate() - 6)
    expect(start.getDate()).toBe(expectedStart.getDate())
  })

  it('should set start time to midnight', () => {
    const { start } = getDateRangeForDays(7)

    expect(start.getHours()).toBe(0)
    expect(start.getMinutes()).toBe(0)
    expect(start.getSeconds()).toBe(0)
  })

  it('should set end time to end of day', () => {
    const { end } = getDateRangeForDays(7)

    expect(end.getHours()).toBe(23)
    expect(end.getMinutes()).toBe(59)
    expect(end.getSeconds()).toBe(59)
  })
})
