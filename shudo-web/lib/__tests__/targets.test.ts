import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { effectiveMacroTarget, type DailyTargetSnapshot } from '../targets'

describe('effectiveMacroTarget', () => {
  const original: DailyTargetSnapshot = {
    target_day: '2026-01-01',
    calories_kcal: 2000,
    protein_g: 100,
    carbs_g: 200,
    fat_g: 60,
  }
  const revised: DailyTargetSnapshot = {
    target_day: '2026-07-20',
    calories_kcal: 2400,
    protein_g: 150,
    carbs_g: 260,
    fat_g: 75,
  }

  it('uses the latest target effective on the selected day', () => {
    assert.equal(effectiveMacroTarget([revised, original], '2026-07-19', revised), original)
    assert.equal(effectiveMacroTarget([revised, original], '2026-07-21', original), revised)
  })

  it('falls back when no historical target applies', () => {
    assert.equal(effectiveMacroTarget([revised], '2026-01-01', original), original)
  })
})
