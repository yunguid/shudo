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
        // POSIX locale keeps the day keys ASCII so they match server-side
        // local_day values even when the user's locale uses non-Latin digits.
        formatter.locale = Locale(identifier: "en_US_POSIX")
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

/// Presents web-research provenance from the fields the server already
/// writes. Copy contract with supabase/functions/_shared/entry_processor.ts
/// (RESEARCH_STATUS_MESSAGES) and _shared/meal_research.ts (disclosure
/// strings): both sides pin these exact strings in tests, and unknown text
/// degrades to today's plain rendering rather than breaking.
enum EntryResearchPresentation {
    /// Server-authored processing phases that mean live web research. An
    /// unrecognized message simply renders without the research glyph.
    static let researchingStatusMessages: Set<String> = [
        "Searching the web",
        "Checking nutrition sources",
        "Calculating from sources",
    ]

    static func isResearching(statusMessage: String?) -> Bool {
        guard let statusMessage else { return false }
        return researchingStatusMessages.contains(
            statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static let sourcesPrefix = "Online sources: "
    static let verifiedLinklessDisclosure = "Checked against online sources."
    static let unavailableDisclosurePrefix = "Online lookup was unavailable"
    static let emptyDisclosurePrefix = "No authoritative online nutrition source"

    struct Source: Equatable, Identifiable {
        let host: String
        let url: URL

        var id: URL { url }
    }

    enum Provenance: Equatable {
        case none
        /// Research succeeded; sources may be empty when links were too long
        /// to attach safely.
        case verified(sources: [Source])
        /// The web was searched but no authoritative source was found.
        case unverified
        /// Online lookup failed and the meal fell back to a plain estimate.
        case unavailable
    }

    struct NotesBreakdown: Equatable {
        let provenance: Provenance
        /// Model prose with the research lines removed; nil when nothing
        /// remains to show.
        let displayNotes: String?
        /// True when the server escaped the prose for markdown (verified
        /// meals), so display must render inline markdown to undo escapes.
        let rendersInlineMarkdown: Bool
    }

    static func breakdown(notes: String?) -> NotesBreakdown {
        let trimmed = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return NotesBreakdown(
                provenance: .none,
                displayNotes: nil,
                rendersInlineMarkdown: false
            )
        }

        var paragraphs = trimmed.components(separatedBy: "\n\n")
        let last = paragraphs[paragraphs.count - 1]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        func remainingProse() -> String? {
            paragraphs.removeLast()
            let prose = paragraphs
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return prose.isEmpty ? nil : prose
        }

        if last.hasPrefix(sourcesPrefix) {
            let sources = parseSources(
                String(last.dropFirst(sourcesPrefix.count))
            )
            return NotesBreakdown(
                provenance: .verified(sources: sources),
                displayNotes: remainingProse(),
                rendersInlineMarkdown: true
            )
        }
        if last == verifiedLinklessDisclosure {
            return NotesBreakdown(
                provenance: .verified(sources: []),
                displayNotes: remainingProse(),
                rendersInlineMarkdown: true
            )
        }
        if last.hasPrefix(emptyDisclosurePrefix) {
            return NotesBreakdown(
                provenance: .unverified,
                displayNotes: remainingProse(),
                rendersInlineMarkdown: false
            )
        }
        if last.hasPrefix(unavailableDisclosurePrefix) {
            return NotesBreakdown(
                provenance: .unavailable,
                displayNotes: remainingProse(),
                rendersInlineMarkdown: false
            )
        }
        return NotesBreakdown(
            provenance: .none,
            displayNotes: trimmed,
            rendersInlineMarkdown: false
        )
    }

    static func hasVerifiedResearch(notes: String?) -> Bool {
        if case .verified = breakdown(notes: notes).provenance { return true }
        return false
    }

    /// Collapses same-host citations for display: three deep links into one
    /// restaurant site read as noise, so each host keeps its first link only.
    static func displaySources(_ sources: [Source]) -> [Source] {
        var seenHosts = Set<String>()
        return sources.filter { seenHosts.insert($0.host).inserted }
    }

    /// Parses "[host](url), [host](url)." — the server guarantees links are
    /// never truncated mid-markdown, but a malformed tail is dropped rather
    /// than rendered.
    private static func parseSources(_ line: String) -> [Source] {
        var sources: [Source] = []
        var seen = Set<URL>()
        var remainder = Substring(line)

        while let open = remainder.firstIndex(of: "[") {
            guard let close = remainder[open...].firstIndex(of: "]"),
                  remainder.index(after: close) < remainder.endIndex,
                  remainder[remainder.index(after: close)] == "(",
                  let terminator = remainder[close...].firstIndex(of: ")")
            else { break }

            let host = remainder[remainder.index(after: open)..<close]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let target = remainder[
                remainder.index(close, offsetBy: 2)..<terminator
            ].trimmingCharacters(in: .whitespacesAndNewlines)

            if !host.isEmpty,
               let url = URL(string: target),
               url.scheme == "https" || url.scheme == "http",
               !seen.contains(url) {
                seen.insert(url)
                sources.append(Source(host: host, url: url))
            }
            remainder = remainder[remainder.index(after: terminator)...]
        }
        return sources
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
