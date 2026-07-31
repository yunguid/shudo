import SwiftUI

/// Stored weekly summaries, browsable week by week: chevrons page through
/// history, and each week pairs its narrative with the verifiable nutrient
/// averages behind it (computed locally from the same logged totals the
/// heatmap uses).
struct WeeklyInsightsView: View {
    let summaries: [WeeklyInsightSummary]
    let totals: [DailyNutritionTotal]
    let fallbackTarget: MacroTarget
    let targetHistory: [DailyMacroTargetSnapshot]
    let isLoading: Bool
    let errorMessage: String?
    let onRetry: () -> Void

    @State private var selectedIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        summaries: [WeeklyInsightSummary],
        totals: [DailyNutritionTotal] = [],
        fallbackTarget: MacroTarget = .defaultDaily,
        targetHistory: [DailyMacroTargetSnapshot] = [],
        isLoading: Bool,
        errorMessage: String? = nil,
        onRetry: @escaping () -> Void = {}
    ) {
        self.summaries = summaries
        self.totals = totals
        self.fallbackTarget = fallbackTarget
        self.targetHistory = targetHistory
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.onRetry = onRetry
    }

    private var selectedSummary: WeeklyInsightSummary? {
        guard summaries.indices.contains(selectedIndex) else { return summaries.first }
        return summaries[selectedIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Weekly insights")
                        .font(.headline)
                        .foregroundStyle(Design.Color.ink)
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)
                }
                Spacer(minLength: 8)
                if summaries.count > 1 {
                    weekPager
                } else {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Design.Color.accentSecondary)
                }
            }

            if isLoading {
                VStack(alignment: .leading, spacing: 9) {
                    Capsule().fill(Design.Color.elevated).frame(width: 210, height: 10)
                    Capsule().fill(Design.Color.elevated).frame(height: 8)
                    Capsule().fill(Design.Color.elevated).frame(width: 240, height: 8)
                }
                .shimmering()
                .accessibilityLabel("Loading weekly insights")
            } else if let errorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(Design.Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again", action: onRetry)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Design.Color.accentSecondary)
                        .buttonStyle(.plain)
                }
            } else if let summary = selectedSummary {
                summaryContent(summary)
                    .id(summary.weekStart)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("No weekly summary yet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.ink)
                    Text(
                        "Keep logging meals and the latest patterns and practical next steps can appear here."
                    )
                    .font(.footnote)
                    .foregroundStyle(Design.Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .background(
            Design.Color.glassFill,
            in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
        )
        .onChange(of: summaries.first?.weekStart) { _, _ in
            selectedIndex = 0
        }
    }

    // MARK: - Week paging

    private var weekPager: some View {
        HStack(spacing: 4) {
            pagerButton(
                systemImage: "chevron.left",
                enabled: selectedIndex < summaries.count - 1,
                label: "Earlier week"
            ) {
                selectedIndex = min(selectedIndex + 1, summaries.count - 1)
            }
            Text("\(summaries.count - selectedIndex)/\(summaries.count)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Design.Color.muted)
                .monospacedDigit()
                .frame(minWidth: 30)
                .accessibilityLabel(
                    "Week \(summaries.count - selectedIndex) of \(summaries.count)"
                )
            pagerButton(
                systemImage: "chevron.right",
                enabled: selectedIndex > 0,
                label: "Later week"
            ) {
                selectedIndex = max(selectedIndex - 1, 0)
            }
        }
    }

    private func pagerButton(
        systemImage: String,
        enabled: Bool,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            if reduceMotion {
                action()
            } else {
                withAnimation(.easeOut(duration: 0.16)) { action() }
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(enabled ? Design.Color.ink : Design.Color.subtle)
                .frame(width: 32, height: 32)
                .background(Design.Color.elevated, in: Circle())
                .contentShape(Circle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var subtitleText: String {
        guard let summary = selectedSummary else { return "Latest summary" }
        let period = periodText(summary)
        return selectedIndex == 0 ? "\(period) · latest" : period
    }

    // MARK: - Selected week

    @ViewBuilder
    private func summaryContent(_ summary: WeeklyInsightSummary) -> some View {
        weekNumbers(summary)

        Text(summary.headline.isEmpty ? "Your week at a glance" : summary.headline)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Design.Color.ink)
            .fixedSize(horizontal: false, vertical: true)

        if !summary.narrative.isEmpty {
            Text(summary.narrative)
                .font(.footnote)
                .foregroundStyle(Design.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
        }

        if !summary.repeatedFoods.isEmpty {
            insightGroup(
                title: "Repeated foods",
                items: summary.repeatedFoods.prefix(4).map {
                    "\($0.name) · \($0.count) logged meals"
                },
                systemImage: "repeat"
            )
        }

        if !summary.patterns.isEmpty {
            insightGroup(title: "Patterns", items: summary.patterns, systemImage: "waveform.path.ecg")
        }
        if !summary.suggestions.isEmpty {
            insightGroup(title: "Try next", items: summary.suggestions, systemImage: "arrow.right.circle")
        }

        if let report = summary.micronutrientReport {
            NavigationLink {
                MicronutrientReportView(report: report, period: periodText(summary))
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .foregroundStyle(Design.Color.accentSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Micronutrient report")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Design.Color.ink)
                        Text("Vitamins, minerals, fiber, and omega-3")
                            .font(.caption)
                            .foregroundStyle(Design.Color.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Design.Color.subtle)
                }
                .padding(12)
                .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the detailed weekly nutrient analysis")
        }
    }

    /// The verifiable numbers behind the week's story: average intake vs
    /// target on the days that were actually logged.
    @ViewBuilder
    private func weekNumbers(_ summary: WeeklyInsightSummary) -> some View {
        if let week = NutritionProgressPolicy.weeklyBreakdown(
            for: summary,
            totals: totals,
            fallbackTarget: fallbackTarget,
            targetHistory: targetHistory
        ), week.loggedDayCount > 0, let average = week.average, let target = week.averageTarget {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    numberChip(
                        label: "kcal",
                        value: average.caloriesKcal,
                        goal: target.caloriesKcal,
                        color: Design.Color.accentSecondary
                    )
                    numberChip(
                        label: "P",
                        value: average.proteinG,
                        goal: target.proteinG,
                        color: Design.Color.ringProtein
                    )
                    numberChip(
                        label: "C",
                        value: average.carbsG,
                        goal: target.carbsG,
                        color: Design.Color.ringCarb
                    )
                    numberChip(
                        label: "F",
                        value: average.fatG,
                        goal: target.fatG,
                        color: Design.Color.ringFat
                    )
                }
                Text(
                    "Daily average across \(week.loggedDayCount) logged day\(week.loggedDayCount == 1 ? "" : "s")"
                )
                .font(.caption2)
                .foregroundStyle(Design.Color.subtle)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(breakdownAccessibilityLabel(week: week, average: average, target: target))
        }
    }

    private func numberChip(label: String, value: Double, goal: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(Design.Color.muted)
            }
            Text(chipValueText(value: value, goal: goal))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Design.Color.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            Design.Color.elevated,
            in: RoundedRectangle(cornerRadius: Design.Radius.s, style: .continuous)
        )
    }

    private func chipValueText(value: Double, goal: Double) -> String {
        "\(Int(value.rounded()))/\(Int(goal.rounded()))"
    }

    private func breakdownAccessibilityLabel(
        week: NutrientTrendWeek,
        average: NutrientTrendValues,
        target: NutrientTrendValues
    ) -> String {
        "Daily averages across \(week.loggedDayCount) logged days: "
            + "\(Int(average.caloriesKcal.rounded())) of \(Int(target.caloriesKcal.rounded())) kilocalories, "
            + "protein \(Int(average.proteinG.rounded())) of \(Int(target.proteinG.rounded())) grams, "
            + "carbs \(Int(average.carbsG.rounded())) of \(Int(target.carbsG.rounded())) grams, "
            + "fat \(Int(average.fatG.rounded())) of \(Int(target.fatG.rounded())) grams"
    }

    private func insightGroup(title: String, items: [String], systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Design.Color.muted)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(Design.Color.accentSecondary)
                        .frame(width: 4, height: 4)
                        .padding(.top, 7)
                    Text(item)
                        .font(.footnote)
                        .foregroundStyle(Design.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static let periodFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private func periodText(_ summary: WeeklyInsightSummary) -> String {
        let formatter = Self.periodFormatter
        return "\(formatter.string(from: summary.weekStart))–\(formatter.string(from: summary.weekEnd))"
    }
}
