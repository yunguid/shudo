import PhotosUI
import SwiftUI
import UIKit

/// What the composer hands to the Today screen: text only (a recording was
/// already transcribed into the note), which engine produced any dictated
/// words, the photo, and the idempotency key reused on every retry.
struct EntryCaptureDraft: Equatable {
    let text: String?
    let speechEngine: SpeechEngineID?
    let imageJPEG: Data?
    let clientRequestId: UUID
}

enum EntryComposerPolicy {
    static let maximumNoteLength = 12_000

    static let maximumScannedItems = 4

    /// `hasLiveDictation`: a take is recording or transcribing; submitting
    /// finishes it (stop → transcribe) and sends its words.
    static func canSubmit(
        isSubmitting: Bool,
        isPreparingImage: Bool,
        hasLiveDictation: Bool = false,
        hasImage: Bool,
        hasScannedFood: Bool,
        note: String
    ) -> Bool {
        !isSubmitting
            && !isPreparingImage
            && note.utf16.count <= maximumNoteLength
            && (hasLiveDictation
                || hasImage
                || hasScannedFood
                || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    static func boundedNote(_ note: String) -> String {
        guard note.utf16.count > maximumNoteLength else { return note }
        let utf16 = note.utf16
        var end = utf16.index(utf16.startIndex, offsetBy: maximumNoteLength)
        while String.Index(end, within: note) == nil {
            end = utf16.index(before: end)
        }
        guard let stringEnd = String.Index(end, within: note) else { return "" }
        return String(note[..<stringEnd])
    }

}

struct EntryComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Owned by the shell and deliberately not observed here: the bottom
    /// bar observes it, and this view mirrors only whether a take is in
    /// flight, so meter updates never re-render the photos above.
    private let voice: VoiceTranscriber
    @State private var hasLiveDictation = false
    @State private var dictatedTakeCount = 0
    @State private var dictatedEngine: SpeechEngineID?

    @State private var note = ""
    @State private var pickedImages: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []
    @State private var isShowingCamera = false
    @State private var isShowingPhotoPicker = false
    @State private var isShowingBarcodeScanner = false
    @State private var scannedPortions: [ScannedPortion] = []
    @State private var isPreparingImage = false
    @State private var imageLoadGeneration = UUID()
    @State private var imagePreparationTask: Task<Void, Never>?
    @State private var uploadEncodeTask: Task<Data?, Never>?
    @State private var isSubmitting = false
    @State private var localError: String?
    @State private var didAutoStart = false
    @State private var clientRequestId = UUID()
    /// Fitted to its content with nothing attached (one question, the
    /// chips, the bar under the thumb); the full sheet once there's a photo
    /// or a label to look at.
    @State private var isExpanded: Bool
    @State private var headingIn = false
    /// Header, a breath, chips and bar — scaled with the text size.
    @ScaledMetric(relativeTo: .title) private var compactHeight: CGFloat = 262

    let selectedDay: Date
    let timezone: String
    let autoStartRecording: Bool
    /// The capture bar's "Scan barcode": open the scanner once the sheet is up.
    let opensBarcodeScannerOnAppear: Bool
    @State private var didOpenScanner = false
    /// Hands the composed meal to the owner and returns immediately — the
    /// upload runs on the Today screen's card, so this sheet never holds the
    /// user through the network round trip.
    let onSubmit: (EntryCaptureDraft) -> Void
    /// Nil for today (the usual case says nothing).
    private let dayText: String?

    init(
        selectedDay: Date,
        timezone: String,
        autoStartRecording: Bool = false,
        voice: VoiceTranscriber,
        initialImages: [UIImage] = [],
        opensBarcodeScannerOnAppear: Bool = false,
        onSubmit: @escaping (EntryCaptureDraft) -> Void
    ) {
        self.selectedDay = selectedDay
        self.timezone = timezone
        self.autoStartRecording = autoStartRecording
        self.opensBarcodeScannerOnAppear = opensBarcodeScannerOnAppear
        self.voice = voice
        _images = State(initialValue: initialImages)
        _isExpanded = State(initialValue: !initialImages.isEmpty)
        self.onSubmit = onSubmit
        dayText = Self.dayLabelText(selectedDay: selectedDay, timezone: timezone)
    }

    private var canSubmit: Bool {
        EntryComposerPolicy.canSubmit(
            isSubmitting: isSubmitting,
            isPreparingImage: isPreparingImage,
            hasLiveDictation: hasLiveDictation,
            hasImage: !images.isEmpty,
            hasScannedFood: !scannedPortions.isEmpty,
            note: note
        )
    }

    private var hasAttachments: Bool { !images.isEmpty || !scannedPortions.isEmpty }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 12) {
                        photoGrid
                        scannedFoodSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls }
        .presentationDetents([compactDetent, .large], selection: detentSelection)
        .presentationBackgroundInteraction(.disabled)
        .onChange(of: hasAttachments || isPreparingImage) { _, attached in
            guard attached, !isExpanded else { return }
            withAnimation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion)) { isExpanded = true }
        }
        .preferredColorScheme(.dark)
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
        .sheet(isPresented: $isShowingBarcodeScanner) {
            BarcodeScannerSheet { product in
                appendScannedProduct(product)
            }
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(Design.Radius.sheet)
        }
        .onChange(of: pickedImages) { _, items in preparePickedImages(items) }
        .onChange(of: isShowingPhotoPicker) { wasPresented, isPresented in
            guard wasPresented, !isPresented else { return }
            CaptureDiagnostics.record(.photoPickerDismissed, state: voice.controlState)
        }
        .onChange(of: images) { _, updated in prepareUploadEncoding(for: updated) }
        .onChange(of: note) { _, value in
            let bounded = EntryComposerPolicy.boundedNote(value)
            if bounded != value { note = bounded }
        }
        .onReceive(voice.$phase) { phase in
            if hasLiveDictation != phase.holdsTake { hasLiveDictation = phase.holdsTake }
        }
        .onAppear {
            Perf.mark("composer.appear")
            CaptureDiagnostics.record(.composerPresented, state: voice.controlState)
            // Build the camera controller after the sheet settles so a later
            // "Camera" tap presents instantly instead of paying the picker's
            // multi-second first-build on the tap itself.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                CameraPrewarmer.prewarm()
            }
            if opensBarcodeScannerOnAppear, !didOpenScanner {
                didOpenScanner = true
                Task { @MainActor in
                    // Present over the settled sheet, not mid-animation.
                    try? await Task.sleep(for: .milliseconds(450))
                    isShowingBarcodeScanner = true
                }
            }
        }
        .task {
            guard autoStartRecording, !didAutoStart else { return }
            didAutoStart = true
            // Normally the warm-up starts at the tap so it overlaps this
            // sheet's presentation; this covers presentations where that
            // start couldn't run, without double-starting or retrying a
            // start that already failed.
            guard voice.phase == .idle else { return }
            await voice.start()
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private var compactDetent: PresentationDetent { .height(min(compactHeight, 420)) }

    private var detentSelection: Binding<PresentationDetent> {
        Binding(
            get: { isExpanded ? .large : compactDetent },
            set: { isExpanded = $0 == .large }
        )
    }

    // MARK: Header

    /// One question, in the serif, with room around it. A meal for another
    /// day says which day under it.
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What did you eat?")
                    .font(Design.Typeface.display(.title, weight: .regular))
                    .foregroundStyle(Design.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("meal.heading")
                if let dayText {
                    Text("For \(dayText)")
                        .font(Design.Typeface.text(.subheadline))
                        .foregroundStyle(Design.Color.textTertiary)
                        .accessibilityLabel("Logging for \(dayText)")
                }
            }
            .opacity(headingIn ? 1 : 0)
            .offset(y: headingIn || reduceMotion ? 0 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.custom(Design.Typeface.faceName(.bold), fixedSize: 13))
                    .fontWeight(.semibold)
                    .foregroundStyle(Design.Color.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Design.Color.hinoki.opacity(0.08), in: Circle())
                    .contentShape(Circle().inset(by: -8))
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("meal.close")
        }
        .padding(.leading, 24)
        .padding(.trailing, 18)
        .padding(.top, 30)
        .onAppear {
            withAnimation(Design.Motion.calm(Design.Motion.arrive, reduceMotion: reduceMotion).delay(reduceMotion ? 0 : 0.12)) {
                headingIn = true
            }
        }
    }

    // MARK: Bottom: attach row + the capture bar's shape

    /// Everything Luke taps sits at the bottom, under his thumb: what to
    /// attach, then the bar (mic bottom-left, note, send).
    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            attachRow
                .padding(.horizontal, 16)
            SheetCaptureBar(
                voice: voice,
                text: $note,
                placeholder: hasAttachments ? "Add a note…" : "Say it or type it…",
                canSend: hasAttachments,
                isSendEnabled: canSubmit,
                isSending: isSubmitting,
                sendLabel: "Log meal",
                message: localError,
                identifierPrefix: "meal",
                onWillRecord: { localError = nil },
                onSend: submit,
                onTake: appendTake
            )
        }
        .padding(.top, 8)
    }

    /// Left-aligned under the thumb, each sized to its word.
    private var attachRow: some View {
        HStack(spacing: 8) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                attachButton("Camera", systemImage: "camera.fill", enabled: canAddPhoto) {
                    Perf.mark("camera.tap")
                    settleVoiceCapture()
                    isShowingCamera = true
                }
            }
            attachButton("Photos", systemImage: "photo.on.rectangle", enabled: canAddPhoto) {
                settleVoiceCapture()
                CaptureDiagnostics.record(.photoPickerPresented, state: voice.controlState)
                isShowingPhotoPicker = true
            }
            // A scan adds a removable label card; it doesn't use a photo slot.
            attachButton(
                "Scan",
                systemImage: "barcode.viewfinder",
                enabled: !isSubmitting && scannedPortions.count < EntryComposerPolicy.maximumScannedItems
            ) {
                settleVoiceCapture()
                isShowingBarcodeScanner = true
            }
        }
    }

    private var canAddPhoto: Bool {
        !isSubmitting && !isPreparingImage && images.count < ImageProcessor.maximumPhotoCount
    }

    private func attachButton(
        _ title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Design.Typeface.text(.subheadline, weight: .medium))
                .foregroundStyle(enabled ? Design.Color.textSecondary : Design.Color.textDisabled)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: 38)
                .background(Design.Color.hinoki.opacity(0.06), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Content

    @ViewBuilder
    private var photoGrid: some View {
        if !images.isEmpty || isPreparingImage {
            LazyVGrid(
                columns: images.count <= 1
                    ? [GridItem(.flexible())]
                    : [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 8
            ) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    ZStack(alignment: .topTrailing) {
                        // The slot sets the size; the photo fills it. (A
                        // scaled-to-fill image on its own reports its full
                        // ideal width and pushes the grid past the screen.)
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: images.count == 1 ? 300 : 150)
                            .overlay {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.cardLarge, style: .continuous))
                            // clipShape crops drawing but NOT hit testing: a
                            // portrait photo scaled to fill this slot stays
                            // taller for touch purposes and would eat taps
                            // meant for the controls around the grid.
                            .allowsHitTesting(false)

                        Button {
                            removePhoto(at: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.custom(Design.Typeface.faceName(.bold), fixedSize: 12))
                                .fontWeight(.semibold)
                                .foregroundStyle(Design.Color.textPrimary)
                                .frame(width: 30, height: 30)
                                .background(Design.Color.canvas.opacity(0.62), in: Circle())
                                .contentShape(Circle().inset(by: -6))
                        }
                        .padding(8)
                        .disabled(isSubmitting)
                        .accessibilityLabel("Remove photo \(index + 1)")
                    }
                }
                if isPreparingImage {
                    RoundedRectangle(cornerRadius: Design.Radius.cardLarge, style: .continuous)
                        .fill(Design.Color.surface1)
                        .frame(height: images.isEmpty ? 300 : 150)
                        .shimmering()
                        .accessibilityLabel("Adding photo")
                }
            }
        }
    }

    /// Nil for today; otherwise the day this meal lands on.
    static func dayLabelText(selectedDay: Date, timezone: String) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        if calendar.isDateInToday(selectedDay) { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: selectedDay)
    }

    /// Ends dictation before another surface takes the audio hardware: the
    /// microphone is released right away and the words land in the note
    /// when the transcription arrives; an in-flight warm-up is aborted,
    /// since a start finishing underneath the camera gets killed by its
    /// capture session.
    private func settleVoiceCapture() {
        voice.finishInBackground()
    }

    private func appendTake(_ take: VoiceTake) {
        let result = DictationMergePolicy.appending(
            take.text,
            to: note,
            limit: EntryComposerPolicy.maximumNoteLength
        )
        if result.wasTruncated { localError = VoiceCopy.reachedLengthLimit }
        guard result.record != nil else { return }
        note = result.note
        dictatedTakeCount += 1
        dictatedEngine = take.engine
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

        Perf.mark("photo.prepare.begin")
        isPreparingImage = true
        localError = nil
        let availableSlots = max(0, ImageProcessor.maximumPhotoCount - images.count)
        let selectedItems = Array(items.prefix(availableSlots))
        imagePreparationTask = Task.detached(priority: .userInitiated) {
            // Loading and downsampling two photos at a time keeps several large
            // library photos fast without holding every original in memory.
            let loaded = await BoundedConcurrency.map(
                selectedItems,
                maximumConcurrentTasks: 2
            ) { item -> UIImage? in
                guard !Task.isCancelled,
                      let data = try? await item.loadTransferable(type: Data.self),
                      !Task.isCancelled else { return nil }
                return ImageProcessor.downsample(data: data)
            }
            let preparedImages = loaded.compactMap { $0 }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard imageLoadGeneration == generation else { return }
                imagePreparationTask = nil
                isPreparingImage = false
                pickedImages = []
                guard !preparedImages.isEmpty else {
                    localError = "Those photos couldn’t be loaded."
                    return
                }
                let remainingSlots = max(0, ImageProcessor.maximumPhotoCount - images.count)
                animated {
                    images.append(contentsOf: preparedImages.prefix(remainingSlots))
                }
                Perf.mark("photo.thumbs.visible")
                CaptureDiagnostics.record(.photosPrepared, state: voice.controlState)
                localError = preparedImages.count < selectedItems.count
                    ? "Some photos couldn’t be loaded."
                    : nil
            }
        }
    }

    private func prepareCameraImage(_ captured: UIImage) {
        guard images.count < ImageProcessor.maximumPhotoCount else { return }
        // Downsample the full-resolution camera frame before keeping it so the
        // composer never retains multi-hundred-megapixel-second originals.
        isPreparingImage = true
        localError = nil
        let generation = imageLoadGeneration
        Task.detached(priority: .userInitiated) {
            let prepared = ImageProcessor.resizedForUpload(captured)
            await MainActor.run {
                guard imageLoadGeneration == generation else { return }
                isPreparingImage = false
                guard images.count < ImageProcessor.maximumPhotoCount else { return }
                animated { images.append(prepared) }
            }
        }
    }

    /// Re-encodes the upload JPEG in the background whenever the photo set
    /// changes, so tapping "Log meal" never renders or encodes on the tap.
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

    @ViewBuilder
    private var scannedFoodSection: some View {
        if !scannedPortions.isEmpty {
            VStack(spacing: 10) {
                ForEach($scannedPortions) { $portion in
                    ScannedFoodCard(
                        portion: $portion,
                        isDisabled: isSubmitting,
                        onRemove: { removeScannedPortion(id: portion.id) }
                    )
                    .transition(.ink(reduceMotion: reduceMotion))
                }
            }
        }
    }

    private func appendScannedProduct(_ product: ScannedProduct) {
        guard scannedPortions.count < EntryComposerPolicy.maximumScannedItems else { return }
        localError = nil
        animated {
            scannedPortions.append(ScannedPortion(product: product))
        }
    }

    private func removeScannedPortion(id: UUID) {
        animated {
            scannedPortions.removeAll { $0.id == id }
        }
    }

    private func removePhoto(at offset: Int) {
        guard images.indices.contains(offset) else { return }
        animated {
            let index = images.index(images.startIndex, offsetBy: offset)
            images.remove(at: index)
        }
    }

    /// Honors Reduce Motion: state changes land without the spring when the
    /// user asked the system for less movement.
    private func animated(_ body: () -> Void) {
        if reduceMotion {
            body()
        } else {
            withAnimation(Design.Motion.arrive, body)
        }
    }

    private func submit() {
        guard canSubmit else {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            return
        }
        Perf.mark("entry.submit.tap")
        let hasSelectedImages = !images.isEmpty
        let selectedImages = images
        let encodeTask = uploadEncodeTask

        isSubmitting = true
        localError = nil
        Task {
            // A recording still in flight is stopped and transcribed first
            // (or a failed upload retried once) and lands in the note like
            // any other take — Log while recording is stop → transcribe →
            // send in one go.
            let hadTake = voice.hasTakeInFlight
            if let take = await voice.finishPendingTake(finalizationTimeout: 1.5) {
                appendTake(take)
            } else if hadTake, voice.errorMessage != nil {
                // The transcription failed: keep the sheet (and a kept
                // recording, which the bar offers to retry or discard)
                // instead of sending without Luke's words.
                isSubmitting = false
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }

            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            // The user's own words lead; scanned label facts follow so the
            // first line stays a natural meal title and the model reads the
            // labels as supporting facts.
            let scanText = BarcodeNutrition.submissionText(for: scannedPortions)
            let combined = [trimmed, scanText]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let text = combined.isEmpty
                ? nil
                : EntryComposerPolicy.boundedNote(combined)
            guard text != nil || hasSelectedImages else {
                isSubmitting = false
                localError = VoiceCopy.didNotCatchThat
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }

            // The upload JPEG is normally ready before the tap; otherwise wait
            // for the in-flight background encode instead of re-rendering here.
            var imageJPEG = await encodeTask?.value
            if hasSelectedImages && imageJPEG == nil {
                imageJPEG = await Task.detached(priority: .userInitiated) {
                    ImageProcessor.uploadJPEGData(from: selectedImages)
                }.value
            }
            if hasSelectedImages && imageJPEG == nil {
                isSubmitting = false
                localError = "Those photos couldn’t be prepared. Remove them and try again."
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            // Locally accepted: the Today screen owns the upload from here
            // (its card shows progress and any retryable failure), so the
            // sheet closes now instead of holding through the network round
            // trip.
            onSubmit(EntryCaptureDraft(
                text: text,
                speechEngine: text != nil && dictatedTakeCount > 0 ? dictatedEngine : nil,
                imageJPEG: imageJPEG,
                clientRequestId: clientRequestId
            ))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            isSubmitting = false
            dismiss()
        }
    }

}

