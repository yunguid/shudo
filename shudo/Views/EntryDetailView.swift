import Foundation
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
/// it. Fixing it happens right here: the bottom is the capture bar's shape
/// (Shudo's spot bottom-left, then the field) — say or type what was off.
/// The estimator's question, when it has one, is the field's placeholder.
/// Estimation machinery (confidence, sources, research notes) stays behind
/// the scenes; the coach explains it in conversation when asked.
struct EntryDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.setShellBandSuppressed) private var setShellBandSuppressed
    @ScaledMetric(relativeTo: .largeTitle) private var calorieFontSize: CGFloat = 60
    let entryId: UUID
    /// Receives a locally accepted correction. The owner (the Today screen)
    /// runs the update and shows its progress on the meal card; this screen
    /// pops immediately after handing off.
    private let onCorrectionSubmit: (EntryCorrectionSubmission) -> Void
    private let loadsRemotely: Bool
    /// What the timeline already knows about this meal (title, macros,
    /// photo). Rendered immediately so navigation never blocks on the
    /// network; the full fetch fills in the breakdown.
    private let seed: Entry?
    @State private var detail: SupabaseService.EntryDetail?
    @State private var isLoading = true
    @State private var errorMessage: String?

    init(
        entryId: UUID,
        seed: Entry? = nil,
        onCorrectionSubmit: @escaping (EntryCorrectionSubmission) -> Void
    ) {
        self.entryId = entryId
        self.seed = seed
        loadsRemotely = true
        self.onCorrectionSubmit = onCorrectionSubmit
    }

    init(
        entryId: UUID,
        previewDetail: SupabaseService.EntryDetail,
        onCorrectionSubmit: @escaping (EntryCorrectionSubmission) -> Void = { _ in }
    ) {
        self.entryId = entryId
        seed = nil
        loadsRemotely = false
        self.onCorrectionSubmit = onCorrectionSubmit
        _detail = State(initialValue: previewDetail)
        _isLoading = State(initialValue: false)
    }

    /// The estimator's one follow-up question, if it left one.
    private var question: String? {
        ClarificationPolicy.question(in: detail?.analysisNotes ?? seed?.analysisNotes)
    }

    var body: some View {
        ZStack {
            AppBackground()
            GeometryReader { viewport in
                ScrollView {
                    if let detail {
                        VStack(alignment: .leading, spacing: Design.Space.section) {
                            photoGallery(detail.imageURLs)
                            summary(
                                title: detail.title,
                                createdAt: detail.createdAt,
                                calories: detail.caloriesKcal,
                                protein: detail.proteinG,
                                carbs: detail.carbsG,
                                fat: detail.fatG
                            )
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
                        .padding(.top, 12)
                        .padding(.bottom, 28)
                    } else if let seed {
                        // The timeline's card data renders in the first frame;
                        // only the breakdown below it waits for the fetch.
                        VStack(alignment: .leading, spacing: Design.Space.section) {
                            photo(seed.imageURL)
                            summary(
                                title: seed.summary,
                                createdAt: seed.createdAt,
                                calories: seed.caloriesKcal,
                                protein: seed.proteinG,
                                carbs: seed.carbsG,
                                fat: seed.fatG
                            )
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
                        .padding(.top, 12)
                        .padding(.bottom, 28)
                    } else if isLoading {
                        loadingView
                    } else {
                        errorView
                    }
                }
                .refreshable { await load() }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if detail != nil || seed != nil {
                MealFixBar(question: question, onSubmit: onCorrectionSubmit, onAccepted: returnToSelectedDay)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Perf.mark("detail.appear")
            // The fix bar is this page's bottom; the shell's band steps aside.
            setShellBandSuppressed(true)
        }
        .onDisappear { setShellBandSuppressed(false) }
        .task {
            guard loadsRemotely else { return }
            await load()
        }
    }

    // MARK: Summary

    /// Title and time, then one hero number and a quiet line of macros.
    private func summary(
        title: String,
        createdAt: Date,
        calories: Double,
        protein: Double,
        carbs: Double,
        fat: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xl) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Design.Typeface.display(.title, weight: .regular))
                    .foregroundStyle(Design.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(createdAt, style: .time)
                    .font(Design.Typeface.numeral(.subheadline, weight: .regular))
                    .foregroundStyle(Design.Color.textTertiary)
            }

            VStack(alignment: .leading, spacing: Design.Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(calories.rounded()))")
                        .font(.custom(Design.Typeface.faceName(.light), size: calorieFontSize))
                        .monospacedDigit()
                        .foregroundStyle(Design.Color.macroKcal)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("kcal")
                        .font(Design.Typeface.text(.title3))
                        .foregroundStyle(Design.Color.textTertiary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Int(calories.rounded())) kilocalories")

                macroRow(protein: protein, carbs: carbs, fat: fat)
            }
        }
    }

    @ViewBuilder
    private func macroRow(protein: Double, carbs: Double, fat: Double) -> some View {
        if EntryDetailLayoutPolicy.stacksMacroCards(for: dynamicTypeSize) {
            VStack(alignment: .leading, spacing: 8) {
                macroValue("protein", protein, Design.Color.macroProtein)
                macroValue("carbs", carbs, Design.Color.macroCarbs)
                macroValue("fat", fat, Design.Color.macroFat)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.xl) {
                macroValue("protein", protein, Design.Color.macroProtein)
                macroValue("carbs", carbs, Design.Color.macroCarbs)
                macroValue("fat", fat, Design.Color.macroFat)
            }
        }
    }

    /// "54 g protein": the number in hinoki, the word in its macro's pigment.
    private func macroValue(_ label: String, _ value: Double, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(Int(value.rounded())) g")
                .font(Design.Typeface.numeral(.body, weight: .medium))
                .foregroundStyle(Design.Color.textPrimary)
            Text(label)
                .font(Design.Typeface.text(.subheadline))
                .foregroundStyle(color)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label.capitalized), \(Int(value.rounded())) grams")
    }

    // MARK: Breakdown

    /// What's in it: one quiet row per item, no header and no rules — the
    /// spacing groups them.
    private func breakdown(_ items: [SupabaseService.EntryDetailItem]) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.l) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                itemRow(item)
            }
        }
        .transition(.ink(reduceMotion: reduceMotion))
    }

    private func itemRow(_ item: SupabaseService.EntryDetailItem) -> some View {
        let amount = item.amount.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(Design.Typeface.text(.body))
                    .foregroundStyle(Design.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(itemDetail(amount: amount, item: item))
                    .font(Design.Typeface.numeral(.footnote, weight: .regular))
                    .foregroundStyle(Design.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(Int(item.caloriesKcal.rounded()))")
                .font(Design.Typeface.numeral(.body, weight: .regular))
                .foregroundStyle(Design.Color.textSecondary)
        }
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
                .font(Design.Typeface.text(.footnote))
                .foregroundStyle(Design.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Try again") { Task { await load() } }
                .font(Design.Typeface.text(.footnote, weight: .semibold))
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
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.cardLarge, style: .continuous))
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
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.cardLarge, style: .continuous))
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
            RoundedRectangle(cornerRadius: Design.Radius.cardLarge).fill(Design.Color.surface1).frame(height: 260)
            Capsule().fill(Design.Color.surface1).frame(width: 190, height: 16)
            Capsule().fill(Design.Color.surface1).frame(width: 120, height: 40)
        }
        .padding(20)
        .shimmering()
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Text(errorMessage ?? "This meal couldn’t be loaded.")
                .font(Design.Typeface.text(.subheadline))
                .foregroundStyle(Design.Color.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await load() } }
                .font(Design.Typeface.text(.subheadline, weight: .semibold))
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

