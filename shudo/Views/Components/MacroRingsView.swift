import SwiftUI

/// Macro dashboard with three dials (P/C/F) and calorie gauge
struct MacroRingsView: View {
    let target: MacroTarget
    let current: DayTotals

    private var estimatedCalories: Double {
        let fromMacros = current.proteinG * 4 + current.carbsG * 4 + current.fatG * 9
        return current.caloriesKcal > 0 ? current.caloriesKcal : fromMacros
    }

    private var calorieProgress: Double {
        let d = max(target.caloriesKcal, 1)
        return estimatedCalories / d
    }

    var body: some View {
        VStack(spacing: Design.Spacing.xl) {
            // Macro dials
            HStack(spacing: Design.Spacing.xl) {
                Dial(
                    title: "Protein",
                    short: "P",
                    color: Design.Color.ringProtein,
                    value: current.proteinG,
                    goal: max(target.proteinG, 1)
                )

                Dial(
                    title: "Carbs",
                    short: "C",
                    color: Design.Color.ringCarb,
                    value: current.carbsG,
                    goal: max(target.carbsG, 1)
                )

                Dial(
                    title: "Fat",
                    short: "F",
                    color: Design.Color.ringFat,
                    value: current.fatG,
                    goal: max(target.fatG, 1)
                )
            }

            // Calorie gauge
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 6) {
                        Image(systemName: "flame.fill")
                            .font(.caption)
                            .foregroundStyle(estimatedCalories > target.caloriesKcal ? Design.Color.warning : Design.Color.muted)
                        Text("Calories")
                            .font(.caption)
                            .foregroundStyle(Design.Color.muted)
                    }

                    Spacer()

                    Text("\(Int(estimatedCalories))")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(estimatedCalories > target.caloriesKcal ? Design.Color.warning : Design.Color.ink)
                        .monospacedDigit()
                    + Text(" / \(Int(target.caloriesKcal))")
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)
                        .monospacedDigit()
                }

                GaugeCapsule(
                    progress: max(0, min(calorieProgress, 1)),
                    height: 8,
                    gradient: LinearGradient(
                        colors: estimatedCalories > target.caloriesKcal
                            ? [Design.Color.warning, Design.Color.danger]
                            : [Design.Color.accentSecondary, Design.Color.accentPrimary],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

                let diff = Int(abs(estimatedCalories - target.caloriesKcal))
                HStack(spacing: 4) {
                    Circle()
                        .fill(estimatedCalories <= target.caloriesKcal ? Design.Color.success : Design.Color.warning)
                        .frame(width: 6, height: 6)
                    Text(estimatedCalories <= target.caloriesKcal ? "\(diff) kcal remaining" : "\(diff) kcal over")
                        .font(.caption)
                        .foregroundStyle(estimatedCalories <= target.caloriesKcal ? Design.Color.muted : Design.Color.warning)
                        .monospacedDigit()
                }
            }
        }
    }
}

// MARK: - Dial

private struct Dial: View {
    let title: String
    let short: String
    let color: Color
    let value: Double
    let goal: Double

    private var progress: Double { value / goal }
    private var clamped: Double { min(max(progress, 0), 1) }
    private var overflow: Double { max(progress - 1, 0) }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Canvas { context, size in
                    let w = size.width
                    let h = size.height
                    let side = min(w, h)
                    let line = max(side * 0.10, 8)
                    let radius = side/2 - line/2
                    let center = CGPoint(x: w/2, y: h/2)

                    // Track
                    var track = Path()
                    track.addArc(center: center, radius: radius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                    context.stroke(
                        track,
                        with: .color(Design.Color.elevated),
                        style: StrokeStyle(lineWidth: line)
                    )

                    // Primary arc
                    if clamped > 0 {
                        var arc = Path()
                        arc.addArc(center: center,
                                   radius: radius,
                                   startAngle: .degrees(-90),
                                   endAngle: .degrees(-90 + 360 * clamped),
                                   clockwise: false)
                        context.stroke(
                            arc,
                            with: .color(Design.Color.ring(color)),
                            style: StrokeStyle(lineWidth: line, lineCap: .round)
                        )
                    }

                    // Overflow band
                    if overflow > 0.0001 {
                        var arc2 = Path()
                        let start = -90 + 360 * clamped
                        let end = start + 360 * min(overflow, 1)
                        arc2.addArc(center: center,
                                    radius: radius,
                                    startAngle: .degrees(start),
                                    endAngle: .degrees(end),
                                    clockwise: false)
                        context.stroke(
                            arc2,
                            with: .linearGradient(
                                Gradient(colors: [Design.Color.warning.opacity(0.9), Design.Color.danger.opacity(0.9)]),
                                startPoint: .init(x: 0, y: 0),
                                endPoint: .init(x: 1, y: 1)
                            ),
                            style: StrokeStyle(lineWidth: line, lineCap: .round)
                        )
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                
                // Center content
                VStack(spacing: 0) {
                    Text("\(Int(value))")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Design.Color.ink)
                        .monospacedDigit()
                    Text("/ \(Int(goal))")
                        .font(.caption2)
                        .foregroundStyle(Design.Color.subtle)
                        .monospacedDigit()
                }
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Design.Color.muted)
            }
        }
    }
}