/// A scanned packaged food shown as a removable card: the label's macros
/// (scaled live by the chosen amount), the serving context, and an amount
/// stepper. The card is a proposal — the person can adjust or reject it
/// without touching their note, photos, or voice recording.
private struct ScannedFoodCard: View {
    @Binding var portion: ScannedPortion
    let isDisabled: Bool
    let onRemove: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    macroSummary
                    Spacer(minLength: 0)
                    stepper
                }
                VStack(alignment: .leading, spacing: 12) {
                    macroSummary
                    stepper
                }
            }
        }
        .padding(16)
        .cardSurface()
        .opacity(isDisabled ? 0.6 : 1)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(portion.product.name)
                    .font(Design.Typeface.text(.subheadline, weight: .semibold))
                    .foregroundStyle(Design.Color.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = headerDetail {
                    Text(detail)
                        .font(Design.Typeface.text(.caption))
                        .foregroundStyle(Design.Color.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.custom(Design.Typeface.faceName(.bold), fixedSize: 12))
                    .fontWeight(.semibold)
                    .foregroundStyle(Design.Color.muted)
                    .frame(width: 30, height: 30)
                    .background(Design.Color.surface2, in: Circle())
                    .contentShape(Circle().inset(by: -7))
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel("Remove \(portion.product.name)")
        }
    }

    private var headerDetail: String? {
        // The amount row already speaks in servings, so the detail line only
        // carries the brand and what one serving is.
        let serving = portion.product.usesServingUnits
            ? portion.product.servingSize
            : "per 100 g"
        return [portion.product.brands, serving]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty
    }

    @ViewBuilder
    private var macroSummary: some View {
        if let macros = portion.scaledMacros {
            VStack(alignment: .leading, spacing: 4) {
                calorieText(macros)
                HStack(spacing: 10) { macroChips(macros) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityMacroSummary(macros))
        }
    }

    private func calorieText(_ macros: ScannedProduct.Macros) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(macros.caloriesKcal.map { BarcodeNutrition.compactAmount($0) } ?? "—")
                .font(Design.Typeface.numeral(.title3))
                .foregroundStyle(Design.Color.ink)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
            Text("kcal")
                .font(Design.Typeface.text(.caption2))
                .foregroundStyle(Design.Color.muted)
        }
    }

    @ViewBuilder
    private func macroChips(_ macros: ScannedProduct.Macros) -> some View {
        macroChip("P", macros.proteinG, Design.Color.ringProtein)
        macroChip("C", macros.carbsG, Design.Color.ringCarb)
        macroChip("F", macros.fatG, Design.Color.ringFat)
    }

    @ViewBuilder
    private func macroChip(_ label: String, _ value: Double?, _ color: Color) -> some View {
        if let value {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text("\(label) \(BarcodeNutrition.compactAmount(value))g")
                    .font(Design.Typeface.numeral(.caption2, weight: .regular))
                    .foregroundStyle(Design.Color.muted)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
        }
    }

    private var stepper: some View {
        HStack(spacing: 8) {
            stepButton(systemImage: "minus", enabled: canDecrement) {
                adjustQuantity(by: -ScannedPortion.quantityStep)
            }
            .accessibilityHidden(true)

            Text(portion.quantityLabel)
                .font(Design.Typeface.numeral(.subheadline, weight: .semibold))
                .foregroundStyle(Design.Color.ink)
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText())
                .frame(minWidth: 80)
                .accessibilityLabel("Amount")
                .accessibilityValue(portion.quantityLabel)
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment:
                        adjustQuantity(by: ScannedPortion.quantityStep)
                    case .decrement:
                        adjustQuantity(by: -ScannedPortion.quantityStep)
                    @unknown default:
                        break
                    }
                }

            stepButton(systemImage: "plus", enabled: canIncrement) {
                adjustQuantity(by: ScannedPortion.quantityStep)
            }
            .accessibilityHidden(true)
        }
    }

    private var canDecrement: Bool {
        !isDisabled && portion.quantity > ScannedPortion.minimumQuantity
    }

    private var canIncrement: Bool {
        !isDisabled && portion.quantity < ScannedPortion.maximumQuantity
    }

    private func stepButton(
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.custom(Design.Typeface.faceName(.bold), fixedSize: 13))
                .fontWeight(.semibold)
                .foregroundStyle(enabled ? Design.Color.ink : Design.Color.subtle)
                .frame(width: 34, height: 34)
                .background(Design.Color.surface2, in: Circle())
                .contentShape(Circle().inset(by: -5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func adjustQuantity(by delta: Double) {
        let updated = min(
            ScannedPortion.maximumQuantity,
            max(ScannedPortion.minimumQuantity, portion.quantity + delta)
        )
        guard updated != portion.quantity else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        if reduceMotion {
            portion.quantity = updated
        } else {
            withAnimation(.snappy(duration: 0.18)) {
                portion.quantity = updated
            }
        }
    }

    private func accessibilityMacroSummary(_ macros: ScannedProduct.Macros) -> String {
        var parts: [String] = []
        if let kcal = macros.caloriesKcal {
            parts.append("\(BarcodeNutrition.compactAmount(kcal)) kilocalories")
        }
        if let protein = macros.proteinG {
            parts.append("protein \(BarcodeNutrition.compactAmount(protein)) grams")
        }
        if let carbs = macros.carbsG {
            parts.append("carbs \(BarcodeNutrition.compactAmount(carbs)) grams")
        }
        if let fat = macros.fatG {
            parts.append("fat \(BarcodeNutrition.compactAmount(fat)) grams")
        }
        return parts.joined(separator: ", ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
