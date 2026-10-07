import AVFoundation
import Speech
import SwiftUI
import UIKit

/// The morning check-in, photo first and weight optional (no scale yet):
/// camera → review (pose, optional weight by voice or keypad, optional note)
/// → save. `.weight` opens straight on the weight entry for "Add weight"
/// later the same day; that save omits every photo key, so the morning photo
/// stays untouched, and a photo-only save omits `weight_kg` so an earlier
/// weight survives. Replaces the 1.x weigh-in sheet.
struct BodyCheckInFlow: View {
    enum Start: Equatable {
        case camera
        case weight
    }

    private enum Step: Equatable {
        case camera
        case review
        case weight
    }

    let localDay: String
    let units: String
    let existing: WeightCheckIn?
    let service: any BodyServicing
    let photoLoader: BodyPhotoLoader?
    let ghostPath: String?
    let updatesProfileWeight: Bool
    let onSaved: (WeightCheckIn) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// On-device dictation for the spoken weight. Held unobserved so the
    /// ~16 Hz meter ticks never re-render the photo and form; the flow
    /// mirrors only the phase it needs.
    @StateObject private var voiceHolder: UnobservedHolder<VoiceTranscriber>
    @State private var voicePhase: VoiceTranscriber.Phase = .idle
    @State private var step: Step
    @State private var capture: PhysiqueCapture?
    @State private var ghost: UIImage?
    @State private var pose: PhysiquePose
    @State private var weightText: String
    @State private var note: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedCount = 0
    @FocusState private var weightFocused: Bool
    @FocusState private var noteFocused: Bool

    /// - Parameters:
    ///   - localDay: the `yyyy-MM-dd` day being checked in (usually today).
    ///   - existing: that day's row if one exists (photo and/or weight).
    ///   - start: `.camera` for the ritual / retake, `.weight` for "Add weight".
    ///   - ghostPath: storage path of the previous photo for the 30% overlay.
    ///   - onSaved: called after a successful save (the shell triggers coach sync).
    init(
        localDay: String,
        units: String,
        existing: WeightCheckIn?,
        start: Start = .camera,
        ghostPath: String? = nil,
        service: any BodyServicing = LiveBodyService(),
        photoLoader: BodyPhotoLoader? = nil,
        updatesProfileWeight: Bool = true,
        onSaved: @escaping (WeightCheckIn) -> Void
    ) {
        self.localDay = localDay
        self.units = units
        self.existing = existing
        self.service = service
        self.photoLoader = photoLoader
        self.ghostPath = ghostPath ?? existing?.progressPhotoPath
        self.updatesProfileWeight = updatesProfileWeight
        self.onSaved = onSaved
        _voiceHolder = StateObject(wrappedValue: UnobservedHolder(Self.makeVoice(units: units)))
        _step = State(initialValue: start == .weight ? .weight : .camera)
        let pose = existing?.photoPose ?? .frontRelaxed
        _pose = State(initialValue: pose == .front ? .frontRelaxed : pose)
        _note = State(initialValue: existing?.note ?? "")
        let shown = existing?.weightKG.map { WeightCheckInPolicy.displayedValue(kilograms: $0, units: units) }
        _weightText = State(initialValue: shown.map { String(format: "%.1f", $0) } ?? "")
    }

    #if DEBUG
        /// Previews/screenshots: open on the review step with a captured image.
        init(previewCapture image: UIImage, localDay: String, units: String, service: any BodyServicing) {
            self.init(localDay: localDay, units: units, existing: nil, service: service) { _ in }
            _step = State(initialValue: .review)
            _capture = State(initialValue: PhysiqueCapture(image: image, capturedAt: Date(), fromLibrary: false))
        }
    #endif

    /// A weigh-in transcriber that ends the take by itself once a plausible
    /// weight has been heard and held (`VoiceProfile.weighIn`'s stable
    /// interval), so "one eighty two point four" needs no Stop tap.
    @MainActor
    static func makeVoice(units: String, environment: VoiceEnvironment? = nil) -> VoiceTranscriber {
        let voice = VoiceTranscriber(profile: .weighIn, environment: environment)
        voice.autoStopCondition = autoStopCondition(units: units)
        return voice
    }

