import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { parseAnalysisItems } from '@/lib/analysis'

describe('parseAnalysisItems', () => {
  it('reads well-formed items with trimmed strings', () => {
    const items = parseAnalysisItems([
      {
        name: '  Grilled chicken ',
        amount: ' 6 oz ',
        protein_g: 42.5,
        carbs_g: 0,
        fat_g: 7,
        calories_kcal: 250,
        confidence: 0.9,
      },
    ])

    assert.equal(items.length, 1)
    assert.equal(items[0].name, 'Grilled chicken')
    assert.equal(items[0].amount, '6 oz')
    assert.equal(items[0].protein_g, 42.5)
  })

  it('degrades malformed rows to an empty breakdown instead of crashing', () => {
    assert.deepEqual(parseAnalysisItems(null), [])
    assert.deepEqual(parseAnalysisItems('not-an-array'), [])
    assert.deepEqual(parseAnalysisItems([null, 'string', 42, ['nested']]), [])
    assert.deepEqual(parseAnalysisItems([{ amount: 'no name' }, { name: '   ' }]), [])
  })

  it('zeroes negative or non-numeric macros rather than rendering them', () => {
    const [item] = parseAnalysisItems([
      { name: 'Mystery', protein_g: -5, carbs_g: 'many', fat_g: Infinity, calories_kcal: 120 },
    ])

    assert.equal(item.protein_g, 0)
    assert.equal(item.carbs_g, 0)
    assert.equal(item.fat_g, 0)
    assert.equal(item.calories_kcal, 120)
    assert.equal(item.amount, '')
  })
})
