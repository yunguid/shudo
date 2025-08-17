import SwiftUI

struct MacroRingsView: View {
    let target: MacroTarget
    let current: DayTotals

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .bottom, spacing: 12) {
                ring(progress: current.proteinG / max(target.proteinG, 1), color: .pink, label: "P", current: current.proteinG, target: target.proteinG)
                ring(progress: current.carbsG / max(target.carbsG, 1), color: .blue, label: "C", current: current.carbsG, target: target.carbsG)
                ring(progress: current.fatG / max(target.fatG, 1), color: .orange, label: "F", current: current.fatG, target: target.fatG)
            }
            .frame(height: 120)
            HStack(spacing: 16) {
                legend(color: .pink, title: "Protein", value: current.proteinG, target: target.proteinG)
                legend(color: .blue, title: "Carbs", value: current.carbsG, target: target.carbsG)
                legend(color: .orange, title: "Fat", value: current.fatG, target: target.fatG)
                Spacer()
            }
        }
    }

    private func ring(progress: Double, color: Color, label: String, current: Double, target: Double) -> some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().stroke(Color.gray.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(label).font(.caption2).foregroundStyle(.secondary)
                    Text("\(Int(current))").font(.headline.weight(.semibold))
                    Text("/ \(Int(target))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
        }
    }

    private func legend(color: Color, title: String, value: Double, target: Double) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text("\(Int(value)) / \(Int(target))").font(.caption.weight(.medium))
            }
        }
    }
}


