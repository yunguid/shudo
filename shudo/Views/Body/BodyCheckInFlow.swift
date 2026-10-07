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
    @StateObject private var voice = WeightVoiceCapture()
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
        .onChange(of: voice.transcript) { _, transcript in
            guard voice.isCapturing,
                let value = WeightUtterancePolicy.parsedWeight(transcript: transcript, units: units)
            else { return }
            weightText = String(format: "%.1f", value)
        }
        .onChange(of: weightFocused) { _, focused in if focused { voice.stop() } }
        .onDisappear { voice.stop() }
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
                            voice.stop()
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
            await voice.start()
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
                if voice.isCapturing {
                    HStack(spacing: 6) {
                        Circle().fill(Design.Color.danger).frame(width: 7, height: 7)
                        Text(weightKG == nil ? "Listening — say your weight" : "Heard it")
                            .font(Design.Typeface.meta)
                            .foregroundStyle(Design.Color.textSecondary)
                    }
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
                    if voice.isCapturing { voice.stop() } else { Task { await voice.start() } }
                } label: {
                    Image(systemName: voice.isCapturing ? "stop.fill" : "mic.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Design.Color.onEmber)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                        .background(Design.Color.emberFill, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
                .accessibilityLabel(voice.isCapturing ? "Stop listening" : "Say your weight")
            }
            .padding(16)
            .cardSurface()
            .contentShape(Rectangle())
            .onTapGesture { weightFocused = true }
            if step == .review, existing?.weightKG != nil, weightText.isEmpty {
                Text("Leaving it blank keeps this morning’s weight.")
                    .font(.caption)
                    .foregroundStyle(Design.Color.textTertiary)
            } else if step == .review, weightText.isEmpty {
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
            if voice.isCapturing { voice.stop() } else { save() }
        } label: {
            HStack(spacing: 8) {
                if isSaving {
                    ProgressView().tint(Design.Color.onEmber)
                } else {
                    Image(systemName: voice.isCapturing ? "stop.fill" : "checkmark")
                }
                Text(voice.isCapturing ? "Stop" : isSaving ? "Saving…" : step == .weight ? "Save weight" : "Save check-in")
            }
            .font(.headline)
            .foregroundStyle(Design.Color.onEmber)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background {
                if canSave || voice.isCapturing {
                    Capsule().fill(Design.Color.emberFill)
                } else {
                    Capsule().fill(Design.Color.textDisabled)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!voice.isCapturing && !canSave)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Design.Color.canvas.opacity(0.92))
    }

    // MARK: Actions

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

    private func save() {
        voice.stop()
        weightFocused = false
        noteFocused = false
        isSaving = true
        errorMessage = nil
        let image = step == .review ? capture?.image : nil
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var draft = BodyCheckInDraft(localDay: localDay)
        draft.weightKG = weightKG
        draft.pose = image == nil ? nil : pose
        draft.capturedAt = image == nil ? nil : capture?.capturedAt
        draft.note = trimmedNote.isEmpty || trimmedNote == existing?.note ? nil : trimmedNote
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
