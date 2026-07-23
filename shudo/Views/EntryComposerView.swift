import PhotosUI
import SwiftUI
import UIKit

enum EntryComposerPolicy {
    static let maximumNoteLength = 12_000

    static func canSubmit(
        isSubmitting: Bool,
        isPreparingImage: Bool,
        hasAudio: Bool,
        hasImage: Bool,
        note: String
    ) -> Bool {
        !isSubmitting
            && !isPreparingImage
            && note.utf16.count <= maximumNoteLength
            && (hasAudio || hasImage || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    static func shouldDiscardRecording(
        isSubmitting: Bool,
        isShowingCamera: Bool,
        isShowingPhotoPicker: Bool
    ) -> Bool {
        !isSubmitting && !isShowingCamera && !isShowingPhotoPicker
    }
}

struct EntryComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var audio = AudioRecorder()

    @State private var note = ""
    @State private var pickedImages: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []
    @State private var isShowingCamera = false
    @State private var isShowingPhotoPicker = false
    @State private var isPreparingImage = false
    @State private var imageLoadGeneration = UUID()
    @State private var imagePreparationTask: Task<Void, Never>?
    @State private var uploadEncodeTask: Task<Data?, Never>?
    @State private var isSubmitting = false
    @State private var localError: String?
    @State private var didAutoStart = false
    @State private var clientRequestId = UUID()

    let selectedDay: Date
    let timezone: String
    let autoStartRecording: Bool
    let onSubmit: (String?, Data?, Data?, UUID) async -> EntrySubmissionResult

    init(
        selectedDay: Date,
        timezone: String,
        autoStartRecording: Bool = false,
        onSubmit: @escaping (String?, Data?, Data?, UUID) async -> EntrySubmissionResult
    ) {
        self.selectedDay = selectedDay
        self.timezone = timezone
        self.autoStartRecording = autoStartRecording
        self.onSubmit = onSubmit
    }

    private var hasAudio: Bool { audio.recordedFileURL != nil }
    private var canSubmit: Bool {
        EntryComposerPolicy.canSubmit(
            isSubmitting: isSubmitting,
            isPreparingImage: isPreparingImage,
            hasAudio: hasAudio,
            hasImage: !images.isEmpty,
            note: note
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: 28) {
                        dayLabel
                        voiceCapture
                        imageCapture
                        noteField

                        if let error = localError ?? audio.errorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(Design.Color.danger)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 120)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Log meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Design.Color.muted)
                        .disabled(isSubmitting)
                }
            }
            .safeAreaInset(edge: .bottom) { submitBar }
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
        .onChange(of: pickedImages) { _, items in preparePickedImages(items) }
        .onChange(of: images) { _, updated in prepareUploadEncoding(for: updated) }
        .task {
            guard autoStartRecording, !didAutoStart else { return }
            didAutoStart = true
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            _ = await audio.startRecording()
        }
        .onDisappear {
            // A camera or photo picker temporarily covers this view. Preserve a
            // finished voice note across that system presentation and clean it
            // up only when the composer itself is actually leaving.
            guard EntryComposerPolicy.shouldDiscardRecording(
                isSubmitting: isSubmitting,
                isShowingCamera: isShowingCamera,
                isShowingPhotoPicker: isShowingPhotoPicker
            ) else { return }
            imagePreparationTask?.cancel()
            imagePreparationTask = nil
            uploadEncodeTask?.cancel()
            uploadEncodeTask = nil
            imageLoadGeneration = UUID()
            isPreparingImage = false
            audio.discardRecording()
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private var dayLabel: some View {
        HStack(spacing: 7) {
            Image(systemName: "calendar")
            Text(dayText)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Design.Color.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Design.Color.glassFill, in: Capsule())
        .accessibilityLabel("Logging for \(dayText)")
    }

    private var voiceCapture: some View {
        VStack(spacing: 18) {
            AudioMeterView(levels: audio.meterLevels, isActive: audio.isRecording)
                .frame(height: 76)
                .padding(.horizontal, 18)

            VStack(spacing: 5) {
                Text(voiceHeadline)
                    .font(audio.isRecording ? .system(size: 26, weight: .medium) : .headline)
                    .monospacedDigit()
                    .foregroundStyle(Design.Color.ink)

                Text(voiceDetail)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Design.Color.muted)
            }

            HStack(spacing: 16) {
                if hasAudio && !audio.isRecording {
                    Button {
                        audio.discardRecording()
                    } label: {
                        Image(systemName: "trash")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Design.Color.muted)
                            .frame(width: 48, height: 48)
                            .background(Design.Color.elevated, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Discard voice note")
                }

                Button {
                    Task { await toggleRecording() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                audio.isRecording
                                    ? AnyShapeStyle(Design.Color.danger)
                                    : AnyShapeStyle(LinearGradient(
                                        colors: [Design.Color.accentPrimary, Design.Color.accentSecondary],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                            )
                            .frame(width: 76, height: 76)
                            .shadow(color: Design.Color.accentPrimary.opacity(audio.isRecording ? 0.12 : 0.28), radius: 24)

                        Image(systemName: audio.isRecording ? "stop.fill" : "mic.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                .accessibilityLabel(recordingButtonLabel)
            }
        }
        .padding(.vertical, 8)
    }

    private var imageCapture: some View {
        VStack(spacing: 12) {
            if !images.isEmpty {
                LazyVGrid(
                    columns: images.count == 1
                        ? [GridItem(.flexible())]
                        : [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity)
                                .frame(height: images.count == 1 ? 190 : 122)
                                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous))

                            Button {
                                removePhoto(at: index)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(.black.opacity(0.58), in: Circle())
                            }
                            .padding(8)
                            .accessibilityLabel("Remove photo \(index + 1)")
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    mediaButton(title: "Camera", systemImage: "camera.fill") {
                        if audio.isRecording { audio.stopRecording() }
                        isShowingCamera = true
                    }
                }

                mediaButton(
                    title: images.isEmpty ? "Photos" : "Add photos",
                    systemImage: "photo.on.rectangle"
                ) {
                    if audio.isRecording { audio.stopRecording() }
                    isShowingPhotoPicker = true
                }
            }
        }
    }

    private func mediaButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Design.Color.ink)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Design.Color.elevated, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(
            isSubmitting
                || isPreparingImage
                || images.count >= ImageProcessor.maximumPhotoCount
        )
    }

    private var noteField: some View {
        ZStack(alignment: .topLeading) {
            if note.isEmpty {
                Text("Optional note — portions, ingredients, anything useful")
                    .font(.body)
                    .foregroundStyle(Design.Color.muted)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 15)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $note)
                .font(.body)
                .foregroundStyle(Design.Color.ink)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(minHeight: 104, maxHeight: 150)
                .onChange(of: note) { _, value in
                    let bounded = EntryComposerPolicy.boundedNote(value)
                    if bounded != value { note = bounded }
                }
        }
        .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.xl, style: .continuous))
    }

    private var submitBar: some View {
        Button {
            submit()
        } label: {
            HStack(spacing: 9) {
                if isSubmitting || isPreparingImage {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.up")
                }
                Text(
                    isSubmitting
                        ? "Sending…"
                        : isPreparingImage ? "Preparing photos…" : "Log meal"
                )
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
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var dayText: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        if calendar.isDateInToday(selectedDay) { return "Today" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: selectedDay)
    }

    private var voiceHeadline: String {
        if audio.isRecording { return formatTime(audio.elapsedTime) }
        return hasAudio ? "Voice note ready" : "Describe what you ate"
    }

    private var voiceDetail: String {
        if audio.isRecording {
            return "\(formatTime(audio.remainingTime)) remaining · tap when done"
        }
        if hasAudio && audio.didReachMaximumDuration {
            return "Recording stopped at the time limit"
        }
        return hasAudio ? formatTime(audio.elapsedTime) : "Tap to record a voice note"
    }

    private var recordingButtonLabel: String {
        if audio.isRecording {
            return "Stop recording, \(formatTime(audio.remainingTime)) remaining"
        }
        return "Start recording"
    }

    private func toggleRecording() async {
        localError = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if audio.isRecording {
            audio.stopRecording()
        } else {
            _ = await audio.startRecording()
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
                withAnimation(.snappy) {
                    images.append(contentsOf: preparedImages.prefix(remainingSlots))
                }
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
        let generation = imageLoadGeneration
        Task.detached(priority: .userInitiated) {
            let prepared = ImageProcessor.resizedForUpload(captured)
            await MainActor.run {
                guard imageLoadGeneration == generation else { return }
                isPreparingImage = false
                guard images.count < ImageProcessor.maximumPhotoCount else { return }
                withAnimation(.snappy) { images.append(prepared) }
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

    private func removePhoto(at offset: Int) {
        guard images.indices.contains(offset) else { return }
        withAnimation(.snappy) {
            let index = images.index(images.startIndex, offsetBy: offset)
            images.remove(at: index)
        }
    }

    private func submit() {
        if audio.isRecording { audio.stopRecording() }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? nil : trimmed
        let audioData = audio.recordedData()
        let hasSelectedImages = !images.isEmpty
        let selectedImages = images
        let encodeTask = uploadEncodeTask

        isSubmitting = true
        localError = nil
        Task {
            // The upload JPEG is normally ready before the tap; otherwise wait
            // for the in-flight background encode instead of re-rendering here.
            var imageJPEG = await encodeTask?.value
            if hasSelectedImages && imageJPEG == nil {
                imageJPEG = await Task.detached(priority: .userInitiated) {
                    ImageProcessor.uploadJPEGData(from: selectedImages)
                }.value
            }
            if hasSelectedImages && imageJPEG == nil {
                await MainActor.run {
                    isSubmitting = false
                    localError = "Those photos couldn’t be prepared. Remove them and try again."
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
                return
            }
            let result = await onSubmit(text, audioData, imageJPEG, clientRequestId)
            await MainActor.run {
                isSubmitting = false
                switch result {
                case .accepted:
                    audio.discardRecording()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                case .rejected(let message):
                    localError = message
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private func formatTime(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct AudioMeterView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let levels: [CGFloat]
    let isActive: Bool

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 4
            let barWidth = max(2, (geometry.size.width - spacing * CGFloat(levels.count - 1)) / CGFloat(levels.count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(isActive ? Design.Color.accentPrimary : Design.Color.subtle.opacity(0.55))
                        .frame(width: barWidth, height: max(4, geometry.size.height * level))
                        .animation(reduceMotion ? nil : .linear(duration: 0.055), value: level)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}