/// The meal's fix bar: the capture bar's shape at the bottom of the meal —
/// Shudo's spot bottom-left (tap to record, tap again to send), the field
/// beside it. The estimator's question, if any, is the placeholder; an
/// answer goes out as "Q: … A: …". Sending hands the correction to the
/// Today screen (VM-owned, idempotent by `clientRequestId`) and goes back
/// to the day, where the card shows the update.
private struct MealFixBar: View {
    let question: String?
    let onSubmit: (EntryCorrectionSubmission) -> Void
    let onAccepted: () -> Void

    /// Held unobserved: the bar observes it.
    @StateObject private var voiceHolder = UnobservedHolder(VoiceTranscriber(profile: .correction))
    @State private var text = ""
    @State private var hasLiveDictation = false
    @State private var dictatedTakeCount = 0
    @State private var dictatedEngine: SpeechEngineID?
    @State private var hasSubmitted = false
    @State private var errorMessage: String?
    @State private var clientRequestId = UUID()

    private var voice: VoiceTranscriber { voiceHolder.value }

    private var canSubmit: Bool {
        EntryCorrectionPolicy.canSubmit(
            text: text,
            hasLiveDictation: hasLiveDictation,
            hasImage: false,
            isPreparingImage: false,
            isSubmitting: hasSubmitted
        )
    }

