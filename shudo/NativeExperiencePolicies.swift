import Foundation

struct WeeklyRepeatedFood: Equatable, Sendable {
    let name: String
    let count: Int
}

struct WeeklyInsightSummary: Equatable, Sendable {
    let weekStart: Date
    let weekEnd: Date
    let headline: String
    let narrative: String
    let repeatedFoods: [WeeklyRepeatedFood]
    let patterns: [String]
    let suggestions: [String]

    init(
        weekStart: Date,
        weekEnd: Date,
        headline: String,
        narrative: String = "",
        repeatedFoods: [WeeklyRepeatedFood] = [],
        patterns: [String],
        suggestions: [String]
    ) {
        self.weekStart = weekStart
        self.weekEnd = weekEnd
        self.headline = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        self.narrative = narrative.trimmingCharacters(in: .whitespacesAndNewlines)
        self.repeatedFoods = Array(
            repeatedFoods
                .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count > 0 }
                .prefix(8)
        )
        self.patterns = Self.normalizedItems(patterns)
        self.suggestions = Self.normalizedItems(suggestions)
    }

    private static func normalizedItems(_ items: [String]) -> [String] {
        Array(
            items
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .prefix(3)
        )
    }
}

protocol WeeklySummaryProviding {
    func fetchLatestWeeklySummary() async throws -> WeeklyInsightSummary?
}

struct EmptyWeeklySummaryProvider: WeeklySummaryProviding {
    func fetchLatestWeeklySummary() async throws -> WeeklyInsightSummary? { nil }
}

enum AccountDeletionPolicy {
    static let confirmation = "DELETE"

    static func isConfirmed(_ value: String) -> Bool {
        value == confirmation
    }
}

struct DailyNutritionTotal: Equatable, Identifiable, Sendable {
    let localDay: String
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let caloriesKcal: Double
    let entryCount: Int

    var id: String { localDay }
}

struct DailyMacroTargetSnapshot: Equatable, Identifiable, Sendable {
    let targetDay: String
    let target: MacroTarget

    var id: String { targetDay }
}

struct AdherenceHeatmapCell: Equatable, Identifiable {
    let date: Date
    let localDay: String
    let adherence: Double?
    let entryCount: Int

    var id: String { localDay }
}

enum NutrientTrendMetric: String, CaseIterable, Identifiable, Sendable {
    case calories
    case protein
    case carbs
    case fat

    var id: String { rawValue }

    func value(in nutrients: NutrientTrendValues) -> Double {
        switch self {
        case .calories: nutrients.caloriesKcal
        case .protein: nutrients.proteinG
        case .carbs: nutrients.carbsG
        case .fat: nutrients.fatG
        }
    }
}

struct NutrientTrendValues: Equatable, Sendable {
    let caloriesKcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
}

struct NutrientTrendWeek: Equatable, Identifiable, Sendable {
    let startDate: Date
    let endDate: Date
    let startLocalDay: String
    let endLocalDay: String
    let loggedDayCount: Int
    let average: NutrientTrendValues?
    let averageTarget: NutrientTrendValues?

    var id: String { startLocalDay }

    func ratio(for metric: NutrientTrendMetric) -> Double? {
        guard loggedDayCount > 0,
              let average,
              let averageTarget else { return nil }
        let current = metric.value(in: average)
        let goal = metric.value(in: averageTarget)
        guard current.isFinite, goal.isFinite, goal > 0 else { return nil }
        return max(current / goal, 0)
    }
}

enum NutritionProgressPolicy {
    static let heatmapDayCount = 84
    static let trendWeekCount = 12

    static func progress(current: Double, goal: Double) -> Double {
        guard current.isFinite, goal.isFinite, goal > 0 else { return 0 }
        return min(max(current / goal, 0), 1)
    }

    static func adherence(total: DailyNutritionTotal, target: MacroTarget) -> Double? {
        guard total.entryCount > 0 else { return nil }
        let pairs = [
            (total.caloriesKcal, target.caloriesKcal),
            (total.proteinG, target.proteinG),
            (total.carbsG, target.carbsG),
            (total.fatG, target.fatG)
        ].filter { $0.1 > 0 && $0.0.isFinite && $0.1.isFinite }
        guard !pairs.isEmpty else { return nil }

        let scores = pairs.map { current, goal in
            max(0, 1 - abs(current - goal) / goal)
        }
        return scores.reduce(0, +) / Double(scores.count)
    }

    static func effectiveTarget(
        on localDay: String,
        history: [DailyMacroTargetSnapshot],
        fallback: MacroTarget
    ) -> MacroTarget {
        history
            .filter { $0.targetDay <= localDay }
            .max { $0.targetDay < $1.targetDay }?
            .target ?? fallback
    }

