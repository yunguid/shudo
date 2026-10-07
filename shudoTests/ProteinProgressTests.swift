import Foundation
import Testing
@testable import shudo

struct ProteinProgressTests {
    private let target = MacroTarget(caloriesKcal: 2_000, proteinG: 150, carbsG: 200, fatG: 70)

    @Test func missingDaysStayUnknownAndTargetsFollowHistoryAcrossDST() throws {
        let now = ISO8601DateFormatter().date(from: "2026-03-09T02:00:00Z")!
        let rows = ProteinProgress.days(
            totals: [
                DailyNutritionTotal(localDay: "2026-03-07", proteinG: 80, carbsG: 0, fatG: 0, caloriesKcal: 320, entryCount: 1),
                DailyNutritionTotal(localDay: "2026-03-08", proteinG: 0, carbsG: 40, fatG: 0, caloriesKcal: 160, entryCount: 1)
            ],
            target: target,
            history: [
                DailyMacroTargetSnapshot(targetDay: "2026-03-01", target: MacroTarget(caloriesKcal: 2_000, proteinG: 100, carbsG: 200, fatG: 70)),
                DailyMacroTargetSnapshot(targetDay: "2026-03-08", target: target)
            ],
            timezone: "America/New_York", now: now
        )
        #expect(rows.count == 7)
        #expect(Set(rows.map(\.localDay)).count == 7)
        #expect(rows.last?.localDay == "2026-03-08")
        #expect(rows.first?.loggedGrams == nil)
        #expect(rows.last?.loggedGrams == 0)
        #expect(rows.last?.remainingGrams == 150)
        #expect(rows.dropLast().last?.targetGrams == 100)
        #expect(rows.dropLast().last?.remainingGrams == 20)
    }

    @Test func remainingGramsNeverGoNegative() {
        let day = ProteinDay(localDay: "2026-09-20", date: Date(), loggedGrams: 103, targetGrams: 178)
        #expect(day.remainingGrams == 75)
        let met = ProteinDay(localDay: day.localDay, date: day.date, loggedGrams: 180, targetGrams: 178)
        #expect(met.remainingGrams == 0)
    }
}