    static func autoStopCondition(units: String) -> (LiveTranscript) -> Bool {
        { WeightUtterancePolicy.parsedWeight(transcript: $0.displayText, units: units) != nil }
    }

    private var voice: VoiceTranscriber { voiceHolder.value }

    /// Starting, listening, or finishing a take — the Stop affordances show.
    private var isCapturing: Bool {
        switch voicePhase {
        case .starting, .listening, .finishing: return true
        default: return false
        }
    }

    private var unitLabel: String { BodyUnits.label(units) }

    private var weightKG: Double? {
        guard let value = Double(weightText.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return WeightCheckInPolicy.kilograms(from: value, units: units)
    }

    private var weightIsInvalid: Bool {
        !weightText.trimmingCharacters(in: .whitespaces).isEmpty && weightKG == nil
    }

    var body: some View {
        Group {
            switch step {
            case .camera:
                PhysiqueCameraView(
                    ghost: ghost,
                    onCapture: { captured in
                        capture = captured
                        withAnimation(Design.Motion.gated(Design.Motion.settle, reduceMotion: reduceMotion)) {
                            step = .review
                        }
                    },
                    onSkipPhoto: capture == nil && existing?.hasPhoto != true
                        ? { withAnimation { step = .weight } } : nil,
                    onCancel: {
                        if capture != nil { step = .review } else { dismiss() }
                    }
                )
            case .review, .weight:
                entryScreen
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadGhost() }
        .onReceive(voice.$phase) { phase in
            if voicePhase != phase { voicePhase = phase }
        }
        .onReceive(voice.$transcript) { transcript in
            // The parsed weight shows live while Luke speaks.
            guard voice.isListening || voice.isFinishing else { return }
            applySpokenWeight(transcript.displayText)
        }
        .onChange(of: voicePhase) { _, phase in
            // A take that ended by itself (auto-stop once the weight held,
            // an interruption) is parked; its final text wins.
            if phase == .ready, let take = voice.collectReadyTake() {
                applySpokenWeight(take.text)
            }
        }
        // Typing takes over: drop the take so a late final pass can't
        // overwrite the keypad. The live-parsed value stays in the field.
        .onChange(of: weightFocused) { _, focused in if focused { voice.cancel() } }
        .onDisappear { voice.cancel() }
        .sensoryFeedback(.success, trigger: savedCount)
        .interactiveDismissDisabled(isSaving)
    }

    // MARK: Review / weight entry

    private var entryScreen: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if step == .review { photoBlock }
                    weightBlock
                    if step == .review { noteBlock }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(Design.Color.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Design.Color.canvas.ignoresSafeArea())
            .navigationTitle(step == .weight ? "Weigh-in" : "Check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(isSaving)
                }
                if step == .review {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Retake") {
                            voice.cancel()
                            step = .camera
                        }
                        .disabled(isSaving)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        weightFocused = false
                        noteFocused = false
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { saveBar }
        }
        .task(id: step) {
            // "Add weight" goes straight to voice, like the 1.x weigh-in —
            // once permission exists. A first-time user taps the mic, so the
            // sheet never opens onto a system prompt.
            guard step == .weight, existing?.weightKG == nil,
                SFSpeechRecognizer.authorizationStatus() == .authorized,
                AVAudioApplication.shared.recordPermission == .granted
            else { return }
            await startListening()
        }
    }

