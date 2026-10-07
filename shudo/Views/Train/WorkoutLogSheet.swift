import PhotosUI
import SwiftUI
import UIKit

/// Final dictation result handed back by the voice layer.
struct WorkoutDictation: Equatable, Sendable {
    var text: String
    /// e.g. "apple.speech_transcriber"; sent to log_activity as speech_engine.
    var speechEngine: String?
}

/// Two-phase dictation hook so the sheet stays voice-agnostic: lane I1's
/// `VoiceTranscriber` maps onto it directly (`start()` / `stop()` →
/// `VoiceTake{text, engine}` / `cancel()`).
struct WorkoutDictationHook {
    var start: @MainActor () async -> Bool
    var stop: @MainActor () async -> WorkoutDictation?
    var cancel: @MainActor () -> Void

    init(
        start: @escaping @MainActor () async -> Bool,
        stop: @escaping @MainActor () async -> WorkoutDictation?,
        cancel: @escaping @MainActor () -> Void
    ) {
        self.start = start
        self.stop = stop
        self.cancel = cancel
    }
}

/// Log a workout the way you'd text a friend: words (typed or dictated), an
/// optional Watch/treadmill screenshot, and a Lift/Cardio/Walk hint. When
/// opened from "Next up" it carries the plan session and shows today's
/// targets. Submitting hands a `WorkoutLogDraft` to the owner and dismisses
/// immediately — the upload belongs to `ActivityLoggingController`.
struct WorkoutLogSheet: View {
    let session: TrainingSession?
    let targets: [LiftTarget]
    var onDictate: WorkoutDictationHook?
    let onSubmit: (WorkoutLogDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var kind: ActivityKind?
    @State private var speechEngine: String?
    @State private var imageJPEG: Data?
    @State private var previewImage: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var isPreparingPhoto = false
    @State private var isDictating = false
    @State private var isStartingDictation = false
    @State private var photoError: String?
    @FocusState private var textFocused: Bool

    init(
        session: TrainingSession? = nil,
        targets: [LiftTarget] = [],
        initialKind: ActivityKind? = nil,
        initialText: String = "",
        initialImage: UIImage? = nil,
        onDictate: WorkoutDictationHook? = nil,
        onSubmit: @escaping (WorkoutLogDraft) -> Void
    ) {
        self.session = session
        self.targets = targets
        self.onDictate = onDictate
        self.onSubmit = onSubmit
        _text = State(initialValue: initialText)
        _kind = State(initialValue: initialKind ?? (session != nil ? .strength : nil))
        _previewImage = State(initialValue: initialImage)
        _imageJPEG = State(initialValue: initialImage.flatMap { Self.uploadJPEG(from: $0) })
    }

    private var draft: WorkoutLogDraft {
        WorkoutLogDraft(
            text: text,
            speechEngine: speechEngine,
            imageJPEG: imageJPEG,
            planSessionId: session?.id,
            kindHint: kind
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let session, !targets.isEmpty {
                        targetsCard(session)
                    }
                    if session == nil {
                        kindChips
                    }
                    entryField
                    attachmentRow
                    if let photoError {
                        Text(photoError)
                            .font(.footnote)
                            .foregroundStyle(Design.Color.danger)
                    }
                    Text("Shudo reads it, counts your sets, finds PRs, and estimates the burn. Burn never gets added back to your food targets.")
                        .font(.caption)
                        .foregroundStyle(Design.Color.textTertiary)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Design.Color.canvas.ignoresSafeArea())
            .navigationTitle(session?.name ?? "Log a workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDictating { onDictate?.cancel() }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log") { submit() }
                        .fontWeight(.semibold)
                        .disabled(!draft.canSubmit || isPreparingPhoto || isDictating)
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await loadPhoto(item) }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker { image in
                    Task { await attach(image) }
                }
                .ignoresSafeArea()
            }
            .onAppear {
                if previewImage == nil, onDictate == nil { textFocused = true }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.start, trigger: isDictating) { _, new in new }
        .sensoryFeedback(.stop, trigger: isDictating) { old, new in old && !new }
    }

    // MARK: Sections

    private func targetsCard(_ session: TrainingSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "target")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Design.Color.ember)
                Text("Today’s numbers").eyebrowStyle(Design.Color.ember)
                Spacer()
                Button("Fill in the plan") { fillFromPlan() }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Design.Color.ember)
                    .accessibilityHint("Writes every target into the log so you only edit what changed")
            }
            ForEach(targets) { target in
                HStack(alignment: .firstTextBaseline) {
                    Text(ActivitySummaryFormatter.shortLiftName(target.exercise.name))
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(target.prescription)
                        .font(Design.Typeface.numeral(.subheadline, weight: .semibold))
                        .foregroundStyle(Design.Color.textSecondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(14)
        .cardSurface(radius: Design.Radius.control)
    }

    private var kindChips: some View {
        HStack(spacing: 8) {
            ForEach([ActivityKind.strength, .cardio, .walk], id: \.self) { option in
                let selected = kind == option
                Button {
                    withAnimation(Design.Motion.snap) { kind = selected ? nil : option }
                } label: {
                    Label(option == .strength ? "Lift" : option.label, systemImage: option.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? Design.Color.onEmber : Design.Color.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background {
                            if selected {
                                Capsule().fill(Design.Color.emberFill)
                            } else {
                                Capsule().fill(Design.Color.surface2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: kind)
    }

    private var entryField: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(Design.Color.textTertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
            TextField("", text: $text, axis: .vertical)
                .font(.body)
                .foregroundStyle(Design.Color.textPrimary)
                .lineLimit(5...14)
                .focused($textFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .accessibilityLabel("What did you do?")
        }
        .frame(minHeight: 132, alignment: .topLeading)
        .background(Design.Color.surface2, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                .stroke(isDictating ? Design.Color.ember : Design.Color.hairline, lineWidth: isDictating ? 1.5 : 0.5))
    }

    private var placeholder: String {
        if isDictating { return "Listening…" }
        if session != nil { return "Bench 185 for 8, 8, 7. Rows 3×10 at 70s. Pull-ups +25 for 8…" }
        switch kind {
        case .cardio: return "25 min on the bike, 6.2 mi, avg HR 141…"
        case .walk: return "Walked to the office and back, about 40 min…"
        default: return "What did you do? Say it like you’d text a friend — or add your Watch screenshot."
        }
    }

    private var attachmentRow: some View {
        HStack(spacing: 10) {
            if let onDictate {
                Button {
                    Task { await toggleDictation(onDictate) }
                } label: {
                    Image(systemName: isDictating ? "stop.fill" : "mic.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Design.Color.onEmber)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 48, height: 48)
                        .background(Design.Color.emberFill, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isStartingDictation)
                .accessibilityLabel(isDictating ? "Stop dictation" : "Dictate")
            }
            PhotosPicker(selection: $photoItem, matching: .images) {
                attachmentLabel("Screenshot", symbol: "photo.on.rectangle")
            }
            .buttonStyle(.plain)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showingCamera = true } label: {
                    attachmentLabel("Camera", symbol: "camera.fill")
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if let previewImage {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button {
                        self.previewImage = nil
                        imageJPEG = nil
                        photoItem = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Design.Color.textPrimary, Design.Color.surface3)
                            .font(.body)
                    }
                    .offset(x: 6, y: -6)
                    .accessibilityLabel("Remove photo")
                }
            } else if isPreparingPhoto {
                ProgressView().tint(Design.Color.ember)
            }
        }
    }

    private func attachmentLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Design.Color.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Design.Color.surface3, in: Capsule())
    }

    // MARK: Actions

    private func submit() {
        let draft = self.draft
        guard draft.canSubmit else { return }
        onSubmit(draft)
        dismiss()
    }

    /// Writes the targets as plain text so logging "as planned" is one tap
    /// plus edits for whatever went differently.
    private func fillFromPlan() {
        let lines = targets.map { target -> String in
            let name = ActivitySummaryFormatter.shortLiftName(target.exercise.name)
            return "\(name) \(target.prescription)"
        }
        let planText = lines.joined(separator: "\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? planText : text + "\n" + planText
        textFocused = true
    }

    private func toggleDictation(_ hook: WorkoutDictationHook) async {
        if isDictating {
            isDictating = false
            if let take = await hook.stop() {
                let spoken = take.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !spoken.isEmpty {
                    let existing = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    text = existing.isEmpty ? spoken : existing + " " + spoken
                    speechEngine = take.speechEngine ?? speechEngine
                }
            }
        } else {
            textFocused = false
            isStartingDictation = true
            let started = await hook.start()
            isStartingDictation = false
            isDictating = started
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        isPreparingPhoto = true
        photoError = nil
        defer { isPreparingPhoto = false }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            photoError = "Couldn’t load that photo."
            return
        }
        let prepared = await Task.detached(priority: .userInitiated) { () -> (UIImage, Data)? in
            guard let image = ImageProcessor.downsample(data: data, maxPixelSize: Self.photoMaxPixelSize),
                  let jpeg = Self.uploadJPEG(from: image) else { return nil }
            return (image, jpeg)
        }.value
        guard let prepared else {
            photoError = "That photo couldn’t be prepared. Try a screenshot instead."
            return
        }
        previewImage = prepared.0
        imageJPEG = prepared.1
        if kind == nil { kind = .cardio }
    }

    private func attach(_ image: UIImage) async {
        isPreparingPhoto = true
        defer { isPreparingPhoto = false }
        let jpeg = await Task.detached(priority: .userInitiated) {
            Self.uploadJPEG(from: ImageProcessor.resizedForUpload(image, maxPixelSize: Self.photoMaxPixelSize))
        }.value
        guard let jpeg else {
            photoError = "That photo couldn’t be prepared."
            return
        }
        previewImage = image
        imageJPEG = jpeg
    }

    /// Screenshots keep small text legible at 2,048 px; quality steps down
    /// until the JPEG fits the 6 MB upload cap.
    nonisolated static let photoMaxPixelSize = 2_048

    nonisolated static func uploadJPEG(from image: UIImage) -> Data? {
        for quality in [0.85, 0.7, 0.55, 0.4] as [CGFloat] {
            if let data = image.jpegData(compressionQuality: quality),
               data.count <= SupabaseService.maximumActivityPhotoBytes {
                return data
            }
        }
        return nil
    }
}
