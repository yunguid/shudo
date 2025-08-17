import SwiftUI

// A clean, high-contrast metrics card inspired by enterprise data-graphics.
// Focuses on legibility, restrained color, and clear hierarchy.
struct MacroRingsView: View {
    let target: MacroTarget
    let current: DayTotals

    private var estimatedCalories: Double {
        let fromMacros = current.proteinG * 4 + current.carbsG * 4 + current.fatG * 9
        return current.caloriesKcal > 0 ? current.caloriesKcal : fromMacros
    }

    private var calorieProgress: Double { estimatedCalories / max(target.caloriesKcal, 1) }

    var body: some View {
        VStack(spacing: 18) {
            // Metric tiles laid out with equal widths; no GeometryReader sizing
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 0) {
                MacroTile(
                    title: "Protein",
                    short: "P",
                    color: .pink,
                    progress: safeProgress(current.proteinG, target.proteinG),
                    current: current.proteinG,
                    target: target.proteinG
                )
                MacroTile(
                    title: "Carbs",
                    short: "C",
                    color: .blue,
                    progress: safeProgress(current.carbsG, target.carbsG),
                    current: current.carbsG,
                    target: target.carbsG
                )
                MacroTile(
                    title: "Fat",
                    short: "F",
                    color: .orange,
                    progress: safeProgress(current.fatG, target.fatG),
                    current: current.fatG,
                    target: target.fatG
                )
            }
            .frame(height: 116)

            // Calorie budget
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Estimated Calories", systemImage: "flame.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(estimatedCalories)) / \(Int(target.caloriesKcal))")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(estimatedCalories > target.caloriesKcal ? Color.red : Color.primary)
                        .monospacedDigit()
                }
                GaugeCapsule(
                    progress: max(0, min(calorieProgress, 1)),
                    height: 10,
                    gradient: LinearGradient(
                        colors: estimatedCalories > target.caloriesKcal ? [.orange, .red] : [.green, .blue],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                let diff = Int(abs(estimatedCalories - target.caloriesKcal))
                Text(estimatedCalories <= target.caloriesKcal ? "\(diff) kcal left" : "\(diff) kcal over")
                    .font(.caption2)
                    .foregroundStyle((estimatedCalories <= target.caloriesKcal) ? Color.secondary : Color.red)
                    .lineLimit(1)
            }

            // Inline chips for quick reading
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    chip(color: .pink, title: "Protein", value: current.proteinG, target: target.proteinG)
                    chip(color: .blue, title: "Carbs", value: current.carbsG, target: target.carbsG)
                    chip(color: .orange, title: "Fat", value: current.fatG, target: target.fatG)
                }
                .padding(.trailing, 2)
            }
        }
    }

    private func safeProgress(_ value: Double, _ goal: Double) -> Double {
        guard goal > 0 else { return 0 }
        return value / goal
    }

    private func chip(color: Color, title: String, value: Double, target: Double) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text("\(Int(value)) / \(Int(target))").font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.gray.opacity(0.12)))
    }
}

// MARK: - Metric Tile

private struct MacroTile: View {
    let title: String
    let short: String
    let color: Color
    let progress: Double
    let current: Double
    let target: Double

    private var clamped: Double { min(max(progress, 0), 1) }
    private var overflow: Double { max(progress - 1, 0) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Track
                Circle()
                    .stroke(
                        AngularGradient(colors: [Color.gray.opacity(0.18), Color.gray.opacity(0.12), Color.gray.opacity(0.18)], center: .center),
                        style: StrokeStyle(lineWidth: 10)
                    )

                // Primary progress
                RadialMeter(
                    fraction: clamped,
                    lineWidth: 10,
                    gradient: AngularGradient(colors: [color.opacity(0.9), color.opacity(0.6), color.opacity(0.9)], center: .center)
                )

                // Overflow band (shows beyond 100%)
                if overflow > 0.0001 {
                    RadialMeter(
                        fraction: min(overflow, 1),
                        lineWidth: 10,
                        gradient: AngularGradient(colors: [.red.opacity(0.8), .red.opacity(0.5), .red.opacity(0.8)], center: .center)
                    )
                    .rotationEffect(.degrees(360 * clamped))
                }

                VStack(spacing: 2) {
                    Text(short)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(Int(current))")
                        .font(.subheadline.weight(.semibold))
                    Text("/ \(Int(target))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)

            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Radial Meter

private struct RadialMeter: View {
    let fraction: Double   // 0...1
    let lineWidth: CGFloat
    let gradient: AngularGradient

    var body: some View {
        Circle()
            .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
            .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .rotationEffect(.degrees(-90))
            .animation(.spring(response: 0.45, dampingFraction: 0.9), value: fraction)
    }
}
