import SwiftUI

struct EntryDetailView: View {
    let entryId: UUID
    @State private var detail: SupabaseService.EntryDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                if let detail {
                    VStack(alignment: .leading, spacing: 26) {
                        photo(detail.imageURL)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(detail.title)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Design.Color.ink)
                            Text(detail.createdAt, style: .time)
                                .font(.caption)
                                .foregroundStyle(Design.Color.muted)
                        }

                        macroSummary(detail)

                        if !detail.items.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                sectionTitle("Breakdown")
                                ForEach(Array(detail.items.enumerated()), id: \.offset) { index, item in
                                    itemRow(item)
                                    if index < detail.items.count - 1 {
                                        Rectangle()
                                            .fill(Design.Color.rule)
                                            .frame(height: 0.5)
                                    }
                                }
                            }
                        }

                        if let notes = nonempty(detail.analysisNotes) {
                            textSection(title: "Notes", text: notes)
                        }

                        if let transcript = nonempty(detail.transcript) {
                            textSection(title: "Transcript", text: transcript)
                        } else if let rawText = nonempty(detail.rawText) {
                            textSection(title: "Description", text: rawText)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                } else if isLoading {
                    loadingView
                } else {
                    errorView
                }
            }
        }
        .navigationTitle("Meal")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private func photo(_ url: URL?) -> some View {
        if let url {
            AsyncImage(url: url, transaction: .init(animation: .easeInOut(duration: 0.22))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill().transition(.opacity)
                case .failure:
                    photoPlaceholder(systemImage: "photo")
                case .empty:
                    photoPlaceholder(systemImage: nil).shimmering()
                @unknown default:
                    photoPlaceholder(systemImage: nil)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 260)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func photoPlaceholder(systemImage: String?) -> some View {
        Rectangle()
            .fill(Design.Color.elevated)
            .overlay {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(Design.Color.muted)
                }
            }
    }

    private func macroSummary(_ detail: SupabaseService.EntryDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(detail.caloriesKcal.rounded()))")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Design.Color.ink)
                    .monospacedDigit()
                Text("kcal")
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.muted)
                Spacer()
                if let confidence = detail.confidence, confidence > 0 {
                    Text("\(Int((confidence * 100).rounded()))% confidence")
                        .font(.caption)
                        .foregroundStyle(Design.Color.subtle)
                }
            }

            HStack(spacing: 10) {
                macroValue("Protein", detail.proteinG, Design.Color.ringProtein)
                macroValue("Carbs", detail.carbsG, Design.Color.ringCarb)
                macroValue("Fat", detail.fatG, Design.Color.ringFat)
            }
        }
    }

    private func macroValue(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(Int(value.rounded()))g")
                .font(.headline)
                .foregroundStyle(Design.Color.ink)
                .monospacedDigit()
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(.caption).foregroundStyle(Design.Color.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private func itemRow(_ item: SupabaseService.EntryDetailItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Design.Color.ink)
                Spacer()
                Text(item.amount)
                    .font(.caption)
                    .foregroundStyle(Design.Color.muted)
            }
            HStack(spacing: 14) {
                compactMacro("P", item.proteinG, Design.Color.ringProtein)
                compactMacro("C", item.carbsG, Design.Color.ringCarb)
                compactMacro("F", item.fatG, Design.Color.ringFat)
                Spacer()
                Text("\(Int(item.caloriesKcal.rounded())) kcal")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Design.Color.muted)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 11)
    }

    private func compactMacro(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(label) \(Int(value.rounded()))g")
                .font(.caption2)
                .foregroundStyle(Design.Color.muted)
                .monospacedDigit()
        }
    }

    private func textSection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle(title)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Design.Color.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
                .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Design.Color.ink)
    }

    private var loadingView: some View {
        VStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 24).fill(Design.Color.elevated).frame(height: 260)
            Capsule().fill(Design.Color.elevated).frame(width: 190, height: 16)
            RoundedRectangle(cornerRadius: 20).fill(Design.Color.elevated).frame(height: 120)
        }
        .padding(20)
        .shimmering()
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.circle")
                .font(.title)
                .foregroundStyle(Design.Color.danger)
            Text(errorMessage ?? "This meal couldn’t be loaded.")
                .font(.subheadline)
                .foregroundStyle(Design.Color.muted)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }
                .foregroundStyle(Design.Color.accentPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 30)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            detail = try await SupabaseService().fetchEntryDetail(id: entryId)
            if detail == nil { errorMessage = "This meal no longer exists." }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
