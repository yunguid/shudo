import SwiftUI

struct EntryCard: View {
    let entry: Entry
    var isProcessing: Bool = false
    var onDelete: (() -> Void)? = nil

    @ScaledMetric(relativeTo: .body) private var thumb: CGFloat = 44
    
    private var hasImage: Bool {
        entry.imageURL != nil
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Only show thumbnail if there's an image
            if hasImage {
                thumbnail
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.summary)
                        .font(.subheadline)
                        .foregroundStyle(isProcessing ? Design.Color.muted : Design.Color.ink)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .textSelection(.disabled)
                    
                    if isProcessing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Design.Color.accentPrimary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isProcessing {
                    Text("Analyzing…")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Design.Color.accentPrimary)
                } else {
                    HStack(spacing: 8) {
                        macroChip(Design.Color.ringProtein, entry.proteinG)
                        macroChip(Design.Color.ringCarb, entry.carbsG)
                        macroChip(Design.Color.ringFat, entry.fatG)
                        
                        Spacer()
                        
                        Text("\(Int(entry.caloriesKcal.rounded()))")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Design.Color.ink)
                            .monospacedDigit()
                        + Text(" kcal")
                            .font(.caption2)
                            .foregroundStyle(Design.Color.muted)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "Protein \(Int(entry.proteinG.rounded()))g, Carbs \(Int(entry.carbsG.rounded()))g, Fat \(Int(entry.fatG.rounded()))g, Calories \(Int(entry.caloriesKcal.rounded()))kcal"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isProcessing {
                menuButton
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous)
                .fill(Design.Color.elevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous)
                .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
        )
        .opacity(isProcessing ? 0.7 : 1.0)
        .dynamicTypeSize(.xSmall ... .large)
    }

    private func macroChip(_ color: Color, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text("\(Int(value.rounded()))g")
                .font(.caption2)
                .foregroundStyle(Design.Color.muted)
                .monospacedDigit()
        }
    }

    @State private var showDeleteConfirmation = false
    
    private var menuButton: some View {
        Group {
            if onDelete != nil {
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Design.Color.muted)
                        .frame(width: 24, height: 24)
                        .background(Design.Color.glassFill, in: RoundedRectangle(cornerRadius: Design.Radius.s, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete entry")
                .confirmationDialog("Delete this entry?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { onDelete?() }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This action cannot be undone.")
                }
            }
        }
    }

    private var thumbnail: some View {
        AsyncImage(url: entry.imageURL, transaction: .init(animation: .easeInOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            case .empty:
                Rectangle()
                    .fill(Design.Color.elevated)
                    .redacted(reason: .placeholder)
            case .failure:
                Rectangle()
                    .fill(Design.Color.elevated)
            @unknown default:
                Rectangle()
                    .fill(Design.Color.elevated)
            }
        }
        .frame(width: thumb, height: thumb)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.s, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.s, style: .continuous)
                .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
        )
        .accessibilityLabel("Meal photo")
    }
}
