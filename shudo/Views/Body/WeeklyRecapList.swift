import SwiftUI

/// The weekly recap archive: stored `weekly_summaries`, newest first, one
/// row per week; a row opens the full recap. The only place a stored week
/// renders (Body tab and the This week screen both use it).
struct WeeklyRecapList: View {
    let summaries: [WeeklyInsightSummary]
    var totals: [DailyNutritionTotal] = []
    var target: MacroTarget = .defaultDaily
    var targetHistory: [DailyMacroTargetSnapshot] = []
    /// Preview/deep-link hook: opens the newest recap when it turns true.
    var presentsLatest = false

    @State private var selected: WeeklyRecapSelection?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Weekly recaps").eyebrowStyle()
                .padding(.bottom, 6)
            ForEach(Array(summaries.prefix(12).enumerated()), id: \.offset) { index, summary in
                if index > 0 { HairlineRule() }
                Button {
                    selected = WeeklyRecapSelection(summary: summary)
                } label: {
                    row(summary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .cardSurface(radius: Design.Radius.cardLarge)
        .task(id: presentsLatest) {
            if presentsLatest, let latest = summaries.first {
                selected = WeeklyRecapSelection(summary: latest)
            }
        }
        .sheet(item: $selected) { selection in
            WeeklyRecapDetail(
                summary: selection.summary,
                week: NutritionProgressPolicy.weeklyBreakdown(
                    for: selection.summary,
                    totals: totals,
                    fallbackTarget: target,
                    targetHistory: targetHistory)
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(Design.Radius.sheet)
        }
    }

    private func row(_ summary: WeeklyInsightSummary) -> some View {
        // Accessibility sizes put the date above the headline so the
        // headline keeps the full width.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            Text(WeeklyRecapFormat.range(summary))
                .font(Design.Typeface.numeral(.caption, weight: .bold))
                .foregroundStyle(Design.Color.ember)
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: 76, alignment: .leading)
                .fixedSize()
            Text(summary.headline)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Design.Color.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the full recap")
    }
}

struct WeeklyRecapSelection: Identifiable {
    let summary: WeeklyInsightSummary
    var id: Date { summary.weekStart }
}

enum WeeklyRecapFormat {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Summary dates are local days parsed at UTC midnight.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let dayOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d"
        return formatter
    }()

    /// "Sep 23–29", or "Sep 30–Oct 6" across a month boundary.
    static func range(_ summary: WeeklyInsightSummary) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let sameMonth = calendar.isDate(summary.weekStart, equalTo: summary.weekEnd, toGranularity: .month)
        let end = sameMonth ? dayOnly.string(from: summary.weekEnd) : formatter.string(from: summary.weekEnd)
        return "\(formatter.string(from: summary.weekStart))–\(end)"
    }
}

/// One stored week: the coach's headline and story, the two numbers behind
/// it (daily averages on logged days), what to change next week, and any
/// nutrient worth watching. Machinery (evidence, confidence, caveats,
/// repeated foods) stays server-side.
struct WeeklyRecapDetail: View {
    let summary: WeeklyInsightSummary
    var week: NutrientTrendWeek?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(WeeklyRecapFormat.range(summary)).eyebrowStyle(Design.Color.ember)
                    Text(summary.headline)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Design.Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                numbers
                if !summary.narrative.isEmpty || !summary.patterns.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        if !summary.narrative.isEmpty {
                            Text(summary.narrative)
                                .foregroundStyle(Design.Color.textSecondary)
                        }
                        ForEach(summary.patterns, id: \.self) { pattern in
                            Text(pattern).foregroundStyle(Design.Color.textSecondary)
                        }
                    }
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !summary.suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Next week").eyebrowStyle()
                        ForEach(summary.suggestions, id: \.self) { item in
                            Label {
                                Text(item).foregroundStyle(Design.Color.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "arrow.right").foregroundStyle(Design.Color.ember)
                            }
                            .font(.subheadline)
                        }
                    }
                }
                watchList
            }
            .padding(20)
        }
        .background(Design.Color.surface1.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    /// Calories and protein: the two numbers a bulk runs on.
    @ViewBuilder
    private var numbers: some View {
        if let week, week.loggedDayCount > 0, let average = week.average, let target = week.averageTarget {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                stat(Int(average.caloriesKcal.rounded()).formatted(), unit: "kcal", of: Int(target.caloriesKcal.rounded()).formatted())
                stat("\(Int(average.proteinG.rounded()))", unit: "g protein", of: "\(Int(target.proteinG.rounded()))")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Daily average on \(week.loggedDayCount) logged days: \(Int(average.caloriesKcal.rounded())) of \(Int(target.caloriesKcal.rounded())) kilocalories, \(Int(average.proteinG.rounded())) of \(Int(target.proteinG.rounded())) grams of protein"
            )
        }
    }

    private func stat(_ value: String, unit: String, of target: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Design.Typeface.numeral(.title2, weight: .bold))
                .foregroundStyle(Design.Color.textPrimary)
                .monospacedDigit()
            Text("\(unit) / day · of \(target)")
                .font(Design.Typeface.meta)
                .foregroundStyle(Design.Color.textTertiary)
                .monospacedDigit()
        }
    }

    /// Only nutrients that are off (likely low, or over a limit), worst first.
    @ViewBuilder
    private var watchList: some View {
        let flagged = (summary.micronutrientReport?.nutrients ?? [])
            .filter { $0.status == "low" || $0.status == "high" }
            .sorted { abs($0.percentReference - 100) > abs($1.percentReference - 100) }
            .prefix(5)
        if !flagged.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Watch").eyebrowStyle()
                ForEach(Array(flagged)) { nutrient in
                    HStack(alignment: .firstTextBaseline) {
                        Text(nutrient.name)
                            .font(.subheadline)
                            .foregroundStyle(Design.Color.textPrimary)
                        Spacer(minLength: 8)
                        Text(nutrient.status == "high" ? "over · \(nutrient.percentReference)%" : "low · \(nutrient.percentReference)%")
                            .font(Design.Typeface.numeral(.footnote, weight: .semibold))
                            .foregroundStyle(nutrient.status == "high" ? Design.Color.danger : Design.Color.warning)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
