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

                HStack(spacing: 10) {
                    macroBadge(label: "P", value: entry.proteinG, tint: .pink)
                    macroBadge(label: "C", value: entry.carbsG, tint: .blue)
                    macroBadge(label: "F", value: entry.fatG, tint: .orange)

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
        ZStack {
            if let url = entry.imageURL {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut)) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .empty: Color.gray.opacity(0.06)
                    case .failure: Color.gray.opacity(0.06)
                    @unknown default: Color.gray.opacity(0.06)
                    }
                }
            } else {
                Color.gray.opacity(0.06)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous)
                .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
        )
    }

    private func macroBadge(label: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundStyle(Design.Color.muted)
            Text("\(Int(value))").font(.caption.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Design.Color.fill)
        )
        .overlay(
            Capsule().stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
        )
    }
}


