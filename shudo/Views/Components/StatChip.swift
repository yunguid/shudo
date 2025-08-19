import SwiftUI

struct StatChip: View {
    enum Kind { case protein, carbs, fat, kcal }
    let kind: Kind
    let value: Int

    var body: some View {
        let (label, tint, unit) : (String, Color, String) = {
            switch kind {
            case .protein: return ("P", Design.Color.ringProtein, "g")
            case .carbs:   return ("C", Design.Color.ringCarb,    "g")
            case .fat:     return ("F", Design.Color.ringFat,     "g")
            case .kcal:    return ("kcal", Design.Color.accentSecondary, "kcal")
            }
        }()

        HStack(spacing: 6) {
            if kind != .kcal {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 8, weight: .regular, design: .rounded))
                    .foregroundStyle(tint)
                Text("\(value)\(unit)")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Design.Color.ink)
                    .minimumScaleFactor(0.95)
                    .allowsTightening(true)
            } else {
                Image(systemName: "flame.fill")
                    .imageScale(.small)
                    .foregroundStyle(tint)
                Text("\(value) \(unit)")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Design.Color.ink)
                    .minimumScaleFactor(0.95)
                    .allowsTightening(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .dynamicTypeSize(.xSmall ... .large)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .background(Design.Color.glassElev) // slightly stronger than card for contrast
                .clipShape(Capsule())
        )
        .overlay(
            Capsule().stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value) \(unit == "g" ? "grams" : "kilocalories")")
    }
}
