import SwiftUI

/// "Fuel": twelve weeks of daily adherence as a weekday-aligned calendar
/// grid of small pads in the wood ramp (bare walnut → heartwood →
/// Pernambuco → oak), drawn straight on the page with no card: columns are real
/// weeks, rows are weekdays, with month and weekday anchors so any pad can be
/// traced to an actual day. Five discrete levels (nothing logged + four
/// adherence buckets), and tapping a day shows its logged numbers against
/// that day's target — the grid is verifiable, not just decorative.
///
/// With a `phase`, days are scored phase-aware (`AdherencePolicy`: calories
/// inside the phase's band and protein ≥ 90%), so a bulk never reads eating
/// big as "off target". Without one, the 1.x four-macro score is used.
struct AdherenceHeatmapView: View {
    let totals: [DailyNutritionTotal]
    let target: MacroTarget
    let targetHistory: [DailyMacroTargetSnapshot]
    let timezone: String
    var phase: GoalPhase? = nil
    var title = "Fuel"

    @State private var selectedLocalDay: String?
    @State private var gridWidth: CGFloat = 0

    private static let cellSpacing: CGFloat = 3
    private static let weekdayGutterWidth: CGFloat = 12
    /// How much of its cell a pad fills.
    private static let padScale: CGFloat = 0.66

