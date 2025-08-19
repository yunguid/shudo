import SwiftUI

/// Precision macro dashboard—austere and legible.
/// - Three dials (P/C/F) with overflow band
/// - Calorie budget gauge with left/over text
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
        VStack(spacing: Design.Spacing.l) {

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

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Estimated Calories", systemImage: "flame.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)

                    Spacer()

                    Text("\(Int(estimatedCalories)) / \(Int(target.caloriesKcal))")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(estimatedCalories > target.caloriesKcal ? Design.Color.danger : Design.Color.ink)
                        .monospacedDigit()
                }

                GaugeCapsule(
                    progress: max(0, min(calorieProgress, 1)),
                    height: 12,
                    gradient: LinearGradient(
                        colors: estimatedCalories > target.caloriesKcal
                            ? [Design.Color.ringFat, Design.Color.danger]
                            : [Design.Color.accentSecondary, Design.Color.accentPrimary],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

                let diff = Int(abs(estimatedCalories - target.caloriesKcal))
                Text(estimatedCalories <= target.caloriesKcal ? "\(diff) kcal left" : "\(diff) kcal over")
                    .font(.caption2)
                    .foregroundStyle(estimatedCalories <= target.caloriesKcal ? Design.Color.muted : Design.Color.danger)
                    .monospacedDigit()
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
    private var overflow: Double { max(progress - 1, 0) } // up to 1 => 200%

    var body: some View {
        VStack(spacing: 10) {
            Canvas { context, size in
                let w = size.width
                let h = size.height
                let side = min(w, h)
                let line = max(side * 0.12, 10)
                let radius = side/2 - line/2
                let center = CGPoint(x: w/2, y: h/2)

                // Track
                var track = Path()
                track.addArc(center: center, radius: radius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
                context.stroke(
                    track,
                    with: .color(Design.Color.rule.opacity(0.9)), // clearer track on dark
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

                // Overflow band (beyond 100%)
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
                            Gradient(colors: [Design.Color.danger.opacity(0.9), Design.Color.ringFat.opacity(0.9)]),
                            startPoint: .init(x: 0, y: 0),
                            endPoint: .init(x: 1, y: 1)
                        ),
                        style: StrokeStyle(lineWidth: line, lineCap: .round)
                    )
                }

                // Ticks (every 20%) to better differentiate
                let ticks = 5
                let tickLen = line * 0.50
                let tickWidth = max(line * 0.18, 1)
                let tickAlpha: CGFloat = 0.55  // slightly dimmer than content but still visible
                for i in 0...ticks {
                    let frac = Double(i)/Double(ticks)
                    let angle = Angle.degrees(-90 + 360*frac).radians
                    let inner = CGPoint(x: center.x + (radius - tickLen) * cos(angle),
                                        y: center.y + (radius - tickLen) * sin(angle))
                    let outer = CGPoint(x: center.x + (radius + tickLen) * cos(angle),
                                        y: center.y + (radius + tickLen) * sin(angle))
                    var tick = Path()
                    tick.move(to: inner); tick.addLine(to: outer)
                    context.stroke(tick, with: .color(Design.Color.rule.opacity(tickAlpha)), lineWidth: tickWidth)
                }
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(spacing: 2) {
                Text(short)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Text("\(Int(value))")
                    .font(.headline.weight(.semibold))
                    .monospacedDigit()
                Text("/ \(Int(goal))")
                    .font(.caption)
                    .foregroundStyle(Design.Color.muted)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Design.Color.muted)
                .frame(maxWidth: .infinity)
        }
    }
}
