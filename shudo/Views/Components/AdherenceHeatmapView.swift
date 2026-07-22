import SwiftUI

struct AdherenceHeatmapView: View {
    let totals: [DailyNutritionTotal]
    let target: MacroTarget
    let targetHistory: [DailyMacroTargetSnapshot]
    let timezone: String

    private var cells: [AdherenceHeatmapCell] {
        NutritionProgressPolicy.heatmapCells(
            totals: totals,
            target: target,
            targetHistory: targetHistory,
            timezone: timezone
        )
    }

    private var weeks: [[AdherenceHeatmapCell]] {
        stride(from: 0, to: cells.count, by: 7).map { start in
            Array(cells[start..<min(start + 7, cells.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Adherence")
                        .font(.headline)
                        .foregroundStyle(Design.Color.ink)
                    Text("Last 12 weeks")
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)
                }
                Spacer()
                legend
            }

            HStack(alignment: .top, spacing: 4) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: 4) {
                        ForEach(week) { cell in
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(cellColor(cell))
                                .frame(width: 12, height: 12)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(accessibilityLabel(cell))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(
            Design.Color.glassFill,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less")
            ForEach([0.2, 0.45, 0.7, 1.0], id: \.self) { score in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Design.Color.success.opacity(0.16 + score * 0.78))
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
        guard let adherence = cell.adherence else { return Design.Color.elevated }
        return Design.Color.success.opacity(0.16 + min(max(adherence, 0), 1) * 0.78)
    }

    private func accessibilityLabel(_ cell: AdherenceHeatmapCell) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        guard let adherence = cell.adherence else {
            return "\(formatter.string(from: cell.date)), no completed meals"
        }
        return "\(formatter.string(from: cell.date)), \(Int((adherence * 100).rounded())) percent adherence"
    }
}
