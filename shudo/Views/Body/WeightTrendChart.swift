import Charts
import SwiftUI

/// Raw weigh-ins as dots, the gap-aware EMA as the ember line, the goal as a
/// dashed honey rule, and the on-pace lean-bulk lane shaded from the goal's
/// start. Before there are enough weigh-ins it draws only the self-reported
/// start (hollow) and the lane, so the card is honest about what it knows.
struct WeightTrendChart: View {
    let points: [WeightTrendPoint]
    let goal: BodyGoal?
    let today: String
    let units: String
    var showsTrend = true
    static let maxWindowDays = 84

    private struct Plot: Identifiable {
        let id: String
        let date: Date
        let raw: Double
        let trend: Double
    }

    private struct LanePoint: Identifiable {
        let id: String
        let date: Date
        let low: Double
        let high: Double
    }

    var body: some View {
        let window = windowStart
        let plots = points.compactMap { point -> Plot? in
            guard point.localDay >= window, let date = LocalDayMath.date(point.localDay) else { return nil }
            return Plot(id: point.localDay, date: date, raw: display(point.raw), trend: display(point.trend))
        }
        let lane = lanePoints(from: window)
        let start = startMarker(window: window)
        let target = goal?.targetWeightKG.map(display)
        let domain = yDomain(plots: plots, lane: lane, start: start?.value, target: target)
        let xDomain = (LocalDayMath.date(window) ?? Date())...(LocalDayMath.date(today) ?? Date())

        Chart {
            ForEach(lane) { point in
                AreaMark(
                    x: .value("Day", point.date),
                    yStart: .value("Lane low", point.low),
                    yEnd: .value("Lane high", point.high)
                )
                .foregroundStyle(Design.Color.ember.opacity(0.09))
                .interpolationMethod(.linear)
            }
            if let target, domain.contains(target) {
                RuleMark(y: .value("Goal", target))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    .foregroundStyle(Design.Color.honey.opacity(0.55))
            }
            if let start {
                PointMark(x: .value("Day", start.date), y: .value("Self-reported", start.value))
                    .symbol {
                        Circle()
                            .strokeBorder(Design.Color.honey, lineWidth: 2)
                            .background(Circle().fill(Design.Color.surface1))
                            .frame(width: 11, height: 11)
                    }
                    .annotation(position: .top, alignment: .leading, spacing: 4) {
                        Text("self-reported")
                            .font(Design.Typeface.meta)
                            .foregroundStyle(Design.Color.textTertiary)
                    }
            }
            ForEach(plots) { plot in
                PointMark(x: .value("Day", plot.date), y: .value("Weight", plot.raw))
                    .symbolSize(showsTrend ? 14 : 30)
                    .foregroundStyle(showsTrend ? Design.Color.textTertiary : Design.Color.ember)
            }
            if showsTrend {
                ForEach(plots) { plot in
                    LineMark(x: .value("Day", plot.date), y: .value("Trend", plot.trend), series: .value("Series", "trend"))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                        .foregroundStyle(Design.Color.ember)
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: domain)
        .chartPlotStyle { $0.clipped() }
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated).day(), centered: false)
                    .foregroundStyle(Design.Color.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Design.Color.hairline)
                AxisValueLabel().foregroundStyle(Design.Color.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// Up to 12 weeks back, never before the goal started or the first weigh-in.
    private var windowStart: String {
        let earliest = LocalDayMath.adding(-Self.maxWindowDays, to: today) ?? today
        let first = [goal?.startDay, points.first?.localDay].compactMap { $0 }.min() ?? today
        let start = max(first, earliest)
        // Keep at least two weeks of axis so a fresh goal doesn't render as one column.
        let minimum = LocalDayMath.adding(-14, to: today) ?? today
        return min(start, minimum)
    }

    private func display(_ kilograms: Double) -> Double { BodyUnits.display(kilograms, units: units) }

    private func lanePoints(from window: String) -> [LanePoint] {
        guard let goal, let days = goal.startDay.flatMap({ LocalDayMath.days(from: $0, to: today) }) else { return [] }
        let weeks = max(1, Int((Double(days) / 7).rounded(.up)))
        return TrajectoryPolicy.lane(goal: goal, weeks: weeks).compactMap { point in
            guard let date = LocalDayMath.date(point.day) else { return nil }
            return LanePoint(id: point.day, date: date, low: display(point.low), high: display(point.high))
        }
    }

    private func startMarker(window: String) -> (date: Date, value: Double)? {
        guard let goal, let weight = goal.startWeightKG, let day = goal.startDay,
            day >= window, !points.contains(where: { $0.localDay == day }),
            let date = LocalDayMath.date(day)
        else { return nil }
        return (date, display(weight))
    }

    private func yDomain(plots: [Plot], lane: [LanePoint], start: Double?, target: Double?) -> ClosedRange<Double> {
        var values = plots.flatMap { [$0.raw, $0.trend] }
        values += lane.flatMap { [$0.low, $0.high] }
        if let start { values.append(start) }
        guard var low = values.min(), var high = values.max() else {
            let base = target ?? 70
            return (base - 5)...(base + 1)
        }
        // Keep the goal line on the chart when it's within reach.
        let reach = BodyUnits.isImperial(units) ? 15.0 : 7.0
        if let target, abs(target - high) <= reach || abs(target - low) <= reach {
            low = min(low, target)
            high = max(high, target)
        }
        let pad = BodyUnits.isImperial(units) ? 1.0 : 0.5
        return (low - pad).rounded(.down)...(high + pad).rounded(.up)
    }

    private var accessibilitySummary: String {
        let unit = BodyUnits.label(units)
        guard let last = points.last else { return "No weigh-ins yet" }
        return "\(points.count) weigh-ins. Trend \(BodyUnits.format(display(last.trend))) \(unit)."
    }
}
