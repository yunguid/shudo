import SwiftUI
import UIKit

extension Notification.Name {
    static let entryReanalysisRequested = Notification.Name("shudo.entryReanalysisRequested")
}

enum EntryDetailLayoutPolicy {
    static let horizontalPadding: CGFloat = 20

    static func contentWidth(for viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - horizontalPadding * 2)
    }

    static func stacksMacroCards(for dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize >= .xxLarge
    }
}

struct EntryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var calorieFontSize: CGFloat = 40
    let entryId: UUID
    private let reanalysisService: any EntryReanalysisServing
    private let loadsRemotely: Bool
    @State private var detail: SupabaseService.EntryDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var expandedItemIndices: Set<Int> = []
    @State private var isShowingCorrection = false

    init(entryId: UUID) {
        self.entryId = entryId
        loadsRemotely = true
        reanalysisService = APIService(
            supabaseUrl: AppConfig.supabaseURL,
            supabaseAnonKey: AppConfig.supabaseAnonKey,
            sessionJWTProvider: { try await AuthSessionManager.shared.getAccessToken() }
        )
    }

    init(entryId: UUID, reanalysisService: any EntryReanalysisServing) {
        self.entryId = entryId
        loadsRemotely = true
        self.reanalysisService = reanalysisService
    }

    init(
        entryId: UUID,
        previewDetail: SupabaseService.EntryDetail,
        reanalysisService: any EntryReanalysisServing
    ) {
        self.entryId = entryId
        loadsRemotely = false
        self.reanalysisService = reanalysisService
        _detail = State(initialValue: previewDetail)
        _isLoading = State(initialValue: false)
    }

    var body: some View {
        ZStack {
            AppBackground()
            GeometryReader { viewport in
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

                            correctionAction

                            if !detail.items.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    sectionTitle("Breakdown")
                                    ForEach(Array(detail.items.enumerated()), id: \.offset) { index, item in
                                        itemRow(item, index: index)
                                        if index < detail.items.count - 1 {
                                            Rectangle()
                                                .fill(Design.Color.rule)
                                                .frame(height: 0.5)
                                        }
                                    }
                                }
                            }

                            if let notes = nonempty(detail.analysisNotes) {
                                DetailTextSection(
                                    title: "Analysis notes",
                                    systemImage: "doc.text.magnifyingglass",
                                    text: notes
                                )
                            }

                            if let transcript = nonempty(detail.transcript) {
                                DetailTextSection(
                                    title: "Transcript",
                                    systemImage: "text.quote",
                                    text: transcript,
                                    collapsedByDefault: true
                                )
                            } else if let rawText = nonempty(detail.rawText) {
                                DetailTextSection(
                                    title: "Description",
                                    systemImage: "text.bubble",
                                    text: rawText,
                                    collapsedByDefault: true
                                )
                            }
                        }
                        // A vertical ScrollView otherwise adopts a wide child's ideal width.
                        // Keep collages and nutrition rows inside the visible phone viewport.
                        .frame(
                            width: EntryDetailLayoutPolicy.contentWidth(for: viewport.size.width),
                            alignment: .leading
                        )
                        .padding(.horizontal, EntryDetailLayoutPolicy.horizontalPadding)
                        .padding(.vertical, 14)
                    } else if isLoading {
                        loadingView
                    } else {
                        errorView
                    }
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("Meal")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard loadsRemotely else { return }
            await load()
        }
        .sheet(isPresented: $isShowingCorrection) {
            EntryCorrectionSheet(
                entryTitle: detail?.title ?? "this meal",
                onSubmit: { text, audioData, requestId in
                    try await submitCorrection(
                        text: text,
                        audioData: audioData,
                        clientRequestId: requestId
                    )
                },
                onAccepted: returnToSelectedDay
            )
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(Design.Radius.sheet)
        }
    }

    @ViewBuilder
    private func photo(_ url: URL?) -> some View {
        if let url {
            AsyncImage(url: url, transaction: .init(animation: .easeInOut(duration: 0.22))) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        // Bounds the placeholder-to-photo layout jump while
                        // keeping the full photo visible.
                        .frame(maxHeight: 420)
                        .transition(.opacity)
                        .accessibilityLabel("Meal photo")
                case .failure:
                    photoPlaceholder(systemImage: "photo")
                        .frame(height: 260)
                case .empty:
                    photoPlaceholder(systemImage: nil)
                        .frame(height: 260)
                        .shimmering()
                @unknown default:
                    photoPlaceholder(systemImage: nil)
                        .frame(height: 260)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Design.Color.elevated)
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.hero, style: .continuous))
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    calorieSummary(detail)
                    Spacer(minLength: 12)
                    confidenceLabel(detail)
                }
                VStack(alignment: .leading, spacing: 5) {
                    calorieSummary(detail)
                    confidenceLabel(detail)
                }
            }

            if EntryDetailLayoutPolicy.stacksMacroCards(for: dynamicTypeSize) {
                VStack(spacing: 10) {
                    macroValue("Protein", detail.proteinG, Design.Color.ringProtein)
                    macroValue("Carbs", detail.carbsG, Design.Color.ringCarb)
                    macroValue("Fat", detail.fatG, Design.Color.ringFat)
                }
            } else {
                HStack(spacing: 10) {
                    macroValue("Protein", detail.proteinG, Design.Color.ringProtein)
                    macroValue("Carbs", detail.carbsG, Design.Color.ringCarb)
                    macroValue("Fat", detail.fatG, Design.Color.ringFat)
                }
            }
        }
    }

    private func calorieSummary(_ detail: SupabaseService.EntryDetail) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(Int(detail.caloriesKcal.rounded()))")
                .font(.system(size: calorieFontSize, weight: .bold))
                .foregroundStyle(Design.Color.ink)
                .monospacedDigit()
            Text("kcal")
                .font(.subheadline)
                .foregroundStyle(Design.Color.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int(detail.caloriesKcal.rounded())) kilocalories")
    }

    @ViewBuilder
    private func confidenceLabel(_ detail: SupabaseService.EntryDetail) -> some View {
        if let confidence = detail.confidence, confidence > 0 {
            Text("\(Int((confidence * 100).rounded()))% confidence")
                .font(.caption)
                .foregroundStyle(Design.Color.muted)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    "Nutrition estimate confidence, \(Int((confidence * 100).rounded())) percent"
                )
        }
    }

    private func macroValue(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(Int(value.rounded()))g")
                .font(.headline)
                .foregroundStyle(Design.Color.ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Design.Color.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(value.rounded())) grams")
    }

    private func itemRow(_ item: SupabaseService.EntryDetailItem, index: Int) -> some View {
        let offersExpansion = EntryDetailPresentation.offersItemExpansion(
            name: item.name,
            amount: item.amount
        )
        let isExpanded = expandedItemIndices.contains(index)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.ink)
                        .lineLimit(isExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if !item.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(item.amount)
                            .font(.caption)
                            .foregroundStyle(Design.Color.muted)
                            .lineLimit(isExpanded ? nil : 1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if offersExpansion {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            if isExpanded {
                                expandedItemIndices.remove(index)
                            } else {
                                expandedItemIndices.insert(index)
                            }
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Design.Color.muted)
                            .frame(width: 32, height: 32)
                            // 44pt tap target without growing the 32pt row footprint.
                            .contentShape(Rectangle().inset(by: -6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse item details" : "Expand item details")
                }
            }

            ViewThatFits(in: .horizontal) {
                itemMacroLine(item)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 14) {
                        compactMacro("P", item.proteinG, Design.Color.ringProtein)
                        compactMacro("C", item.carbsG, Design.Color.ringCarb)
                        compactMacro("F", item.fatG, Design.Color.ringFat)
                    }
                    calorieLabel(item.caloriesKcal)
                }
            }
        }
        .padding(.vertical, 11)
    }

    private func itemMacroLine(_ item: SupabaseService.EntryDetailItem) -> some View {
        HStack(spacing: 14) {
            compactMacro("P", item.proteinG, Design.Color.ringProtein)
            compactMacro("C", item.carbsG, Design.Color.ringCarb)
            compactMacro("F", item.fatG, Design.Color.ringFat)
            Spacer(minLength: 4)
            calorieLabel(item.caloriesKcal)
        }
    }

    private func calorieLabel(_ calories: Double) -> some View {
        Text("\(Int(calories.rounded())) kcal")
            .font(.caption.weight(.medium))
            .foregroundStyle(Design.Color.muted)
            .monospacedDigit()
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

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Design.Color.ink)
    }

    private var correctionAction: some View {
        Button { isShowingCorrection = true } label: {
            Text("Update meal")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    LinearGradient(
                        colors: [Design.Color.ctaPrimary, Design.Color.ctaSecondary],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Add a voice recording or note to revise the estimate")
    }

    private var loadingView: some View {
        VStack(spacing: 18) {
            RoundedRectangle(cornerRadius: Design.Radius.hero).fill(Design.Color.elevated).frame(height: 260)
            Capsule().fill(Design.Color.elevated).frame(width: 190, height: 16)
            RoundedRectangle(cornerRadius: Design.Radius.xl).fill(Design.Color.elevated).frame(height: 120)
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

    private func submitCorrection(
        text: String?,
        audioData: Data?,
        clientRequestId: UUID
    ) async throws {
        let result = try await reanalysisService.correctEntry(
            id: entryId,
            text: text,
            audioData: audioData,
            clientRequestId: clientRequestId
        )
        if result.status == .failed {
            throw APIService.APIError.server(
                statusCode: 409,
                message: "The correction couldn’t be applied. Try again."
            )
        }
        NotificationCenter.default.post(name: .entryReanalysisRequested, object: entryId)
    }

    private func returnToSelectedDay() {
        Task { @MainActor in
            await Task.yield()
            dismiss()
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct DetailTextSection: View {
    let title: String
    let systemImage: String
    let text: String
    let collapsedByDefault: Bool
    @State private var isExpanded: Bool

    init(
        title: String,
        systemImage: String,
        text: String,
        collapsedByDefault: Bool = false
    ) {
        self.title = title
        self.systemImage = systemImage
        self.text = text
        self.collapsedByDefault = collapsedByDefault
        _isExpanded = State(initialValue: false)
    }

    private var offersExpansion: Bool {
        EntryDetailPresentation.offersExpansion(for: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if collapsedByDefault {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 9) {
                        Label(title, systemImage: systemImage)
                            .font(.headline)
                            .foregroundStyle(Design.Color.ink)
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Design.Color.muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isExpanded ? "Hide" : "Show") \(title.lowercased())")
            } else {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .foregroundStyle(Design.Color.ink)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !collapsedByDefault && offersExpansion {
                        Button("Show less") {
                            withAnimation(.snappy(duration: 0.22)) {
                                isExpanded = false
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Design.Color.accentSecondary)
                        .buttonStyle(.plain)
                    }
                }
                .padding(15)
                .background(
                    Design.Color.elevated,
                    in: RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if !collapsedByDefault {
                VStack(alignment: .leading, spacing: 10) {
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.ink)
                        .lineLimit(offersExpansion ? 5 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if offersExpansion {
                        Button {
                            withAnimation(.snappy(duration: 0.22)) {
                                isExpanded = true
                            }
                        } label: {
                            Text("Show more")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Design.Color.accentSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(15)
                .background(
                    Design.Color.elevated,
                    in: RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
                )
            }
        }
    }
}

private struct EntryCorrectionSheet: View {
    private enum FocusField: Hashable {
        case note
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: FocusField?
    @StateObject private var audio = AudioRecorder()
    @State private var context = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var clientRequestId = UUID()

    let entryTitle: String
    let onSubmit: (String?, Data?, UUID) async throws -> Void
    let onAccepted: () -> Void

    private var hasAudio: Bool {
        audio.recordedFileURL != nil
    }

    private var canSubmit: Bool {
        EntryCorrectionPolicy.canSubmit(
            text: context,
            hasAudio: hasAudio,
            isSubmitting: isSubmitting
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("What changed?")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Design.Color.ink)
                            Text("Tell Shudo what to adjust for \(entryTitle).")
                                .font(.subheadline)
                                .foregroundStyle(Design.Color.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        voiceCorrectionCard

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Optional note")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Design.Color.ink)

                            ZStack(alignment: .topLeading) {
                                if context.isEmpty {
                                    Text("Example: The rice was one cup, not two.")
                                        .font(.body)
                                        .foregroundStyle(Design.Color.muted)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 15)
                                        .allowsHitTesting(false)
                                }
                                TextEditor(text: $context)
                                    .font(.body)
                                    .foregroundStyle(Design.Color.ink)
                                    .scrollContentBackground(.hidden)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 8)
                                    .frame(height: 128)
                                    .focused($focusedField, equals: .note)
                                    .onChange(of: context) { _, updated in
                                        if updated.count > EntryCorrectionPolicy.maximumCharacters {
                                            context = EntryCorrectionPolicy.normalized(updated)
                                        }
                                    }
                            }
                            .background(
                                Design.Color.elevated,
                                in: RoundedRectangle(cornerRadius: Design.Radius.xl, style: .continuous)
                            )
                            .id(FocusField.note)
                        }

                        HStack {
                            Spacer()
                            Text("\(context.count) / \(EntryCorrectionPolicy.maximumCharacters)")
                                .font(.caption2)
                                .foregroundStyle(Design.Color.muted)
                                .monospacedDigit()
                        }

                        if let errorMessage {
                            VStack(alignment: .leading, spacing: 10) {
                                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(Design.Color.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Start over") {
                                    resetCorrection()
                                }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Design.Color.accentSecondary)
                                .buttonStyle(.plain)
                                .disabled(isSubmitting)
                            }
                        }

                        if isSubmitting {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .tint(Design.Color.accentSecondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Updating the estimate…")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Design.Color.ink)
                                    Text("The current meal stays visible until the update is ready.")
                                        .font(.caption)
                                        .foregroundStyle(Design.Color.muted)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(
                                Design.Color.elevated,
                                in: RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
                            )
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Updating the meal estimate. The current meal remains visible.")
                        }
                        }
                        .padding(20)
                        .padding(.bottom, 90)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: focusedField) { _, field in
                        guard field == .note else { return }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                scrollProxy.scrollTo(FocusField.note, anchor: .center)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Update meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        audio.discardRecording()
                        dismiss()
                    }
                        .foregroundStyle(Design.Color.muted)
                        .disabled(isSubmitting)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    submit()
                } label: {
                    HStack(spacing: 9) {
                        if isSubmitting { ProgressView().tint(.white) }
                        Text(isSubmitting ? "Updating…" : "Update estimate")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        LinearGradient(
                            colors: canSubmit
                                ? [Design.Color.ctaPrimary, Design.Color.ctaSecondary]
                                : [Design.Color.subtle, Design.Color.subtle],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .onDisappear {
            audio.discardRecording()
        }
    }

    private var voiceCorrectionCard: some View {
        VStack(spacing: 17) {
            CorrectionAudioMeter(levels: audio.meterLevels, isActive: audio.isRecording)
                .frame(height: 60)
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(voiceHeadline)
                    .font(
                        audio.isRecording
                            ? .system(size: 25, weight: .medium)
                            : .headline
                    )
                    .foregroundStyle(Design.Color.ink)
                    .monospacedDigit()
                Text(voiceDetail)
                    .font(.footnote)
                    .foregroundStyle(Design.Color.muted)
                    .monospacedDigit()
            }

            HStack(spacing: 16) {
                if hasAudio && !audio.isRecording {
                    Button {
                        audio.discardRecording()
                        clientRequestId = UUID()
                        errorMessage = nil
                    } label: {
                        Image(systemName: "trash")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Design.Color.muted)
                            .frame(width: 48, height: 48)
                            .background(Design.Color.glassFill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting)
                    .accessibilityLabel("Discard correction recording")
                }

                Button {
                    Task { await toggleRecording() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                audio.isRecording
                                    ? AnyShapeStyle(Design.Color.danger)
                                    : AnyShapeStyle(
                                        LinearGradient(
                                            colors: [
                                                Design.Color.accentPrimary,
                                                Design.Color.accentSecondary
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                            .frame(width: 76, height: 76)
                            .shadow(
                                color: Design.Color.accentPrimary.opacity(
                                    reduceMotion ? 0 : (audio.isRecording ? 0.12 : 0.28)
                                ),
                                radius: reduceMotion ? 0 : 24
                            )

                        Image(systemName: audio.isRecording ? "stop.fill" : "mic.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                .accessibilityLabel(recordingButtonLabel)
                .accessibilityHint(audio.isRecording ? "Saves this recording" : "Uses the microphone")
            }
        }
        .padding(22)
        .background(
            Design.Color.elevated,
            in: RoundedRectangle(cornerRadius: Design.Radius.hero, style: .continuous)
        )
    }

    private var voiceHeadline: String {
        if audio.isRecording { return formatTime(audio.elapsedTime) }
        return hasAudio ? "Correction ready" : "Speak the correction"
    }

    private var voiceDetail: String {
        if audio.isRecording { return "Tap when you’re done" }
        return hasAudio ? formatTime(audio.elapsedTime) : "Tap to record"
    }

    private var recordingButtonLabel: String {
        audio.isRecording
            ? "Stop correction recording, \(formatTime(audio.elapsedTime)) recorded"
            : "Start correction recording"
    }

    private func toggleRecording() async {
        errorMessage = nil
        focusedField = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if audio.isRecording {
            audio.stopRecording()
        } else {
            _ = await audio.startRecording()
        }
    }

    private func submit() {
        guard canSubmit else { return }
        if audio.isRecording { audio.stopRecording() }
        isSubmitting = true
        errorMessage = nil
        let normalized = EntryCorrectionPolicy.normalized(context)
        let text = normalized.isEmpty ? nil : normalized
        let audioData = audio.recordedData()
        if let audioData,
           !EntryCorrectionPolicy.audioIsWithinUploadLimit(audioData.count) {
            isSubmitting = false
            errorMessage = "That recording is too large. Discard it and record a shorter correction."
            return
        }
        let requestId = clientRequestId
        Task {
            do {
                try await onSubmit(text, audioData, requestId)
                await MainActor.run {
                    isSubmitting = false
                    audio.discardRecording()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                    onAccepted()
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = error.localizedDescription
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private func resetCorrection() {
        audio.discardRecording()
        context = ""
        clientRequestId = UUID()
        errorMessage = nil
        focusedField = nil
    }

    private func formatTime(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct CorrectionAudioMeter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let levels: [CGFloat]
    let isActive: Bool

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 4
            let count = max(levels.count, 1)
            let barWidth = max(
                2,
                (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
            )
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(
                            isActive
                                ? Design.Color.accentSecondary
                                : Design.Color.subtle.opacity(0.65)
                        )
                        .frame(
                            width: barWidth,
                            height: max(4, geometry.size.height * (isActive ? level : 0.07))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: levels
            )
        }
    }
}
