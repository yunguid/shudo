import SwiftUI

/// Twelve weeks of daily adherence as a weekday-aligned calendar grid:
/// columns are real weeks, rows are weekdays, with month and weekday
/// anchors so any square can be traced to an actual day. Colors are five
/// discrete levels (nothing logged + four adherence buckets), and tapping
/// a day shows its logged numbers against that day's target — the grid is
/// verifiable, not just decorative.
struct AdherenceHeatmapView: View {
    let totals: [DailyNutritionTotal]
    let target: MacroTarget
    let targetHistory: [DailyMacroTargetSnapshot]
    let timezone: String

    @State private var selectedLocalDay: String?
    @State private var gridWidth: CGFloat = 0

    private static let cellSpacing: CGFloat = 3
    private static let weekdayGutterWidth: CGFloat = 16

    var body: some View {
        // One cells pass and one DateFormatter per render; both were previously
        // rebuilt per property access and per cell label.
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

        VStack(alignment: .leading, spacing: 13) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) {
                    title(cells: cells)
                    Spacer(minLength: 12)
                    legend
                }
                VStack(alignment: .leading, spacing: 6) {
                    title(cells: cells)
                    legend
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

            dayReadout(selected, formatter: labelFormatter)
        }
        .padding(18)
        .background(
            Design.Color.glassFill,
            in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
        )
        .onAppear {
            if selectedLocalDay == nil {
                selectedLocalDay = cells.last?.localDay
            }
        }
    }

    // MARK: - Header

    private func title(cells: [AdherenceHeatmapCell]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Adherence")
                .font(.headline)
                .foregroundStyle(Design.Color.ink)
            Text(summaryLine(cells: cells))
                .font(.caption)
                .foregroundStyle(Design.Color.muted)
        }
    }

    private func summaryLine(cells: [AdherenceHeatmapCell]) -> String {
        let scores = cells.compactMap(\.adherence)
        guard !scores.isEmpty else { return "Last 12 weeks" }
        let average = Int((scores.reduce(0, +) / Double(scores.count) * 100).rounded())
        return "Last 12 weeks · \(scores.count) logged days · avg \(average)%"
    }

    private var legend: some View {
        HStack(spacing: 4) {
            legendChip(level: 0)
            Text("None")
                .padding(.trailing, 5)
            Text("Off")
            ForEach(1...4, id: \.self) { legendChip(level: $0) }
            Text("On target")
        }
        .font(.caption2)
        .foregroundStyle(Design.Color.muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Legend: gray squares have no logged meals; green squares darken to bright as the day lands closer to its targets"
        )
    }

    private func legendChip(level: Int) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Self.fillColor(level: level))
            .frame(width: 10, height: 10)
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
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Design.Color.muted)
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
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Design.Color.muted)
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
        let level = NutritionProgressPolicy.adherenceLevel(cell.adherence)
        let isSelected = cell.localDay == selectedLocalDay
        let radius = max(2.5, size * 0.28)
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Self.fillColor(level: level))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Design.Color.ink, lineWidth: 1.5)
                } else if isToday {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Design.Color.accentPrimary, lineWidth: 1.2)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedLocalDay = cell.localDay
                UISelectionFeedbackGenerator().selectionChanged()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(cell, formatter: formatter))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows this day’s totals below the grid")
    }

    // MARK: - Day readout

    @ViewBuilder
    private func dayReadout(_ cell: AdherenceHeatmapCell?, formatter: DateFormatter) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let cell {
                Text(formatter.string(from: cell.date))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Design.Color.ink)
                if let total = cell.total, let adherence = cell.adherence {
                    Text("\(Int((adherence * 100).rounded()))%")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Self.fillColor(level: max(
                            2, NutritionProgressPolicy.adherenceLevel(adherence)
                        )))
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    Text(readoutNumbers(total: total, target: cell.effectiveTarget))
                        .font(.caption2)
                        .foregroundStyle(Design.Color.muted)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                } else {
                    Text("Nothing logged")
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)
                    Spacer(minLength: 4)
                }
            } else {
                Text("Tap a day to check its numbers")
                    .font(.caption)
                    .foregroundStyle(Design.Color.muted)
                Spacer(minLength: 4)
            }
        }
        .frame(minHeight: 16)
        .accessibilityElement(children: .combine)
    }

    private func readoutNumbers(total: DailyNutritionTotal, target: MacroTarget) -> String {
        let kcal = "\(Int(total.caloriesKcal.rounded()))/\(Int(target.caloriesKcal.rounded())) kcal"
        let protein = "P \(Int(total.proteinG.rounded()))/\(Int(target.proteinG.rounded()))"
        let carbs = "C \(Int(total.carbsG.rounded()))/\(Int(target.carbsG.rounded()))"
        let fat = "F \(Int(total.fatG.rounded()))/\(Int(target.fatG.rounded()))"
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
        return (max(10, min(26, fitted)), Self.cellSpacing)
    }

    /// Five discrete fills: one for "nothing logged", four adherence
    /// buckets. Distinct steps read clearly at cell size where the previous
    /// continuous opacity ramp did not.
    static func fillColor(level: Int) -> Color {
        switch level {
        case 1: Design.Color.success.opacity(0.28)
        case 2: Design.Color.success.opacity(0.52)
        case 3: Design.Color.success.opacity(0.76)
        case 4: Design.Color.success
        default: Design.Color.heatmapEmpty
        }
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
        guard let adherence = cell.adherence, let total = cell.total else {
            return "\(formatter.string(from: cell.date)), no completed meals"
        }
        return "\(formatter.string(from: cell.date)), \(Int((adherence * 100).rounded())) percent adherence, \(Int(total.caloriesKcal.rounded())) of \(Int(cell.effectiveTarget.caloriesKcal.rounded())) kilocalories"
    }
}
