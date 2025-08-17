import SwiftUI

struct EntryCard: View {
    let entry: Entry
    

    var body: some View {
        HStack(spacing: Design.Spacing.m) {
            thumbnail

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.summary)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .layoutPriority(1)

                HStack(spacing: 10) {
                    macroBadge(label: "P", title: "Protein", value: entry.proteinG, tint: .pink)
                    macroBadge(label: "C", title: "Carbs", value: entry.carbsG, tint: .blue)
                    macroBadge(label: "F", title: "Fat", value: entry.fatG, tint: .orange)

                    Spacer(minLength: 0)

                    Text("\(Int(entry.caloriesKcal)) kcal")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Design.Color.muted)
                        .monospacedDigit()
                }
            }
        }
        .padding(12)
        .cardStyle()
    }

    private var thumbnail: some View {
        Group {
            if let url = entry.imageURL {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity.combined(with: .scale))
                    default:
                        Color.clear
                    }
                }
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous))
                .accessibilityLabel("Meal photo")
            }
        }
    }

    private func macroBadge(label: String, title: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint.opacity(0.95))
            Text("\(Int(value))")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Design.Color.fill)
        )
        .overlay(
            Capsule().stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(Int(value)) grams")
    }
}


