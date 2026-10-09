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
    /// The ledger shows the last few weeks; older ones wait behind a fold.
    @State private var showsEarlier = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let recentCount = 4
    private static let maxCount = 12

    var body: some View {
        let weeks = Array(summaries.prefix(Self.maxCount))
        let shown = showsEarlier ? weeks : Array(weeks.prefix(Self.recentCount))
        VStack(alignment: .leading, spacing: 0) {
            Text("Weekly recaps").eyebrowStyle()
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, Design.Space.s)
            ForEach(Array(shown.enumerated()), id: \.element.weekStart) { index, summary in
                VStack(spacing: 0) {
                    if index > 0 { HairlineRule() }
                    Button {
                        selected = WeeklyRecapSelection(summary: summary)
                    } label: {
                        row(summary)
                    }
                    .buttonStyle(LedgerRowStyle())
                }
                .transition(.ink(reduceMotion: reduceMotion))
            }
            if weeks.count > Self.recentCount {
                HairlineRule()
                Button {
                    withAnimation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion)) {
                        showsEarlier.toggle()
                    }
                } label: {
                    Text(showsEarlier ? "Fewer weeks" : "Earlier weeks")
                        .font(Design.Typeface.text(.footnote))
                        .foregroundStyle(Design.Color.textSecondary)
                        .padding(.vertical, Design.Space.m + 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(LedgerRowStyle())
                .accessibilityHint(showsEarlier ? "Shows only the last four weeks" : "Shows the older weekly recaps")
            }
        }
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
                .font(Design.Typeface.numeral(.footnote, weight: .regular))
                .foregroundStyle(Design.Color.textTertiary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(minWidth: dateColumnWidth, alignment: .leading)
                .fixedSize()
            Text(summary.headline)
                .font(Design.Typeface.text(.subheadline))
                .foregroundStyle(Design.Color.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Design.Space.m + 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the full recap")
    }

    @ScaledMetric(relativeTo: .footnote) private var dateColumnWidth: CGFloat = 92
}

/// A ledger row: no chrome, just a soft dim while pressed.
private struct LedgerRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(Design.Motion.snap, value: configuration.isPressed)
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
            VStack(alignment: .leading, spacing: Design.Space.xxl) {
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    Text(WeeklyRecapFormat.range(summary)).eyebrowStyle()
                    Text(summary.headline)
                        .font(Design.Typeface.display(.title2))
                        .foregroundStyle(Design.Color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                numbers
                if !summary.narrative.isEmpty || !summary.patterns.isEmpty {
                    VStack(alignment: .leading, spacing: Design.Space.m) {
                        if !summary.narrative.isEmpty {
                            Text(summary.narrative)
                                .foregroundStyle(Design.Color.textSecondary)
                        }
                        ForEach(summary.patterns, id: \.self) { pattern in
                            Text(pattern).foregroundStyle(Design.Color.textSecondary)
                        }
                    }
                    .font(Design.Typeface.text(.body))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if !summary.suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: Design.Space.m) {
                        Text("Next week").eyebrowStyle()
                        ForEach(summary.suggestions, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: Design.Space.m) {
                                Capsule()
                                    .fill(Design.Color.pernambuco)
                                    .frame(width: 10, height: 1.5)
                                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                                    .accessibilityHidden(true)
                                Text(item)
                                    .font(Design.Typeface.text(.subheadline))
                                    .foregroundStyle(Design.Color.textPrimary)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                watchList
            }
            .padding(.horizontal, Design.Space.xl)
            .padding(.top, Design.Space.xxl)
            .padding(.bottom, Design.Space.xl)
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
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            Text(value)
                .font(Design.Typeface.figure(.title))
                .foregroundStyle(Design.Color.textPrimary)
                .monospacedDigit()
            Text("\(unit) a day · of \(target)")
                .font(Design.Typeface.text(.caption))
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
                            .font(Design.Typeface.text(.subheadline))
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
