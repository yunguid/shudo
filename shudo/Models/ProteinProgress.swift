import Foundation

struct ProteinDay: Identifiable, Equatable {
    let localDay: String
    let date: Date
    let loggedGrams: Double?
    let targetGrams: Double
    var id: String { localDay }
    var remainingGrams: Double? { loggedGrams.map { max(0, targetGrams - $0) } }
}

enum ProteinProgress {
    /// Keep all seven dates: missing logs are unknown, including today.
    static func days(
        totals: [DailyNutritionTotal], target: MacroTarget,
        history: [DailyMacroTargetSnapshot], timezone: String, now: Date = Date()
    ) -> [ProteinDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let byDay = totals.reduce(into: [String: DailyNutritionTotal]()) { $0[$1.localDay] = $1 }
        return (-6...0).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) else { return nil }
            let localDay = formatter.string(from: date)
            let total = byDay[localDay]
            let protein = total.flatMap {
                $0.entryCount > 0 && $0.proteinG.isFinite && $0.proteinG >= 0 ? $0.proteinG : nil
            }
            let goal = NutritionProgressPolicy.effectiveTarget(on: localDay, history: history, fallback: target).proteinG
            return ProteinDay(localDay: localDay, date: date, loggedGrams: protein, targetGrams: goal)
        }
    }

    static func todayMessage(_ day: ProteinDay, displayName: String?) -> String {
        let name = displayName?.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        let greeting = name.map { "\($0), " } ?? ""
        guard let logged = day.loggedGrams else {
            return "\(greeting)no protein is logged today yet. Your target is \(Int(day.targetGrams.rounded()))g."
        }
        let loggedGrams = Int(logged.rounded())
        let targetGrams = Int(day.targetGrams.rounded())
        if logged >= day.targetGrams {
            return "\(greeting)you’ve logged \(loggedGrams)g protein today, reaching your \(targetGrams)g target."
        }
        return "\(greeting)you’ve logged \(loggedGrams)g protein today; \(max(0, targetGrams - loggedGrams))g more would reach your \(targetGrams)g target."
    }
}
