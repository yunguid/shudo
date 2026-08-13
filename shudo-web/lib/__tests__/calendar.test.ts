import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import {
  buildMonthGrid,
  formatMonthLabel,
  isCalendarMonth,
  macroCalorieSplit,
  monthEnd,
  monthOf,
  monthStart,
  monthsBetween,
  shiftMonth,
} from '@/lib/calendar'

describe('month primitives', () => {
  it('validates and derives months from local days', () => {
    assert.equal(isCalendarMonth('2026-08'), true)
    assert.equal(isCalendarMonth('2026-13'), false)
    assert.equal(isCalendarMonth('2026-8'), false)
    assert.equal(monthOf('2026-08-13'), '2026-08')
    assert.throws(() => monthOf('2026-08'))
  })

  it('shifts months across year boundaries', () => {
    assert.equal(shiftMonth('2026-08', -1), '2026-07')
    assert.equal(shiftMonth('2026-01', -1), '2025-12')
    assert.equal(shiftMonth('2025-12', 2), '2026-02')
  })

  it('counts inclusive month spans', () => {
    assert.equal(monthsBetween('2026-08', '2026-08'), 1)
    assert.equal(monthsBetween('2026-06', '2026-08'), 3)
    assert.equal(monthsBetween('2025-11', '2026-02'), 4)
  })

  it('bounds a month by its first and last local day', () => {
    assert.equal(monthStart('2026-08'), '2026-08-01')
    assert.equal(monthEnd('2026-08'), '2026-08-31')
    assert.equal(monthEnd('2026-02'), '2026-02-28')
    assert.equal(monthEnd('2024-02'), '2024-02-29')
  })

  it('labels months for display', () => {
    assert.equal(formatMonthLabel('2026-08'), 'August 2026')
  })
})

describe('buildMonthGrid', () => {
  it('pads Monday-start weeks like a paper calendar page', () => {
    // 2026-08-01 is a Saturday: five leading pads, six week rows.
    const weeks = buildMonthGrid('2026-08')
    assert.equal(weeks.length, 6)
    assert.deepEqual(weeks[0].slice(0, 5), [null, null, null, null, null])
    assert.equal(weeks[0][5], '2026-08-01')
    assert.equal(weeks[5][0], '2026-08-31')
    assert.deepEqual(weeks[5].slice(1), [null, null, null, null, null, null])
    for (const week of weeks) assert.equal(week.length, 7)
  })

  it('handles Sunday-first and leap months', () => {
    // 2026-02-01 is a Sunday: six leading pads, then 28 days in five rows.
    const february = buildMonthGrid('2026-02')
    assert.equal(february.length, 5)
    assert.equal(february[0][6], '2026-02-01')
    // 2024-02-01 is a Thursday in a leap year.
    const leapFebruary = buildMonthGrid('2024-02')
    assert.equal(leapFebruary[0][3], '2024-02-01')
    assert.equal(leapFebruary.flat().filter(Boolean).length, 29)
  })
})

describe('macroCalorieSplit', () => {
  it('splits by caloric contribution, not grams', () => {
    const split = macroCalorieSplit(100, 100, 0)
    assert.ok(split)
    assert.equal(Math.round(split.proteinShare), 50)
    assert.equal(Math.round(split.carbsShare), 50)
    assert.equal(split.fatShare, 0)

    // Fat's 9 kcal/g outweighs an equal gram count of carbs.
    const fatty = macroCalorieSplit(0, 100, 100)
    assert.ok(fatty)
    assert.ok(fatty.fatShare > fatty.carbsShare)
    assert.equal(Math.round(fatty.fatShare + fatty.carbsShare), 100)
  })

  it('returns null for empty days instead of a zero-width bar', () => {
    assert.equal(macroCalorieSplit(0, 0, 0), null)
  })
})
