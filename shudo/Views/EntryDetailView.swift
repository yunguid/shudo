import AVFoundation
import Foundation
import PhotosUI
import SwiftUI
import UIKit

enum EntryDetailLayoutPolicy {
    static let horizontalPadding: CGFloat = 20

    static func contentWidth(for viewportWidth: CGFloat) -> CGFloat {
        max(0, viewportWidth - horizontalPadding * 2)
    }

    static func stacksMacroCards(for dynamicTypeSize: DynamicTypeSize) -> Bool {
        dynamicTypeSize >= .xxLarge
    }
}

/// One meal: the photo, what it was, one hero number, the macros, what's in
/// it, and the two things Luke does here — update it or log it again.
/// Estimation machinery (confidence, sources, research notes) stays behind
/// the scenes; the coach explains it in conversation when asked.
struct EntryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var calorieFontSize: CGFloat = 56
    let entryId: UUID
    /// Receives a locally accepted correction. The owner (the Today screen)
    /// runs the update and shows its progress on the meal card; this screen
    /// pops immediately after handing off.
    private let onCorrectionSubmit: (EntryCorrectionSubmission) -> Void
    /// Re-logs this meal for today from its description text
    /// (`LogAgainPolicy`). The owner runs the normal optimistic capture
    /// path; this screen pops right after handing off. Hidden when nil.
    private let onLogAgain: ((String) -> Void)?
    private let loadsRemotely: Bool
    /// What the timeline already knows about this meal (title, macros,
    /// photo). Rendered immediately so navigation never blocks on the
    /// network; the full fetch fills in the breakdown.
    private let seed: Entry?
    @State private var detail: SupabaseService.EntryDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var correctionRequest: CorrectionRequest?
    @State private var pendingLogAgainText: String?

    /// One presentation of the correction sheet; "Answer" carries the
    /// estimator's question.
    private struct CorrectionRequest: Identifiable {
        let id = UUID()
        var question: String?
    }

    init(
        entryId: UUID,
        seed: Entry? = nil,
        onCorrectionSubmit: @escaping (EntryCorrectionSubmission) -> Void,
        onLogAgain: ((String) -> Void)? = nil
    ) {
        self.entryId = entryId
        self.seed = seed
        loadsRemotely = true
        self.onCorrectionSubmit = onCorrectionSubmit
        self.onLogAgain = onLogAgain
    }

    init(
        entryId: UUID,
        previewDetail: SupabaseService.EntryDetail,
        onCorrectionSubmit: @escaping (EntryCorrectionSubmission) -> Void = { _ in },
        onLogAgain: ((String) -> Void)? = nil
    ) {
        self.entryId = entryId
        seed = nil
        loadsRemotely = false
        self.onCorrectionSubmit = onCorrectionSubmit
        self.onLogAgain = onLogAgain
        _detail = State(initialValue: previewDetail)
        _isLoading = State(initialValue: false)
    }

    var body: some View {
        ZStack {
            AppBackground()
            GeometryReader { viewport in
                ScrollView {
                    if let detail {
                        VStack(alignment: .leading, spacing: 28) {
                            photoGallery(detail.imageURLs)
                            summary(
                                title: detail.title,
                                createdAt: detail.createdAt,
                                calories: detail.caloriesKcal,
                                protein: detail.proteinG,
                                carbs: detail.carbsG,
                                fat: detail.fatG
                            )
                            if let question = ClarificationPolicy.question(in: detail.analysisNotes) {
                                clarificationRow(question)
                            }
                            mealActions(logAgainText: LogAgainPolicy.text(for: detail))
                            if !detail.items.isEmpty {
                                breakdown(detail.items)
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
                    } else if let seed {
                        // The timeline's card data renders in the first frame;
                        // only the breakdown below it waits for the fetch.
                        VStack(alignment: .leading, spacing: 28) {
                            photo(seed.imageURL)
                            summary(
                                title: seed.summary,
                                createdAt: seed.createdAt,
                                calories: seed.caloriesKcal,
                                protein: seed.proteinG,
                                carbs: seed.carbsG,
                                fat: seed.fatG
                            )
                            if let question = ClarificationPolicy.question(in: seed.analysisNotes) {
                                clarificationRow(question)
                            }
                            mealActions(logAgainText: nil)
                            if isLoading {
                                breakdownSkeleton
                            } else {
                                inlineLoadFailure
                            }
                        }
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
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { Perf.mark("detail.appear") }
        .task {
            guard loadsRemotely else { return }
            await load()
        }
        .sheet(item: $correctionRequest) { request in
            EntryCorrectionSheet(
                entryTitle: detail?.title ?? seed?.summary ?? "this meal",
                question: request.question,
                onSubmit: onCorrectionSubmit,
                onAccepted: returnToSelectedDay
            )
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(Design.Radius.sheet)
        }
        .confirmationDialog(
            "Log this meal again for today?",
            isPresented: Binding(
                get: { pendingLogAgainText != nil },
                set: { if !$0 { pendingLogAgainText = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingLogAgainText
        ) { text in
            Button("Log again") { logAgain(text) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Summary

    /// Title and time, then one hero number and the three macros under it.
    private func summary(
        title: String,
        createdAt: Date,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Design.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(createdAt, style: .time)
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.textTertiary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(calories.rounded()))")
                    .font(.system(size: calorieFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(Design.Color.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("kcal")
                    .font(.title3)
                    .foregroundStyle(Design.Color.textTertiary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Int(calories.rounded())) kilocalories")

            macroRow(protein: protein, carbs: carbs, fat: fat)
        }
    }

    @ViewBuilder
    private func macroRow(protein: Double, carbs: Double, fat: Double) -> some View {
        if EntryDetailLayoutPolicy.stacksMacroCards(for: dynamicTypeSize) {
            VStack(alignment: .leading, spacing: 10) {
                macroValue("Protein", protein, Design.Color.ringProtein)
                macroValue("Carbs", carbs, Design.Color.ringCarb)
                macroValue("Fat", fat, Design.Color.ringFat)
            }
        } else {
            HStack(spacing: 0) {
                macroValue("Protein", protein, Design.Color.ringProtein)
                macroValue("Carbs", carbs, Design.Color.ringCarb)
                macroValue("Fat", fat, Design.Color.ringFat)
            }
        }
    }

    private func macroValue(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(Int(value.rounded()))g")
                .font(Design.Typeface.numeral(.title3))
                .foregroundStyle(Design.Color.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(value.rounded())) grams")
    }

    // MARK: Question and actions

    /// The estimator's one follow-up question, lifted out of its notes.
    /// "Answer" opens Update meal (VM-owned submission) with the question
    /// on screen; the reply goes out as "Q: … A: …".
    private func clarificationRow(_ question: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(question)
                .font(.body)
                .foregroundStyle(Design.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                correctionRequest = CorrectionRequest(question: question)
            } label: {
                Text("Answer")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Design.Color.onEmber)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 40)
                    .background(Design.Color.emberFill, in: Capsule())
                    .contentShape(Capsule().inset(by: -4))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Update meal with this question")
            .accessibilityIdentifier("entryDetail.clarification.answer")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Design.Color.bubbleCoach,
            in: RoundedRectangle(cornerRadius: Design.Radius.bubble, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("entryDetail.clarification")
    }

    /// "Update meal", plus "Log again" when the owner wired it and the meal
    /// has text to re-log.
    @ViewBuilder
    private func mealActions(logAgainText: String?) -> some View {
        if let logAgainText, onLogAgain != nil {
            if EntryDetailLayoutPolicy.stacksMacroCards(for: dynamicTypeSize) {
                VStack(spacing: 10) {
                    correctionAction
                    logAgainButton(logAgainText, fillsWidth: true)
                }
            } else {
                HStack(spacing: 10) {
                    correctionAction
                    logAgainButton(logAgainText, fillsWidth: false)
                }
            }
        } else {
            correctionAction
        }
    }

    private var correctionAction: some View {
        Button { correctionRequest = CorrectionRequest() } label: {
            Text("Update meal")
                .font(.headline)
                .foregroundStyle(Design.Color.onEmber)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
                .background(Design.Color.emberFill, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Say or type what changed, or add a photo")
    }

    private func logAgainButton(_ text: String, fillsWidth: Bool) -> some View {
        Button { pendingLogAgainText = text } label: {
            Label("Log again", systemImage: "arrow.counterclockwise")
                .font(.headline)
                .foregroundStyle(Design.Color.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: !fillsWidth, vertical: false)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .padding(.horizontal, 18)
                .frame(minHeight: 50)
                .background(Design.Color.surface2, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Logs this meal again for today")
        .accessibilityIdentifier("entryDetail.logAgain")
    }

    private func logAgain(_ text: String) {
        pendingLogAgainText = nil
        guard let onLogAgain else { return }
        onLogAgain(text)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(notification: .announcement, argument: "Logging this meal again for today")
        returnToSelectedDay()
    }

    // MARK: Breakdown

    /// What's in it: one quiet row per item, no header — the rows say it.
    private func breakdown(_ items: [SupabaseService.EntryDetailItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { HairlineRule() }
                itemRow(item)
            }
        }
    }

    private func itemRow(_ item: SupabaseService.EntryDetailItem) -> some View {
        let amount = item.amount.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Design.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(itemDetail(amount: amount, item: item))
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(Int(item.caloriesKcal.rounded()))")
                .font(Design.Typeface.numeral(.body, weight: .medium))
                .foregroundStyle(Design.Color.textSecondary)
                .monospacedDigit()
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(item.name)\(amount.isEmpty ? "" : ", \(amount)"), \(Int(item.caloriesKcal.rounded())) kilocalories, "
                + "protein \(Int(item.proteinG.rounded())) grams, carbs \(Int(item.carbsG.rounded())) grams, "
                + "fat \(Int(item.fatG.rounded())) grams"
        )
    }

    private func itemDetail(amount: String, item: SupabaseService.EntryDetailItem) -> String {
        let macros = "\(Int(item.proteinG.rounded()))P · \(Int(item.carbsG.rounded()))C · \(Int(item.fatG.rounded()))F"
        return amount.isEmpty ? macros : "\(amount) · \(macros)"
    }

    private var breakdownSkeleton: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    Capsule().fill(Design.Color.surface1).frame(width: 190, height: 12)
                    Capsule().fill(Design.Color.surface1).frame(width: 130, height: 9)
                }
            }
        }
        .shimmering()
        .accessibilityLabel("Loading what’s in it")
    }

    /// Shown under the seed content when the detail fetch failed: the meal's
    /// numbers are already on screen, so the failure is one quiet line.
    private var inlineLoadFailure: some View {
        HStack(spacing: 10) {
            Text("Couldn’t load what’s in it.")
                .font(.footnote)
                .foregroundStyle(Design.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Try again") { Task { await load() } }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Design.Color.honey)
                .buttonStyle(.plain)
        }
    }

    // MARK: Photos

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
            .background(Design.Color.surface1)
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.hero, style: .continuous))
        }
    }

    @ViewBuilder
    private func photoGallery(_ urls: [URL]) -> some View {
        if urls.count <= 1 {
            photo(urls.first)
        } else {
            TabView {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .accessibilityLabel("Meal photo \(index + 1) of \(urls.count)")
                        case .failure:
                            photoPlaceholder(systemImage: "photo")
                                .accessibilityLabel("Meal photo \(index + 1) couldn’t be loaded")
                        case .empty:
                            photoPlaceholder(systemImage: nil)
                                .shimmering()
                                .accessibilityLabel("Loading meal photo \(index + 1)")
                        @unknown default:
                            photoPlaceholder(systemImage: nil)
                        }
                    }
                    .padding(.bottom, 18)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: urls)
            .frame(height: 320)
            .background(Design.Color.surface1)
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.hero, style: .continuous))
            .accessibilityHint("Swipe left or right to browse meal photos")
        }
    }

    private func photoPlaceholder(systemImage: String?) -> some View {
        Rectangle()
            .fill(Design.Color.surface1)
            .overlay {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(Design.Color.textTertiary)
                }
            }
    }

    // MARK: Loading

    private var loadingView: some View {
        VStack(alignment: .leading, spacing: 18) {
            RoundedRectangle(cornerRadius: Design.Radius.hero).fill(Design.Color.surface1).frame(height: 260)
            Capsule().fill(Design.Color.surface1).frame(width: 190, height: 16)
            Capsule().fill(Design.Color.surface1).frame(width: 120, height: 40)
        }
        .padding(20)
        .shimmering()
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Text(errorMessage ?? "This meal couldn’t be loaded.")
                .font(.subheadline)
                .foregroundStyle(Design.Color.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Design.Color.honey)
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

    private func returnToSelectedDay() {
        Task { @MainActor in
            await Task.yield()
            dismiss()
        }
    }
}

/// "Update meal": say or type what changed (or answer the estimator's one
/// question), optionally add photos, send. The bottom is the capture bar's
/// shape — mic bottom-left, tap again to send.
struct EntryCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Held unobserved: the bar observes it, and this sheet mirrors only
    /// whether a take is in flight, so meter updates never re-render the
    /// photos.
    @StateObject private var voiceHolder = UnobservedHolder(VoiceTranscriber(profile: .correction))
    @State private var hasLiveDictation = false
    @State private var dictatedTakeCount = 0
    @State private var dictatedEngine: SpeechEngineID?
    @State private var context = ""
    @State private var hasSubmitted = false
    @State private var errorMessage: String?
    @State private var clientRequestId = UUID()
    @State private var pickedImages: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []
    @State private var isShowingCamera = false
    @State private var isShowingPhotoPicker = false
    @State private var isPreparingImage = false
    @State private var imageLoadGeneration = UUID()
    @State private var imagePreparationTask: Task<Void, Never>?
    @State private var uploadEncodeTask: Task<Data?, Never>?

    let entryTitle: String
    /// The estimator's question when Luke tapped "Answer"; his reply goes
    /// out as "Q: … A: …" so the estimator has the context.
    let question: String?
    let onSubmit: (EntryCorrectionSubmission) -> Void
    let onAccepted: () -> Void

    init(
        entryTitle: String,
        question: String? = nil,
        onSubmit: @escaping (EntryCorrectionSubmission) -> Void,
        onAccepted: @escaping () -> Void
    ) {
        self.entryTitle = entryTitle
        self.question = question
        self.onSubmit = onSubmit
        self.onAccepted = onAccepted
    }

    private var voice: VoiceTranscriber { voiceHolder.value }

    private var canSubmit: Bool {
        EntryCorrectionPolicy.canSubmit(
            text: context,
            hasLiveDictation: hasLiveDictation,
            hasImage: !images.isEmpty,
            isPreparingImage: isPreparingImage,
            isSubmitting: hasSubmitted
        )
    }

    private var updatesEstimate: Bool {
        EntryCorrectionPolicy.usesPhotoForEstimate(text: context, hasLiveDictation: hasLiveDictation)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(entryTitle)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Design.Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let question {
                            Text(question)
                                .font(Design.Typeface.bubble)
                                .foregroundStyle(Design.Color.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    Design.Color.bubbleCoach,
                                    in: RoundedRectangle(cornerRadius: Design.Radius.bubble, style: .continuous)
                                )
                                .accessibilityLabel("Shudo asks: \(question)")
                        }

                        photoGrid
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Update meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        imagePreparationTask?.cancel()
                        uploadEncodeTask?.cancel()
                        voice.cancel()
                        dismiss()
                    }
                    .foregroundStyle(Design.Color.textSecondary)
                    .disabled(hasSubmitted)
                }
            }
            .safeAreaInset(edge: .bottom) { bottomControls }
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { selected in
                prepareCameraImage(selected)
            }
            .ignoresSafeArea()
        }
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $pickedImages,
            maxSelectionCount: max(1, ImageProcessor.maximumPhotoCount - images.count),
            matching: .images
        )
        .onChange(of: pickedImages) { _, items in preparePickedImages(items) }
        .onChange(of: images) { _, updated in prepareUploadEncoding(for: updated) }
        .onChange(of: context) { _, updated in
            if updated.count > EntryCorrectionPolicy.maximumCharacters {
                context = EntryCorrectionPolicy.normalized(updated)
            }
        }
        .onReceive(voice.$phase) { phase in
            if hasLiveDictation != phase.holdsTake { hasLiveDictation = phase.holdsTake }
        }
        .onDisappear {
            // Camera and Photos temporarily cover this sheet. Keep the whole
            // draft, including dictated text, across those system UIs.
            guard !isShowingCamera, !isShowingPhotoPicker, !hasSubmitted else { return }
            imagePreparationTask?.cancel()
            uploadEncodeTask?.cancel()
            voice.cancel()
        }
        .interactiveDismissDisabled(hasSubmitted)
    }

    // MARK: Bottom: photos + the capture bar's shape

    private var bottomControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    photoButton("Camera", systemImage: "camera.fill") { requestCamera() }
                }
                photoButton("Photos", systemImage: "photo.on.rectangle") {
                    settleVoiceCapture()
                    errorMessage = nil
                    isShowingPhotoPicker = true
                }
            }
            .padding(.horizontal, 20)

            SheetCaptureBar(
                voice: voice,
                text: $context,
                placeholder: question == nil ? "What changed?" : "Your answer…",
                canSend: !images.isEmpty,
                isSendEnabled: canSubmit,
                isSending: hasSubmitted,
                sendLabel: updatesEstimate ? "Update estimate" : "Save photos",
                message: errorMessage,
                identifierPrefix: "correction",
                onWillRecord: { errorMessage = nil },
                onSend: submit,
                onTake: appendTake
            )
        }
        .padding(.top, 8)
    }

    private func photoButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        let enabled = !hasSubmitted && !isPreparingImage && images.count < ImageProcessor.maximumPhotoCount
        return Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(enabled ? Design.Color.textSecondary : Design.Color.textDisabled)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Design.Color.surface1, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    @ViewBuilder
    private var photoGrid: some View {
        if !images.isEmpty || isPreparingImage {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 108, maximum: 180), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                        ZStack(alignment: .topTrailing) {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: 116)
                                .overlay {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                }
                                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous))
                                // Fill overflow stays hit-testable past the
                                // clip and would block the controls around
                                // this grid (see the composer grid).
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            Button {
                                removePhoto(at: index)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 32, height: 32)
                                    .background(.black.opacity(0.62), in: Circle())
                                    .contentShape(Circle().inset(by: -6))
                            }
                            .padding(7)
                            .disabled(hasSubmitted)
                            .accessibilityLabel("Remove new photo \(index + 1)")
                        }
                    }
                    if isPreparingImage {
                        RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
                            .fill(Design.Color.surface1)
                            .frame(height: 116)
                            .shimmering()
                            .accessibilityLabel("Adding photo")
                    }
                }
                if !images.isEmpty, !updatesEstimate {
                    // A photo alone is kept as a memory; words change numbers.
                    Text("Saved with the meal. Say what changed to update the numbers.")
                        .font(.footnote)
                        .foregroundStyle(Design.Color.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Releases the microphone before the camera or picker takes the audio
    /// hardware; the words already said still land in the field.
    private func settleVoiceCapture() {
        voice.finishInBackground()
    }

    private func appendTake(_ take: VoiceTake) {
        let result = DictationMergePolicy.appending(
            take.text,
            to: context,
            limit: EntryCorrectionPolicy.maximumCharacters
        )
        if result.wasTruncated { errorMessage = VoiceCopy.reachedLengthLimit }
        guard result.record != nil else { return }
        context = result.note
        dictatedTakeCount += 1
        dictatedEngine = take.engine
    }

    private func requestCamera() {
        settleVoiceCapture()
        errorMessage = nil
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isShowingCamera = true
        case .notDetermined:
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                await MainActor.run {
                    if granted {
                        isShowingCamera = true
                    } else {
                        errorMessage = "Camera access is off. You can allow it in Settings or choose a photo."
                    }
                }
            }
        case .denied, .restricted:
            errorMessage = "Camera access is off. You can allow it in Settings or choose a photo."
        @unknown default:
            errorMessage = "The camera isn’t available right now. Choose a photo instead."
        }
    }

    private func preparePickedImages(_ items: [PhotosPickerItem]) {
        imagePreparationTask?.cancel()
        let generation = UUID()
        imageLoadGeneration = generation
        guard !items.isEmpty else {
            imagePreparationTask = nil
            isPreparingImage = false
            return
        }

        isPreparingImage = true
        errorMessage = nil
        let availableSlots = max(0, ImageProcessor.maximumPhotoCount - images.count)
        let selectedItems = Array(items.prefix(availableSlots))
        imagePreparationTask = Task.detached(priority: .userInitiated) {
            let loaded = await BoundedConcurrency.map(
                selectedItems,
                maximumConcurrentTasks: 2
            ) { item -> UIImage? in
                guard !Task.isCancelled,
                      let data = try? await item.loadTransferable(type: Data.self),
                      !Task.isCancelled else { return nil }
                return ImageProcessor.downsample(data: data)
            }
            let prepared = loaded.compactMap { $0 }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard imageLoadGeneration == generation else { return }
                imagePreparationTask = nil
                isPreparingImage = false
                pickedImages = []
                guard !prepared.isEmpty else {
                    errorMessage = "Those photos couldn’t be loaded. Your update draft is still here."
                    return
                }
                let remainingSlots = max(0, ImageProcessor.maximumPhotoCount - images.count)
                withAnimation(reduceMotion ? nil : .snappy) {
                    images.append(contentsOf: prepared.prefix(remainingSlots))
                }
                if prepared.count < selectedItems.count {
                    errorMessage = "Some photos couldn’t be loaded. The others are still attached."
                }
            }
        }
    }

    private func prepareCameraImage(_ image: UIImage) {
        guard images.count < ImageProcessor.maximumPhotoCount else { return }
        isPreparingImage = true
        errorMessage = nil
        let generation = imageLoadGeneration
        Task.detached(priority: .userInitiated) {
            let prepared = ImageProcessor.resizedForUpload(image)
            await MainActor.run {
                guard imageLoadGeneration == generation else { return }
                isPreparingImage = false
                guard images.count < ImageProcessor.maximumPhotoCount else { return }
                withAnimation(reduceMotion ? nil : .snappy) { images.append(prepared) }
            }
        }
    }

    private func prepareUploadEncoding(for updated: [UIImage]) {
        uploadEncodeTask?.cancel()
        guard !updated.isEmpty else {
            uploadEncodeTask = nil
            return
        }
        uploadEncodeTask = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil }
            return ImageProcessor.uploadJPEGData(from: updated)
        }
    }

    private func removePhoto(at offset: Int) {
        guard images.indices.contains(offset) else { return }
        withAnimation(reduceMotion ? nil : .snappy) {
            images = EntryCorrectionPolicy.removingPhoto(at: offset, from: images)
        }
        clientRequestId = UUID()
        errorMessage = nil
    }

    /// Validates locally and hands the correction off, then leaves right
    /// away. The update itself runs on the Today screen's meal card, so this
    /// sheet never has to hold the user through the network round-trip.
    /// The text the estimator gets: Luke's words, prefixed with the question
    /// when he's answering one (nil when he said nothing).
    private func submissionText() -> String? {
        let answer = EntryCorrectionPolicy.normalized(context)
        guard !answer.isEmpty else { return nil }
        guard let question else { return answer }
        return EntryCorrectionPolicy.normalized(ClarificationPolicy.answerPrefill(for: question) + answer)
    }

    /// Validates locally and hands the correction off, then leaves right
    /// away. The update itself runs on the Today screen's meal card, so this
    /// sheet never has to hold the user through the network round-trip.
    private func submit() {
        guard canSubmit else {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            return
        }
        errorMessage = nil
        hasSubmitted = true
        let selectedImages = images
        let encodeTask = uploadEncodeTask
        Task {
            // A recording still in flight is stopped and transcribed (or a
            // failed upload retried once) and lands in the note first —
            // send while recording is stop → transcribe → send.
            let hadTake = voice.hasTakeInFlight
            if let take = await voice.finishPendingTake(finalizationTimeout: 1.5) {
                appendTake(take)
            } else if hadTake, voice.errorMessage != nil {
                // Transcription failed: stay, so the bar can retry or
                // discard the kept recording.
                hasSubmitted = false
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            let text = submissionText()
            guard text != nil || !selectedImages.isEmpty else {
                hasSubmitted = false
                errorMessage = VoiceCopy.didNotCatchThat
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            var imageJPEG = await encodeTask?.value
            if !selectedImages.isEmpty && imageJPEG == nil {
                imageJPEG = await Task.detached(priority: .userInitiated) {
                    ImageProcessor.uploadJPEGData(from: selectedImages)
                }.value
            }
            guard selectedImages.isEmpty || imageJPEG != nil else {
                hasSubmitted = false
                errorMessage = "Those photos couldn’t be prepared. Remove them and try again."
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            let submission = EntryCorrectionSubmission(
                text: text,
                speechEngine: text != nil && dictatedTakeCount > 0 ? dictatedEngine : nil,
                imageJPEG: imageJPEG,
                clientRequestId: clientRequestId
            )
            onSubmit(submission)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            UIAccessibility.post(
                notification: .announcement,
                argument: submission.updatesEstimate ? "Updating meal" : "Saving meal photos"
            )
            dismiss()
            onAccepted()
        }
    }
}
