import SwiftUI

struct EntryCard: View {
    let entry: Entry
    var onDelete: (() -> Void)? = nil

    @ScaledMetric(relativeTo: .body) private var thumb: CGFloat = 60
    @ScaledMetric(relativeTo: .body) private var pad: CGFloat = 12
    var body: some View {
        HStack(alignment: .top, spacing: Design.Spacing.m) {
            thumbnail

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.summary)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(Design.Color.ink)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .textSelection(.disabled)
                        .layoutPriority(1)
                }

                HStack(spacing: 12) {
                    macro("P", entry.proteinG, unit: "g")
                    macro("C", entry.carbsG, unit: "g")
                    macro("F", entry.fatG, unit: "g")
                    Spacer(minLength: 0)
                    macro(nil, entry.caloriesKcal, unit: "kcal")
                }
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(Design.Color.ink)
                .monospacedDigit()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Protein \(Int(entry.proteinG.rounded()))g, Carbs \(Int(entry.carbsG.rounded()))g, Fat \(Int(entry.fatG.rounded()))g, Calories \(Int(entry.caloriesKcal.rounded()))kcal"
                )
            }
        }
        .padding(pad)
        .cardStyle()
        .overlay(alignment: .topTrailing) { menuButton }
        .dynamicTypeSize(.xSmall ... .large)
    }

    private func macro(_ label: String?, _ value: Double, unit: String) -> some View {
        HStack(spacing: 4) {
            if let label {
                Text(label)
                    .fontWeight(.regular)
                    .foregroundStyle(Design.Color.muted)
            }
            Text("\(Int(value.rounded()))\(unit)")
                .kerning(-0.2)
        }
    }

    private var menuButton: some View {
        Group {
            if onDelete != nil {
                Menu {
                    Button(role: .destructive) { onDelete?() } label: {
                        Label("Delete Entry", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .imageScale(.medium)
                        .foregroundStyle(Design.Color.muted)
                        .padding(8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous)
                                .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
                        )
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel("More actions")
            }
        }
    }

   private var thumbnail: some View {
        ZStack {
            if let url = entry.imageURL {
                AsyncImage(url: url, transaction: .init(animation: .easeInOut)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity.combined(with: .scale))
                    case .empty:
                        placeholder
                            .redacted(reason: .placeholder)
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: thumb, height: thumb)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous)
                .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
        )
        .accessibilityLabel(entry.imageURL == nil ? "No photo" : "Meal photo")
    } 

    private var placeholder: some View {
        ZStack {
            Design.Color.fill
            Image(systemName: "photo")
                .font(.caption2)
                .foregroundStyle(Design.Color.muted)
        }
    }

    // retained for potential back-compat; unused after redesign
    private func macroBadge(label: String, title: String, value: Double, tint: Color) -> some View { EmptyView() }
}