    private var photoBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = capture?.image {
                Color.clear
                    .frame(width: 285, height: 380)
                    .overlay {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel("Today's check-in photo")
            }
            Text("Pose").eyebrowStyle()
            HStack(spacing: 8) {
                ForEach([PhysiquePose.frontRelaxed, .frontFlexed, .side, .back]) { option in
                    Button {
                        pose = option
                    } label: {
                        Text(option.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(pose == option ? Design.Color.onEmber : Design.Color.textPrimary)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .background(
                                pose == option ? AnyShapeStyle(Design.Color.ember) : AnyShapeStyle(Design.Color.surface3),
                                in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(pose == option ? .isSelected : [])
                }
            }
        }
    }

    private var weightBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(step == .weight ? "Weight" : "Weight · optional").eyebrowStyle()
                Spacer()
                if isCapturing {
                    HStack(spacing: 6) {
                        Circle().fill(Design.Color.danger).frame(width: 7, height: 7)
                        Text(weightKG == nil ? "Listening — say your weight" : "Heard it")
                            .font(Design.Typeface.meta)
                            .foregroundStyle(Design.Color.textSecondary)
                    }
                    .transition(.opacity)
                } else if case .preparingModel(let progress) = voicePhase {
                    Text(VoiceCopy.preparing(progress: progress))
                        .font(Design.Typeface.meta)
                        .foregroundStyle(Design.Color.textTertiary)
                        .transition(.opacity)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("—", text: $weightText)
                    .keyboardType(.decimalPad)
                    .focused($weightFocused)
                    .font(Design.Typeface.numeral(.largeTitle, weight: .bold))
                    .foregroundStyle(weightIsInvalid ? Design.Color.danger : Design.Color.textPrimary)
                    .monospacedDigit()
                    .fixedSize()
                    .onChange(of: weightText) { _, value in
                        let filtered = value.filter { $0.isNumber || $0 == "." || $0 == "," }
                        if filtered != value { weightText = filtered }
                    }
                    .accessibilityLabel("Weight in \(unitLabel == "lb" ? "pounds" : "kilograms")")
                Text(unitLabel)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Design.Color.textSecondary)
                Spacer()
                Button {
                    if isCapturing { stopListening() } else { Task { await startListening() } }
                } label: {
                    Image(systemName: isCapturing ? "stop.fill" : "mic.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Design.Color.onEmber)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                        .background(Design.Color.emberFill, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
                .accessibilityLabel(isCapturing ? "Stop listening" : "Say your weight")
            }
            .padding(16)
            .cardSurface()
            .contentShape(Rectangle())
            .onTapGesture { weightFocused = true }
            if let voiceMessage = voice.errorMessage, !isCapturing {
                Text(voiceMessage)
                    .font(.caption)
                    .foregroundStyle(Design.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if voice.notice == .didNotCatchThat, weightText.isEmpty {
                Text(VoiceCopy.didNotCatchThat)
                    .font(.caption)
                    .foregroundStyle(Design.Color.textSecondary)
            } else if step == .weight {
                Text(existing?.hasPhoto == true
                     ? "Say it or type it. This morning’s photo stays as is."
                     : "Say it or type it.")
                    .font(.caption)
                    .foregroundStyle(Design.Color.textTertiary)
            } else if existing?.weightKG != nil, weightText.isEmpty {
                Text("Leaving it blank keeps this morning’s weight.")
                    .font(.caption)
                    .foregroundStyle(Design.Color.textTertiary)
            } else if weightText.isEmpty {
                Text("No scale yet? Skip it. The photo is the check-in.")
                    .font(.caption)
                    .foregroundStyle(Design.Color.textTertiary)
            }
        }
    }

    private var noteBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Note · optional").eyebrowStyle()
            TextField("Slept 5 hours, pumped from legs…", text: $note, axis: .vertical)
                .focused($noteFocused)
                .lineLimit(1...4)
                .font(.body)
                .foregroundStyle(Design.Color.textPrimary)
                .padding(14)
                .cardSurface(radius: Design.Radius.control)
                .onChange(of: note) { _, value in
                    if value.count > WeightCheckInPolicy.noteLimit {
                        note = String(value.prefix(WeightCheckInPolicy.noteLimit))
                    }
                }
        }
    }

    private var canSave: Bool {
        guard !isSaving, !weightIsInvalid else { return false }
        switch step {
        case .review: return capture != nil
        case .weight: return weightKG != nil
        case .camera: return false
        }
    }

    private var saveBar: some View {
        Button {
            if isCapturing { stopListening() } else { save() }
        } label: {
            HStack(spacing: 8) {
                if isSaving {
                    ProgressView().tint(Design.Color.onEmber)
                } else {
                    Image(systemName: isCapturing ? "stop.fill" : "checkmark")
                }
                Text(isCapturing ? "Stop" : isSaving ? "Saving…" : step == .weight ? "Save weight" : "Save check-in")
            }
            .font(.headline)
            .foregroundStyle(Design.Color.onEmber)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background {
                if canSave || isCapturing {
                    Capsule().fill(Design.Color.emberFill)
                } else {
                    Capsule().fill(Design.Color.textDisabled)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isCapturing && !canSave)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Design.Color.canvas.opacity(0.92))
    }

    // MARK: Actions

    /// What a save sends, before the photo is encoded: only what the user
    /// actually provided. A blank weight stays nil (an earlier weight that day
    /// survives); photo columns ride along only with a new photo; an
    /// unchanged note isn't re-sent.
    static func draft(
        localDay: String,
        weightKG: Double?,
        includesPhoto: Bool,
        pose: PhysiquePose,
        capturedAt: Date?,
        note: String,
        existing: WeightCheckIn?
    ) -> BodyCheckInDraft {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return BodyCheckInDraft(
            localDay: localDay,
            weightKG: weightKG,
            photoJPEG: nil,
            pose: includesPhoto ? pose : nil,
            capturedAt: includesPhoto ? (capturedAt ?? Date()) : nil,
            note: trimmedNote.isEmpty || trimmedNote == existing?.note ? nil : trimmedNote
        )
    }

    private func loadGhost() async {
        guard ghost == nil, let ghostPath else { return }
        if let loader = photoLoader {
            ghost = await loader.image(path: ghostPath, maxPixel: BodyPhotoSize.hero)
        } else if let data = try? await service.photoData(path: ghostPath) {
            ghost = await Task.detached(priority: .userInitiated) {
                ImageProcessor.downsample(data: data, maxPixelSize: BodyPhotoSize.hero)
            }.value
        }
    }

    private func startListening() async {
        weightFocused = false
        await voice.start()
    }

    /// Ends the take and keeps the final pass's weight (the recognizer's
    /// last word beats the live guess).
    private func stopListening() {
        Task {
            if let take = await voice.stop() { applySpokenWeight(take.text) }
        }
    }

    private func applySpokenWeight(_ text: String) {
        guard let value = WeightUtterancePolicy.parsedWeight(transcript: text, units: units) else { return }
        let formatted = String(format: "%.1f", value)
        if weightText != formatted { weightText = formatted }
    }

    private func save() {
        if let take = voice.collectReadyTake() { applySpokenWeight(take.text) }
        voice.cancel()
        weightFocused = false
        noteFocused = false
        isSaving = true
        errorMessage = nil
        let image = step == .review ? capture?.image : nil
        var draft = Self.draft(
            localDay: localDay,
            weightKG: weightKG,
            includesPhoto: image != nil,
            pose: pose,
            capturedAt: capture?.capturedAt,
            note: note,
            existing: existing
        )
        let service = service
        let existing = existing
        let updatesProfileWeight = updatesProfileWeight
        Task {
            if let image {
                guard let jpeg = await Task.detached(priority: .userInitiated, operation: {
                    BodyPhotoEncoder.jpeg(from: image)
                }).value else {
                    isSaving = false
                    errorMessage = "The photo couldn’t be prepared. Retake it and try again."
                    return
                }
                draft.photoJPEG = jpeg
            }
            do {
                let saved = try await service.save(
                    draft, replacing: existing, updatesProfileWeight: updatesProfileWeight)
                if let image, let path = saved.progressPhotoPath {
                    photoLoader?.insert(image, path: path)
                }
                savedCount += 1
                onSaved(saved)
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