    var body: some View {
        SheetCaptureBar(
            voice: voice,
            text: $text,
            placeholder: question ?? "Anything off? Say what changed",
            canSend: false,
            isSendEnabled: canSubmit,
            isSending: hasSubmitted,
            sendLabel: "Update meal",
            message: errorMessage,
            identifierPrefix: "correction",
            onWillRecord: { errorMessage = nil },
            onSend: submit,
            onTake: appendTake
        )
        .onChange(of: text) { _, updated in
            if updated.count > EntryCorrectionPolicy.maximumCharacters {
                text = EntryCorrectionPolicy.normalized(updated)
            }
        }
        .onReceive(voice.$phase) { phase in
            if hasLiveDictation != phase.holdsTake { hasLiveDictation = phase.holdsTake }
        }
        .onDisappear {
            if !hasSubmitted { voice.cancel() }
        }
    }

    private func appendTake(_ take: VoiceTake) {
        let result = DictationMergePolicy.appending(
            take.text,
            to: text,
            limit: EntryCorrectionPolicy.maximumCharacters
        )
        if result.wasTruncated { errorMessage = VoiceCopy.reachedLengthLimit }
        guard result.record != nil else { return }
        text = result.note
        dictatedTakeCount += 1
        dictatedEngine = take.engine
    }

    /// Luke's words, prefixed with the question when there is one.
    private func submissionText() -> String? {
        let answer = EntryCorrectionPolicy.normalized(text)
        guard !answer.isEmpty else { return nil }
        guard let question else { return answer }
        return EntryCorrectionPolicy.normalized(ClarificationPolicy.answerPrefill(for: question) + answer)
    }

    /// Finishes any take in flight, hands the correction off and goes back
    /// to the day right away; the update runs on the meal card.
    private func submit() {
        guard canSubmit else {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            return
        }
        errorMessage = nil
        hasSubmitted = true
        Task {
            let hadTake = voice.hasTakeInFlight
            if let take = await voice.finishPendingTake(finalizationTimeout: 1.5) {
                appendTake(take)
            } else if hadTake, voice.errorMessage != nil {
                // Transcription failed: stay, so the bar can retry or discard.
                hasSubmitted = false
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            guard let words = submissionText() else {
                hasSubmitted = false
                errorMessage = VoiceCopy.didNotCatchThat
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            onSubmit(EntryCorrectionSubmission(
                text: words,
                speechEngine: dictatedTakeCount > 0 ? dictatedEngine : nil,
                imageJPEG: nil,
                clientRequestId: clientRequestId
            ))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            UIAccessibility.post(notification: .announcement, argument: "Updating meal")
            onAccepted()
        }
    }
}
