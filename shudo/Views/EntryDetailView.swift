import SwiftUI
import UIKit

extension Notification.Name {
    static let entryReanalysisRequested = Notification.Name("shudo.entryReanalysisRequested")
}

struct EntryDetailView: View {
    let entryId: UUID
    private let reanalysisService: any EntryReanalysisServing
    @State private var detail: SupabaseService.EntryDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var expandedItemIndices: Set<Int> = []
    @State private var isShowingCorrection = false
    @State private var reanalysisNotice: String?
    @State private var reanalysisGeneration: UUID?

    init(entryId: UUID) {
        self.entryId = entryId
        reanalysisService = APIService(
            supabaseUrl: AppConfig.supabaseURL,
            supabaseAnonKey: AppConfig.supabaseAnonKey,
            sessionJWTProvider: { try await AuthSessionManager.shared.getAccessToken() }
        )
    }

    init(entryId: UUID, reanalysisService: any EntryReanalysisServing) {
        self.entryId = entryId
        self.reanalysisService = reanalysisService
    }

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

                        if let reanalysisNotice {
                            Label(reanalysisNotice, systemImage: "arrow.triangle.2.circlepath")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Design.Color.accentSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 15)
                                .padding(.vertical, 12)
                                .background(
                                    Design.Color.accentPrimary.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                                )
                        }

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
                            ExpandableDetailText(title: "Notes", text: notes)
                        }

                        if let transcript = nonempty(detail.transcript) {
                            ExpandableDetailText(title: "Transcript", text: transcript)
                        } else if let rawText = nonempty(detail.rawText) {
                            ExpandableDetailText(title: "Description", text: rawText)
                        }

                        correctionAction
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                } else if isLoading {
                    loadingView
                } else {
                    errorView
                }
            }
            .refreshable { await load() }
        }
        .navigationTitle("Meal")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: reanalysisGeneration) {
            guard let generation = reanalysisGeneration else { return }
            await pollForReanalysis(generation: generation)
        }
        .sheet(isPresented: $isShowingCorrection) {
            EntryCorrectionSheet(entryTitle: detail?.title ?? "this meal") { text, audioData, requestId in
                try await submitCorrection(
                    text: text,
                    audioData: audioData,
                    clientRequestId: requestId
                )
            }
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
        }
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
                        .foregroundStyle(Design.Color.muted)
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
                            .contentShape(Rectangle())
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Need to adjust this meal?")
                .font(.headline)
                .foregroundStyle(Design.Color.ink)
            Text("Speak or type a missing ingredient, portion change, or other correction.")
                .font(.footnote)
                .foregroundStyle(Design.Color.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button { isShowingCorrection = true } label: {
                Label("Correct this meal", systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Design.Color.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Design.Color.elevated, in: Capsule())
            }
            .buttonStyle(.plain)
        }
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
        NotificationCenter.default.post(name: .entryReanalysisRequested, object: entryId)

        if result.status == .complete {
            reanalysisNotice = "Analysis updated"
            await load()
        } else if result.status == .failed {
            throw APIService.APIError.server(
                statusCode: 409,
                message: "The correction couldn’t be applied. Try again."
            )
        } else {
            reanalysisNotice = "Updating the nutrition estimate…"
            reanalysisGeneration = UUID()
        }
    }

    private func pollForReanalysis(generation: UUID) async {
        for _ in 0..<60 {
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, reanalysisGeneration == generation else { return }

            do {
                guard let entry = try await SupabaseService().fetchEntry(id: entryId) else { return }
                if entry.status == .complete {
                    await load()
                    guard reanalysisGeneration == generation else { return }
                    reanalysisNotice = "Analysis updated"
                    reanalysisGeneration = nil
                    return
                }
                if entry.status == .failed {
                    reanalysisNotice = entry.errorMessage ?? "The update couldn’t be completed."
                    reanalysisGeneration = nil
                    return
                }
            } catch {
                // The durable background job may still be running. Keep the
                // existing detail visible and retry without flashing an error.
            }
        }

        guard reanalysisGeneration == generation else { return }
        reanalysisNotice = "Still updating — pull to refresh shortly"
        reanalysisGeneration = nil
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ExpandableDetailText: View {
    let title: String
    let text: String
    @State private var isExpanded = false

    private var offersExpansion: Bool {
        EntryDetailPresentation.offersExpansion(for: text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Design.Color.ink)

            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.ink)
                    .lineLimit(isExpanded || !offersExpansion ? nil : 5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if offersExpansion {
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        Text(isExpanded ? "Show less" : "Show more")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Design.Color.accentSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(15)
            .background(
                Design.Color.elevated,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
    }
}

private struct EntryCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @StateObject private var audio = AudioRecorder()
    @State private var context = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var clientRequestId = UUID()

    let entryTitle: String
    let onSubmit: (String?, Data?, UUID) async throws -> Void

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
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("What should change?")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(Design.Color.ink)
                            Text("Record a quick correction for \(entryTitle). Add a note only if it helps.")
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
                                    .frame(minHeight: 112, maxHeight: 170)
                                    .focused($isFocused)
                                    .onChange(of: context) { _, updated in
                                        if updated.count > EntryCorrectionPolicy.maximumCharacters {
                                            context = EntryCorrectionPolicy.normalized(updated)
                                        }
                                    }
                            }
                            .background(
                                Design.Color.elevated,
                                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                            )
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
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                            )
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("Updating the meal estimate. The current meal remains visible.")
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 90)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Add context")
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
        .preferredColorScheme(.dark)
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
                            ? .system(size: 25, weight: .medium, design: .rounded)
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

                        Image(systemName: audio.isRecording ? "stop.fill" : "waveform")
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
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
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
        isFocused = false
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
        isFocused = false
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
