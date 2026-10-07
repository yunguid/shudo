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
            guard point.localDay >= window, let date = Self.chartDate(point.localDay) else { return nil }
            return Plot(id: point.localDay, date: date, raw: display(point.raw), trend: display(point.trend))
        }
        let lane = lanePoints(from: window)
        let start = startMarker(window: window)
        let target = goal?.targetWeightKG.map(display)
        let domain = yDomain(plots: plots, lane: lane, start: start?.value, target: target)
        // A little air on both ends so edge markers (the self-reported start,
        // today's dot) and their labels are never cut in half.
        let xLower = LocalDayMath.adding(-2, to: window).flatMap(Self.chartDate) ?? Date()
        let xUpper = LocalDayMath.adding(1, to: today).flatMap(Self.chartDate) ?? Date()
        let xDomain = xLower...max(xUpper, xLower)

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
        .chartXAxis {
            AxisMarks(values: weeklyTicks(from: xLower)) { _ in
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
    var windowStart: String {
        let earliest = LocalDayMath.adding(-Self.maxWindowDays, to: today) ?? today
        let first = [goal?.startDay, points.first?.localDay].compactMap { $0 }.min() ?? today
        let start = max(first, earliest)
        // Keep at least two weeks of axis so a fresh goal doesn't render as one column.
        let minimum = LocalDayMath.adding(-14, to: today) ?? today
        return min(start, minimum)
    }

    private func display(_ kilograms: Double) -> Double { BodyUnits.display(kilograms, units: units) }

    /// Charts formats axis dates in the device zone, so plot each local day
    /// at the device's local midnight (UTC midnight would label as the
    /// previous day anywhere west of Greenwich).
    static func chartDate(_ localDay: String) -> Date? {
        let parts = localDay.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, LocalDayMath.date(localDay) != nil else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Weekly ticks counted back from a week before today, so the last
    /// label always has room before the trailing axis.
    private func weeklyTicks(from lower: Date) -> [Date] {
        let floor = lower.addingTimeInterval(2 * 86_400)
        return (1...13).compactMap { week in
            LocalDayMath.adding(-7 * week, to: today).flatMap(Self.chartDate)
        }
        .filter { $0 >= floor }
        .reversed()
    }

    /// Weekly lane samples from the goal's start, ending exactly at today
    /// (interpolated) so nothing draws past the plot.
    private func lanePoints(from window: String) -> [LanePoint] {
        guard let goal, let startDay = goal.startDay,
            let days = LocalDayMath.days(from: startDay, to: today), days > 0
        else { return [] }
        let weeks = Int((Double(days) / 7).rounded(.up))
        let lane = TrajectoryPolicy.lane(goal: goal, weeks: weeks)
        var result: [LanePoint] = lane.compactMap { point in
            guard point.day <= today, let date = Self.chartDate(point.day) else { return nil }
            return LanePoint(id: point.day, date: date, low: display(point.low), high: display(point.high))
        }
        if result.last?.id != today, let first = lane.first, let last = lane.last,
            let span = LocalDayMath.days(from: first.day, to: last.day), span > 0,
            let date = Self.chartDate(today)
        {
            let t = Double(days) / Double(span)
            result.append(LanePoint(
                id: today, date: date,
                low: display(first.low + (last.low - first.low) * t),
                high: display(first.high + (last.high - first.high) * t)))
        }
        return result
    }

    private func startMarker(window: String) -> (date: Date, value: Double)? {
        guard let goal, let weight = goal.startWeightKG, let day = goal.startDay,
            day >= window, !points.contains(where: { $0.localDay == day }),
            let date = Self.chartDate(day)
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
