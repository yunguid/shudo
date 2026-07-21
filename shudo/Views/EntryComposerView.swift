import PhotosUI
import SwiftUI
import UIKit

enum EntryComposerPolicy {
    static func canSubmit(
        isSubmitting: Bool,
        isPreparingImage: Bool,
        hasAudio: Bool,
        hasImage: Bool,
        note: String
    ) -> Bool {
        !isSubmitting
            && !isPreparingImage
            && (hasAudio || hasImage || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    @State private var pickedImage: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var isShowingCamera = false
    @State private var isShowingPhotoPicker = false
    @State private var isPreparingImage = false
    @State private var imageLoadGeneration = UUID()
    @State private var isSubmitting = false
    @State private var localError: String?
    @State private var didAutoStart = false
    @State private var clientRequestId = UUID()

    let selectedDay: Date
    let timezone: String
    let autoStartRecording: Bool
    let onSubmit: (String?, Data?, UIImage?, UUID) async -> Bool

    init(
        selectedDay: Date,
        timezone: String,
        autoStartRecording: Bool = false,
        onSubmit: @escaping (String?, Data?, UIImage?, UUID) async -> Bool
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
            hasImage: image != nil,
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
                withAnimation(.snappy) { image = selected }
            }
            .ignoresSafeArea()
        }
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $pickedImage,
            matching: .images
        )
        .onChange(of: pickedImage) { _, item in preparePickedImage(item) }
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
                    .font(audio.isRecording ? .system(size: 26, weight: .medium, design: .rounded) : .headline)
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

                        Image(systemName: audio.isRecording ? "stop.fill" : "waveform")
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
            if let image {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 190)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                    Button {
                        withAnimation(.snappy) {
                            self.image = nil
                            pickedImage = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.black.opacity(0.58), in: Circle())
                    }
                    .padding(10)
                    .accessibilityLabel("Remove photo")
                }
            }

            HStack(spacing: 12) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    mediaButton(title: image == nil ? "Camera" : "Retake", systemImage: "camera.fill") {
                        if audio.isRecording { audio.stopRecording() }
                        isShowingCamera = true
                    }
                }

                mediaButton(
                    title: image == nil ? "Photo" : "Replace",
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
        .disabled(isSubmitting || isPreparingImage)
    }

    private var noteField: some View {
        ZStack(alignment: .topLeading) {
            if note.isEmpty {
                Text("Optional note — portions, ingredients, anything useful")
                    .font(.body)
                    .foregroundStyle(Design.Color.subtle)
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
        }
        .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                        : isPreparingImage ? "Preparing photo…" : "Log meal"
                )
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                LinearGradient(
                    colors: canSubmit
                        ? [Design.Color.accentPrimary, Design.Color.accentSecondary]
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
        return hasAudio ? "Voice note ready" : "Tell Shudo what you ate"
    }

    private var voiceDetail: String {
        if audio.isRecording {
            return "\(formatTime(audio.remainingTime)) remaining · tap when done"
        }
        if hasAudio && audio.didReachMaximumDuration {
            return "Stopped automatically at the 15-minute limit"
        }
        return hasAudio ? formatTime(audio.elapsedTime) : "Record up to 15 minutes"
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

    private func preparePickedImage(_ item: PhotosPickerItem?) {
        let generation = UUID()
        imageLoadGeneration = generation
        guard let item else {
            isPreparingImage = false
            return
        }

        isPreparingImage = true
        localError = nil
        Task {
            let prepared: UIImage?
            if let data = try? await item.loadTransferable(type: Data.self) {
                prepared = ImageProcessor.downsample(data: data)
            } else {
                prepared = nil
            }

            await MainActor.run {
                guard imageLoadGeneration == generation else { return }
                isPreparingImage = false
                guard let prepared else {
                    localError = "That photo couldn’t be loaded."
                    return
                }
                withAnimation(.snappy) { image = prepared }
                localError = nil
            }
        }
    }

    private func submit() {
        if audio.isRecording { audio.stopRecording() }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? nil : trimmed
        let audioData = audio.recordedData()
        let selectedImage = image

        isSubmitting = true
        localError = nil
        Task {
            let accepted = await onSubmit(text, audioData, selectedImage, clientRequestId)
            await MainActor.run {
                isSubmitting = false
                if accepted {
                    audio.discardRecording()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                } else {
                    localError = "The meal wasn’t sent. Check your connection and try again."
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
                        .animation(.linear(duration: 0.055), value: level)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}
