import SwiftUI

struct NutrientTrendsView: View {
    let totals: [DailyNutritionTotal]
    let target: MacroTarget
    let targetHistory: [DailyMacroTargetSnapshot]
    let timezone: String

    private let chartMaximumRatio = 1.35

    var body: some View {
        // One trend pass per render; the property form recomputed it on every access.
        let weeks = NutritionProgressPolicy.nutrientTrendWeeks(
            totals: totals,
            target: target,
            targetHistory: targetHistory,
            timezone: timezone
        )
        let hasLoggedData = weeks.contains { $0.loggedDayCount > 0 }
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Nutrient trends")
                        .font(.headline)
                        .foregroundStyle(Design.Color.ink)
                    Text("Weekly average on logged days · 12 weeks")
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)
                }
                Spacer(minLength: 12)
                Image(systemName: "chart.bar.xaxis")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Design.Color.accentSecondary)
            }

            if hasLoggedData {
                VStack(spacing: 15) {
                    trendRow(for: .calories, color: Design.Color.accentSecondary, weeks: weeks)
                    trendRow(for: .protein, color: Design.Color.ringProtein, weeks: weeks)
                    trendRow(for: .carbs, color: Design.Color.ringCarb, weeks: weeks)
                    trendRow(for: .fat, color: Design.Color.ringFat, weeks: weeks)
                }

                HStack(spacing: 7) {
                    Text("12 weeks ago")
                    Spacer(minLength: 8)
                    HStack(spacing: 5) {
                        TargetLineSample()
                            .frame(width: 18, height: 5)
                        Text("Target")
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Design.Color.warning.opacity(0.9))
                            .frame(width: 8, height: 8)
                        Text("Over")
                    }
                    Spacer(minLength: 8)
                    Text("Latest")
                }
                .font(.caption2)
                .foregroundStyle(Design.Color.muted)
            } else {
                Text("Log a few meals to see calories and macros move against your targets over time.")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(
            Design.Color.glassFill,
            in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
        )
    }

    private func trendRow(
        for metric: NutrientTrendMetric,
        color: Color,
        weeks: [NutrientTrendWeek]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title(for: metric))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Design.Color.ink)
                Spacer(minLength: 8)
                Text(latestSummary(for: metric, in: weeks))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Design.Color.muted)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            GeometryReader { geometry in
                let targetY = geometry.size.height * (1 - 1 / chartMaximumRatio)
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(weeks) { week in
                            trendBar(
                                ratio: week.ratio(for: metric),
                                color: color,
                                height: geometry.size.height,
                                isLatest: week.id == weeks.last?.id
                            )
                        }
                    }

                    TargetLineSample()
                        .frame(width: geometry.size.width, height: 5)
                        .offset(y: targetY - 2.5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 40)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(for: metric, in: weeks))
    }

    /// A week's bar: solid metric color up to the target line; anything
    /// beyond the target renders as an amber overflow segment above it, so
    /// over- vs under-target weeks read at a glance. The latest week is
    /// full-strength; history sits back slightly.
    private func trendBar(
        ratio: Double?,
        color: Color,
        height: CGFloat,
        isLatest: Bool
    ) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Design.Color.elevated)
            .overlay(alignment: .bottom) {
                if let ratio {
                    let clamped = min(max(ratio, 0), chartMaximumRatio)
                    let underHeight = max(2, height * min(clamped, 1) / chartMaximumRatio)
                    let overHeight = clamped > 1
                        ? height * (clamped - 1) / chartMaximumRatio
                        : 0
                    VStack(spacing: 0) {
                        if overHeight > 0 {
                            UnevenRoundedRectangle(
                                topLeadingRadius: 2.5,
                                topTrailingRadius: 2.5,
                                style: .continuous
                            )
                            .fill(Design.Color.warning.opacity(isLatest ? 0.95 : 0.7))
                            .frame(height: overHeight)
                        }
                        UnevenRoundedRectangle(
                            topLeadingRadius: overHeight > 0 ? 0 : 2.5,
                            bottomLeadingRadius: 2.5,
                            bottomTrailingRadius: 2.5,
                            topTrailingRadius: overHeight > 0 ? 0 : 2.5,
                            style: .continuous
                        )
                        .fill(color.opacity(isLatest ? 1 : 0.66))
                        .frame(height: underHeight)
                    }
                }
            }
            .frame(maxWidth: .infinity)
    }

    private func title(for metric: NutrientTrendMetric) -> String {
        switch metric {
        case .calories: "Calories"
        case .protein: "Protein"
        case .carbs: "Carbs"
        case .fat: "Fat"
        }
    }

    private func latestSummary(
        for metric: NutrientTrendMetric,
        in weeks: [NutrientTrendWeek]
    ) -> String {
        guard let week = weeks.last(where: { $0.ratio(for: metric) != nil }),
              let average = week.average,
              let averageTarget = week.averageTarget,
              let ratio = week.ratio(for: metric) else { return "No data" }
        let value = Int(metric.value(in: average).rounded())
        let goal = Int(metric.value(in: averageTarget).rounded())
        let suffix = metric == .calories ? " kcal" : "g"
        return "\(value) / \(goal)\(suffix) · \(Int((ratio * 100).rounded()))%"
    }

    private func accessibilitySummary(
        for metric: NutrientTrendMetric,
        in weeks: [NutrientTrendWeek]
    ) -> String {
        let name = title(for: metric)
        let summary = latestSummary(for: metric, in: weeks)
        guard summary != "No data" else {
            return "\(name), no logged data in the last 12 weeks"
        }
        return "\(name), latest weekly average \(summary). Bars run from 12 weeks ago through the latest seven days; the dashed line marks the target."
    }
}

private struct TargetLineSample: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: 0, y: geometry.size.height / 2))
                path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height / 2))
            }
            .stroke(
                Design.Color.muted.opacity(0.65),
                style: StrokeStyle(lineWidth: 0.75, dash: [3, 3])
            )
        }
    }
}