    static func heatmapCells(
        totals: [DailyNutritionTotal],
        target: MacroTarget,
        targetHistory: [DailyMacroTargetSnapshot] = [],
        endingOn endDate: Date = Date(),
        timezone: String,
        dayCount: Int = heatmapDayCount
    ) -> [AdherenceHeatmapCell] {
        guard dayCount > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        let end = calendar.startOfDay(for: endDate)
        let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: end) ?? end
        let totalsByDay = totals.reduce(into: [String: DailyNutritionTotal]()) { result, total in
            result[total.localDay] = total
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        return (0..<dayCount).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let localDay = formatter.string(from: date)
            let total = totalsByDay[localDay]
            let effectiveTarget = effectiveTarget(
                on: localDay,
                history: targetHistory,
                fallback: target
            )
            return AdherenceHeatmapCell(
                date: date,
                localDay: localDay,
                adherence: total.flatMap { adherence(total: $0, target: effectiveTarget) },
                entryCount: total?.entryCount ?? 0
            )
        }
    }

    static func nutrientTrendWeeks(
        totals: [DailyNutritionTotal],
        target: MacroTarget,
        targetHistory: [DailyMacroTargetSnapshot] = [],
        endingOn endDate: Date = Date(),
        timezone: String,
        weekCount: Int = trendWeekCount
    ) -> [NutrientTrendWeek] {
        guard weekCount > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        let end = calendar.startOfDay(for: endDate)
        let dayCount = weekCount * 7
        let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: end) ?? end
        let totalsByDay = totals.reduce(into: [String: DailyNutritionTotal]()) { result, total in
            result[total.localDay] = total
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        return (0..<weekCount).compactMap { weekOffset in
            guard let weekStart = calendar.date(
                byAdding: .day,
                value: weekOffset * 7,
                to: start
            ), let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart) else {
                return nil
            }

            var actual = NutrientAccumulator()
            var goals = NutrientAccumulator()
            var loggedDayCount = 0

            for dayOffset in 0..<7 {
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else {
                    continue
                }
                let localDay = formatter.string(from: date)
                guard let total = totalsByDay[localDay],
                      total.entryCount > 0,
                      actual.canInclude(total) else { continue }
                let effectiveTarget = effectiveTarget(
                    on: localDay,
                    history: targetHistory,
                    fallback: target
                )
                guard goals.canInclude(effectiveTarget) else { continue }
                actual.add(total)
                goals.add(effectiveTarget)
                loggedDayCount += 1
            }

            return NutrientTrendWeek(
                startDate: weekStart,
                endDate: weekEnd,
                startLocalDay: formatter.string(from: weekStart),
                endLocalDay: formatter.string(from: weekEnd),
                loggedDayCount: loggedDayCount,
                average: actual.average(dividingBy: loggedDayCount),
                averageTarget: goals.average(dividingBy: loggedDayCount)
            )
        }
    }
}

private struct NutrientAccumulator {
    private var caloriesKcal = 0.0
    private var proteinG = 0.0
    private var carbsG = 0.0
    private var fatG = 0.0

    func canInclude(_ total: DailyNutritionTotal) -> Bool {
        [total.caloriesKcal, total.proteinG, total.carbsG, total.fatG]
            .allSatisfy { $0.isFinite && $0 >= 0 }
    }

    func canInclude(_ target: MacroTarget) -> Bool {
        [target.caloriesKcal, target.proteinG, target.carbsG, target.fatG]
            .allSatisfy { $0.isFinite && $0 > 0 }
    }

    mutating func add(_ total: DailyNutritionTotal) {
        caloriesKcal += total.caloriesKcal
        proteinG += total.proteinG
        carbsG += total.carbsG
        fatG += total.fatG
    }

    mutating func add(_ target: MacroTarget) {
        caloriesKcal += target.caloriesKcal
        proteinG += target.proteinG
        carbsG += target.carbsG
        fatG += target.fatG
    }

    func average(dividingBy count: Int) -> NutrientTrendValues? {
        guard count > 0 else { return nil }
        let divisor = Double(count)
        return NutrientTrendValues(
            caloriesKcal: caloriesKcal / divisor,
            proteinG: proteinG / divisor,
            carbsG: carbsG / divisor,
            fatG: fatG / divisor
        )
    }
}

enum EntryCorrectionPolicy {
    static let maximumCharacters = 4_000
    static let maximumAudioBytes = 8 * 1_024 * 1_024

    static func normalized(_ value: String) -> String {
        String(
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maximumCharacters)
        )
    }

    static func canSubmit(_ value: String, isSubmitting: Bool = false) -> Bool {
        canSubmit(text: value, hasAudio: false, isSubmitting: isSubmitting)
    }

    static func canSubmit(text: String, hasAudio: Bool, isSubmitting: Bool = false) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !isSubmitting
            && (hasAudio || !trimmed.isEmpty)
            && trimmed.count <= maximumCharacters
    }

    static func audioIsWithinUploadLimit(_ byteCount: Int) -> Bool {
        byteCount > 0 && byteCount <= maximumAudioBytes
    }
}

enum EntryDetailPresentation {
    static func offersExpansion(for text: String, collapsedLineCount: Int = 5) -> Bool {
        let explicitLines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return explicitLines > collapsedLineCount || text.count > collapsedLineCount * 42
    }

    static func offersItemExpansion(name: String, amount: String) -> Bool {
        name.count + amount.count > 72 || name.contains("\n") || amount.contains("\n")
    }
}

struct MacroTargetDraft: Equatable {
    var calories: String
    var protein: String
    var carbs: String
    var fat: String

    init(target: MacroTarget) {
        calories = Self.editableText(target.caloriesKcal)
        protein = Self.editableText(target.proteinG)
        carbs = Self.editableText(target.carbsG)
        fat = Self.editableText(target.fatG)
    }

    var validatedTarget: MacroTarget? {
        guard let caloriesValue = Self.value(calories), (500...10_000).contains(caloriesValue),
              let proteinValue = Self.value(protein), (1...500).contains(proteinValue),
              let carbsValue = Self.value(carbs), (1...1_000).contains(carbsValue),
              let fatValue = Self.value(fat), (1...300).contains(fatValue) else { return nil }
        return MacroTarget(
            caloriesKcal: caloriesValue,
            proteinG: proteinValue,
            carbsG: carbsValue,
            fatG: fatValue
        )
    }

    func differs(from target: MacroTarget) -> Bool {
        validatedTarget != target
    }

    private static func value(_ text: String) -> Double? {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value.rounded()
    }

    private static func editableText(_ value: Double) -> String {
        String(Int(value.rounded()))
    }
}