    var body: some View {
        // One cells pass and one DateFormatter per render.
        let cells = NutritionProgressPolicy.heatmapCells(
            totals: totals,
            target: target,
            targetHistory: targetHistory,
            timezone: timezone
        )
        let calendar = makeCalendar()
        let leadingBlanks = cells.first.map {
            NutritionProgressPolicy.weekdayRow(for: $0.date, calendar: calendar)
        } ?? 0
        let columnCount = max(1, (leadingBlanks + cells.count + 6) / 7)
        let labelFormatter = makeLabelFormatter()
        let selected = selectedCell(in: cells)

        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).eyebrowStyle()
                    Spacer(minLength: 12)
                    summary(cells: cells)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).eyebrowStyle()
                    summary(cells: cells)
                }
            }

            HStack(alignment: .top, spacing: 6) {
                weekdayGutter(calendar: calendar, columnCount: columnCount)
                VStack(alignment: .leading, spacing: 5) {
                    monthLabels(
                        cells: cells,
                        leadingBlanks: leadingBlanks,
                        columnCount: columnCount,
                        calendar: calendar
                    )
                    grid(
                        cells: cells,
                        leadingBlanks: leadingBlanks,
                        columnCount: columnCount,
                        formatter: labelFormatter
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    // Captures the width available to the grid so cell size,
                    // month labels, and the weekday gutter share one metric.
                    GeometryReader { proxy in
                        Color.clear.onAppear { gridWidth = proxy.size.width }
                            .onChange(of: proxy.size.width) { _, updated in
                                gridWidth = updated
                            }
                    }
                }
            }

            dayReadout(selected, formatter: labelFormatter, todayLocalDay: cells.last?.localDay)
                .padding(.top, Design.Space.xs)
        }
        .onAppear {
            if selectedLocalDay == nil {
                selectedLocalDay = cells.last?.localDay
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func summary(cells: [AdherenceHeatmapCell]) -> some View {
        if let line = summaryLine(cells: cells) {
            Text(line)
                .font(.footnote)
                .foregroundStyle(Design.Color.textSecondary)
                .monospacedDigit()
        }
    }

    /// The one judgment worth a line: how the last week went. The pads carry
    /// the rest (brighter = closer to plan; dark = nothing logged).
    private func summaryLine(cells: [AdherenceHeatmapCell]) -> String? {
        if let phase {
            let onPlan = cells.suffix(7).filter {
                AdherencePolicy.level(
                    AdherencePolicy.day(total: $0.total, target: $0.effectiveTarget, phase: phase)) == 4
            }.count
            return "\(onPlan) of last 7 on plan"
        }
        let scores = cells.compactMap(\.adherence)
        guard !scores.isEmpty else { return nil }
        let average = Int((scores.reduce(0, +) / Double(scores.count) * 100).rounded())
        return "avg \(average)%"
    }

    // MARK: - Calendar block

    private func weekdayGutter(calendar: Calendar, columnCount: Int) -> some View {
        let metrics = metrics(columnCount: columnCount)
        let symbols = calendar.veryShortWeekdaySymbols
        let firstIndex = calendar.firstWeekday - 1
        return VStack(alignment: .leading, spacing: Self.cellSpacing) {
            ForEach(0..<7, id: \.self) { row in
                // Odd rows only: with a Sunday-first week that reads M/W/F —
                // unambiguous single letters, unlike the even rows' S/T/T/S.
                Text(row.isMultiple(of: 2) ? "" : symbols[(firstIndex + row) % 7])
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Design.Color.textTertiary)
                    .frame(
                        width: Self.weekdayGutterWidth,
                        height: metrics.cellSize,
                        alignment: .leading
                    )
            }
        }
        .padding(.top, 15)
        .accessibilityHidden(true)
    }

    private func monthLabels(
        cells: [AdherenceHeatmapCell],
        leadingBlanks: Int,
        columnCount: Int,
        calendar: Calendar
    ) -> some View {
        let metrics = metrics(columnCount: columnCount)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM"
        var labels: [(column: Int, text: String)] = []
        var previousMonth = -1
        for column in 0..<columnCount {
            let firstIndex = max(0, column * 7 - leadingBlanks)
            guard firstIndex < cells.count else { continue }
            let month = calendar.component(.month, from: cells[firstIndex].date)
            if month != previousMonth {
                // Skip a label on the first column when the month turns over
                // almost immediately — it would collide with the next label.
                let isCrampedLeadIn = column == 0 && columnCount > 1 && {
                    let nextFirst = min(cells.count - 1, 7 - leadingBlanks)
                    return calendar.component(.month, from: cells[nextFirst].date) != month
                }()
                if !isCrampedLeadIn {
                    labels.append((column, formatter.string(from: cells[firstIndex].date)))
                }
                previousMonth = month
            }
        }
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(height: 10)
            ForEach(labels, id: \.column) { label in
                Text(label.text)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Design.Color.textTertiary)
                    .fixedSize()
                    .offset(x: CGFloat(label.column) * (metrics.cellSize + Self.cellSpacing))
            }
        }
        .accessibilityHidden(true)
    }

    private func grid(
        cells: [AdherenceHeatmapCell],
        leadingBlanks: Int,
        columnCount: Int,
        formatter: DateFormatter
    ) -> some View {
        let metrics = metrics(columnCount: columnCount)
        let todayLocalDay = cells.last?.localDay
        return HStack(alignment: .top, spacing: Self.cellSpacing) {
            ForEach(0..<columnCount, id: \.self) { column in
                VStack(spacing: Self.cellSpacing) {
                    ForEach(0..<7, id: \.self) { row in
                        let index = column * 7 + row - leadingBlanks
                        if index >= 0, index < cells.count {
                            cellView(
                                cells[index],
                                size: metrics.cellSize,
                                isToday: cells[index].localDay == todayLocalDay,
                                formatter: formatter
                            )
                        } else {
                            Color.clear
                                .frame(width: metrics.cellSize, height: metrics.cellSize)
                        }
                    }
                }
            }
        }
    }

    private func cellView(
        _ cell: AdherenceHeatmapCell,
        size: CGFloat,
        isToday: Bool,
        formatter: DateFormatter
    ) -> some View {
        let level = level(for: cell, isToday: isToday)
        let isSelected = cell.localDay == selectedLocalDay
        // Pads sit a little inside their cell so the grid breathes; the
        // selection and today rings sit in that air instead of on the pad.
        let pad = (size * Self.padScale).rounded()
        let radius = max(2, pad * 0.26)
        let ringRadius = radius + (size - pad) / 2
        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Self.fillColor(level: level))
                .frame(width: pad, height: pad)
            if isSelected {
                RoundedRectangle(cornerRadius: ringRadius, style: .continuous)
                    .strokeBorder(Design.Color.textPrimary.opacity(0.85), lineWidth: 1)
            } else if isToday {
                RoundedRectangle(cornerRadius: ringRadius, style: .continuous)
                    .strokeBorder(Design.Color.pernambuco, lineWidth: 1)
            }
        }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Design.Motion.snap) { selectedLocalDay = cell.localDay }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(cell, formatter: formatter))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows this day’s totals below the grid")
    }

    // MARK: - Day readout

    @ViewBuilder
    private func dayReadout(_ cell: AdherenceHeatmapCell?, formatter: DateFormatter, todayLocalDay: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let cell {
                Text(formatter.string(from: cell.date))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Design.Color.textPrimary)
                if let total = cell.total, total.entryCount > 0 {
                    Text(verdict(for: cell, isToday: cell.localDay == todayLocalDay))
                        .font(.caption)
                        .foregroundStyle(Design.Color.oak)
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    Text(readoutNumbers(total: total, target: cell.effectiveTarget))
                        .font(Design.Typeface.numeral(.caption2, weight: .regular))
                        .foregroundStyle(Design.Color.textTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                } else {
                    Text("Nothing logged")
                        .font(.caption)
                        .foregroundStyle(Design.Color.textSecondary)
                    Spacer(minLength: 4)
                }
            } else {
                Text("Tap a day to check its numbers")
                    .font(.caption)
                    .foregroundStyle(Design.Color.textSecondary)
                Spacer(minLength: 4)
            }
        }
        .frame(minHeight: 16)
        .accessibilityElement(children: .combine)
    }

    private func verdict(for cell: AdherenceHeatmapCell, isToday: Bool = false) -> String {
        guard let phase else {
            return cell.adherence.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
        }
        guard let day = AdherencePolicy.day(
            total: cell.total, target: cell.effectiveTarget, phase: phase, isToday: isToday)
        else { return "" }
        // Today isn't over: no verdict until it's already a hit.
        if day.isPending { return day.proteinHit ? "So far · protein hit" : "So far" }
        let calories = switch day.calories {
        case .under: "Under"
        case .onPlan: "On plan"
        case .over: "Over"
        }
        return day.proteinHit ? "\(calories) · protein hit" : calories
    }

    private func readoutNumbers(total: DailyNutritionTotal, target: MacroTarget) -> String {
        func n(_ value: Double) -> String { Int(value.rounded()).formatted() }
        let kcal = "\(n(total.caloriesKcal))/\(n(target.caloriesKcal)) kcal"
        let protein = "P \(n(total.proteinG))/\(n(target.proteinG))"
        guard phase == nil else { return "\(kcal) · \(protein)" }
        let carbs = "C \(n(total.carbsG))/\(n(target.carbsG))"
        let fat = "F \(n(total.fatG))/\(n(target.fatG))"
        return "\(kcal) · \(protein) · \(carbs) · \(fat)"
    }

    private func selectedCell(in cells: [AdherenceHeatmapCell]) -> AdherenceHeatmapCell? {
        guard let selectedLocalDay else { return cells.last }
        return cells.first { $0.localDay == selectedLocalDay } ?? cells.last
    }

    // MARK: - Shared metrics

    private func metrics(columnCount: Int) -> (cellSize: CGFloat, spacing: CGFloat) {
        let columns = CGFloat(max(columnCount, 1))
        let available = gridWidth > 0 ? gridWidth : 300
        let fitted = (available - Self.cellSpacing * (columns - 1)) / columns
        return (max(10, min(30, fitted)), Self.cellSpacing)
    }

    /// Five discrete pads from the icon's ramp: one for "nothing logged",
    /// four adherence buckets from deep amber up to honey.
    static func fillColor(level: Int) -> Color {
        let ramp = Design.Color.heatmapRamp
        return ramp[min(max(level, 0), ramp.count - 1)]
    }

    private func level(for cell: AdherenceHeatmapCell, isToday: Bool) -> Int {
        guard let phase else { return NutritionProgressPolicy.adherenceLevel(cell.adherence) }
        return AdherencePolicy.level(
            AdherencePolicy.day(total: cell.total, target: cell.effectiveTarget, phase: phase, isToday: isToday))
    }

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        return calendar
    }

    private func makeLabelFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        formatter.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        return formatter
    }

    private func accessibilityLabel(_ cell: AdherenceHeatmapCell, formatter: DateFormatter) -> String {
        guard let total = cell.total, total.entryCount > 0 else {
            return "\(formatter.string(from: cell.date)), no completed meals"
        }
        return "\(formatter.string(from: cell.date)), \(verdict(for: cell)), \(Int(total.caloriesKcal.rounded())) of \(Int(cell.effectiveTarget.caloriesKcal.rounded())) kilocalories"
    }
}
