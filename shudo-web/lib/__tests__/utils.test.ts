import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import {
  clampPercent,
  formatDayLabel,
  formatLocalDay,
  formatShortDay,
  isLocalDay,
  normalizeTimeZone,
  resolveEntryTimestamp,
  safeInternalPath,
  shiftLocalDay,
} from '../utils'

describe('formatLocalDay', () => {
  it('formats the same instant in the saved user timezone', () => {
    const instant = new Date('2026-07-20T03:30:00Z')

    assert.equal(formatLocalDay(instant, 'America/New_York'), '2026-07-19')
    assert.equal(formatLocalDay(instant, 'Asia/Tokyo'), '2026-07-20')
  })

  it('defaults to UTC instead of the server timezone', () => {
    assert.equal(formatLocalDay(new Date('2026-01-01T00:15:00Z')), '2026-01-01')
  })
})

describe('normalizeTimeZone', () => {
  it('keeps valid IANA timezones', () => {
    assert.equal(normalizeTimeZone('America/New_York'), 'America/New_York')
  })

  it('falls back to UTC for missing or invalid values', () => {
    assert.equal(normalizeTimeZone(null), 'UTC')
    assert.equal(normalizeTimeZone('Not/A_Zone'), 'UTC')
  })
})

describe('isLocalDay', () => {
  it('accepts valid calendar days', () => {
    assert.equal(isLocalDay('2024-02-29'), true)
    assert.equal(isLocalDay('2026-07-20'), true)
  })

  it('rejects impossible or malformed days', () => {
    assert.equal(isLocalDay('2023-02-29'), false)
    assert.equal(isLocalDay('2026-13-01'), false)
    assert.equal(isLocalDay('07/20/2026'), false)
    assert.equal(isLocalDay(undefined), false)
  })
})

describe('shiftLocalDay', () => {
  it('crosses month and year boundaries without a timezone conversion', () => {
    assert.equal(shiftLocalDay('2025-12-31', 1), '2026-01-01')
    assert.equal(shiftLocalDay('2026-03-01', -1), '2026-02-28')
  })

  it('throws for an invalid source day', () => {
    assert.throws(() => shiftLocalDay('2026-02-30', 1), /Invalid local day/)
  })
})

describe('day labels', () => {
  it('formats stable labels in UTC', () => {
    assert.equal(formatDayLabel('2026-07-20', true), 'Monday, July 20, 2026')
    assert.equal(formatShortDay('2026-07-20'), 'Mon')
  })
})

describe('clampPercent', () => {
  it('keeps progress values in range', () => {
    assert.equal(clampPercent(-3), 0)
    assert.equal(clampPercent(42), 42)
    assert.equal(clampPercent(140), 100)
  })
})

describe('resolveEntryTimestamp', () => {
  it('uses the logical meal time for backdated entries', () => {
    assert.equal(
      resolveEntryTimestamp('2026-07-18T16:00:00.000Z', '2026-07-20T22:30:00.000Z'),
      '2026-07-18T16:00:00.000Z',
    )
  })

  it('falls back to creation time when the logical timestamp is unavailable', () => {
    assert.equal(
      resolveEntryTimestamp(null, '2026-07-20T22:30:00.000Z'),
      '2026-07-20T22:30:00.000Z',
    )
  })
})

describe('safeInternalPath', () => {
  it('keeps same-origin paths, queries, and fragments', () => {
    assert.equal(safeInternalPath('/meals?page=2#evening'), '/meals?page=2#evening')
  })

  it('rejects absolute, protocol-relative, and backslash-based redirects', () => {
    assert.equal(safeInternalPath('https://example.com/steal'), '/')
    assert.equal(safeInternalPath('//example.com/steal'), '/')
    assert.equal(safeInternalPath('/\\example.com/steal'), '/')
  })

  it('defaults missing and malformed values to the dashboard', () => {
    assert.equal(safeInternalPath(null), '/')
    assert.equal(safeInternalPath('http://[invalid'), '/')
  })
})
