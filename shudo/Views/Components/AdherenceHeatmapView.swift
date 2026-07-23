import SwiftUI

struct AdherenceHeatmapView: View {
    let totals: [DailyNutritionTotal]
    let target: MacroTarget
    let targetHistory: [DailyMacroTargetSnapshot]
    let timezone: String

    var body: some View {
        // One cells pass and one DateFormatter per render; both were previously
        // rebuilt per property access and per cell label.
        let cells = NutritionProgressPolicy.heatmapCells(
            totals: totals,
            target: target,
            targetHistory: targetHistory,
            timezone: timezone
        )
        let weekCount = (cells.count + 6) / 7
        let labelFormatter = makeLabelFormatter()
        VStack(alignment: .leading, spacing: 13) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) {
                    title
                    Spacer(minLength: 12)
                    legend
                }
                VStack(alignment: .leading, spacing: 3) {
                    title
                    legend
                }
            }

            AdherenceGrid(columnCount: weekCount, rowCount: 7) {
                ForEach(cells) { cell in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(cellColor(cell))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(Design.Color.heatmapBorder, lineWidth: Design.Stroke.hairline)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(accessibilityLabel(cell, formatter: labelFormatter))
                }
            }
        }
        .padding(18)
        .background(
            Design.Color.glassFill,
            in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
        )
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Adherence")
                .font(.headline)
                .foregroundStyle(Design.Color.ink)
            Text("Last 12 weeks")
                .font(.caption)
                .foregroundStyle(Design.Color.muted)
        }
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less")
            ForEach([0.2, 0.45, 0.7, 1.0], id: \.self) { score in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Design.Color.success.opacity(0.32 + score * 0.68))
                    .frame(width: 8, height: 8)
            }
            Text("On target")
        }
        .font(.caption2)
        .foregroundStyle(Design.Color.muted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Darker squares are closer to daily targets")
    }

    private func cellColor(_ cell: AdherenceHeatmapCell) -> Color {
        guard let adherence = cell.adherence else { return Design.Color.heatmapEmpty }
        return Design.Color.success.opacity(0.32 + min(max(adherence, 0), 1) * 0.68)
    }

    private func makeLabelFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        return formatter
    }

    private func accessibilityLabel(_ cell: AdherenceHeatmapCell, formatter: DateFormatter) -> String {
        guard let adherence = cell.adherence else {
            return "\(formatter.string(from: cell.date)), no completed meals"
        }
        return "\(formatter.string(from: cell.date)), \(Int((adherence * 100).rounded())) percent adherence"
    }
}

private struct AdherenceGrid: Layout {
    let columnCount: Int
    let rowCount: Int

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 320
        let metrics = metrics(for: width)
        return CGSize(
            width: width,
            height: metrics.cellSize * CGFloat(rowCount)
                + metrics.spacing * CGFloat(max(rowCount - 1, 0))
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let metrics = metrics(for: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let column = index / rowCount
            let row = index % rowCount
            guard column < columnCount else { continue }
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(column) * (metrics.cellSize + metrics.spacing),
                    y: bounds.minY + CGFloat(row) * (metrics.cellSize + metrics.spacing)
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: metrics.cellSize,
                    height: metrics.cellSize
                )
            )
        }
    }

    private func metrics(for width: CGFloat) -> (cellSize: CGFloat, spacing: CGFloat) {
        let columns = CGFloat(max(columnCount, 1))
        let preferredSpacing: CGFloat = 4
        let fittedCell = (width - preferredSpacing * (columns - 1)) / columns
        let cellSize = max(10, min(24, fittedCell))
        let spacing = columns > 1
            ? max(2, (width - cellSize * columns) / (columns - 1))
            : 0
        return (cellSize, spacing)
    }
}
