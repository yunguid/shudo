import PhotosUI
import SwiftUI
import UIKit

/// Voice-first weigh-in: the sheet starts listening as it appears, the
/// spoken weight lands in the big readout live, and one bottom button stops
/// the mic and then saves. Manual editing and an optional mirror photo are
/// the only other affordances — no instructions, no date, no scale photos.
struct WeightCheckInView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var voice = WeightVoiceCapture()
    @State private var weightText: String
    @State private var mirrorPhoto: UIImage?
    @State private var mirrorPickerItem: PhotosPickerItem?
    @State private var isShowingCamera = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var weightFieldFocused: Bool

    let localDay: String
    let units: String
    let existing: WeightCheckIn?
    let service: SupabaseService
    let onSaved: (WeightCheckIn) -> Void

    init(
        localDay: String,
        units: String,
        existing: WeightCheckIn?,
        service: SupabaseService = SupabaseService(),
        onSaved: @escaping (WeightCheckIn) -> Void
    ) {
        self.localDay = localDay
        self.units = units
        self.existing = existing
        self.service = service
        self.onSaved = onSaved
        let value = existing.map {
            WeightCheckInPolicy.displayedValue(kilograms: $0.weightKG, units: units)
        }
        _weightText = State(initialValue: value.map { String(format: "%.1f", $0) } ?? "")
    }

    private var unitLabel: String { units.lowercased() == "imperial" ? "lb" : "kg" }

    private var weightKG: Double? {
        let normalized = weightText.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized) else { return nil }
        return WeightCheckInPolicy.kilograms(from: value, units: units)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 12)
                weightReadout
                statusLine
                    .padding(.top, 14)
                Spacer(minLength: 12)
                mirrorPhotoSection
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(Design.Color.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppBackground())
            .navigationTitle("Weigh-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(isSaving)
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { image in
                mirrorPhoto = ImageProcessor.resizedForUpload(image)
                errorMessage = nil
            }
            .ignoresSafeArea()
        }
        .task {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                CameraPrewarmer.prewarm()
            }
            // Fresh weigh-ins go straight to voice; editing an existing one
            // starts quiet (the mic button restarts listening on demand).
            guard existing == nil else { return }
            await voice.start()
        }
        .onChange(of: voice.transcript) { _, transcript in
            guard voice.isCapturing,
                let value = WeightUtterancePolicy.parsedWeight(transcript: transcript, units: units)
            else { return }
            weightText = String(format: "%.1f", value)
        }
        .onChange(of: weightFieldFocused) { _, focused in
            if focused { voice.stop() }
        }
        .onChange(of: mirrorPickerItem) { _, item in loadMirrorPickerItem(item) }
        .onDisappear { voice.stop() }
        .interactiveDismissDisabled(isSaving)
    }

    private var weightReadout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            TextField("0.0", text: $weightText)
                .keyboardType(.decimalPad)
                .focused($weightFieldFocused)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(Design.Color.ink)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .fixedSize()
                .onChange(of: weightText) { _, value in
                    let filtered = value.filter { $0.isNumber || $0 == "." || $0 == "," }
                    if filtered != value { weightText = filtered }
                }
            Text(unitLabel)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Design.Color.muted)

            if !voice.isCapturing {
                Button {
                    Task { await voice.start() }
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Design.Color.accentSecondary)
                        .frame(width: 40, height: 40)
                        .background(Design.Color.elevated, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
                .accessibilityLabel("Say your weight")
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { weightFieldFocused = true }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusLine: some View {
        if voice.isCapturing {
            HStack(spacing: 7) {
                Circle()
                    .fill(Design.Color.danger)
                    .frame(width: 7, height: 7)
                Text(weightKG == nil ? "Listening — say your weight" : "Heard — tap Stop")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Design.Color.muted)
            }
            .transition(.opacity)
        }
    }

    private var mirrorPhotoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mirror photo · optional")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Design.Color.muted)

            if let mirrorPhoto {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: mirrorPhoto)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 170)
                        .clipShape(
                            RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
                        )
                    Button {
                        self.mirrorPhoto = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(.black.opacity(0.58), in: Circle())
                    }
                    .padding(8)
                    .accessibilityLabel("Remove mirror photo")
                }
            } else {
                HStack(spacing: 10) {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            voice.stop()
                            isShowingCamera = true
                        } label: {
                            Label("Camera", systemImage: "camera.fill")
                                .frame(maxWidth: .infinity).frame(height: 44)
                        }
                        .buttonStyle(.plain)
                        .background(Design.Color.elevated, in: Capsule())
                    }

                    PhotosPicker(selection: $mirrorPickerItem, matching: .images) {
                        Label("Photos", systemImage: "photo")
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .background(Design.Color.elevated, in: Capsule())
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Design.Color.ink)
                .disabled(isSaving)
            }

            if existing?.progressPhotoPath != nil, mirrorPhoto == nil {
                Text("A photo is already saved for this day — adding one replaces it.")
                    .font(.caption2)
                    .foregroundStyle(Design.Color.subtle)
            }
        }
    }

    private var actionBar: some View {
        Button {
            if voice.isCapturing {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                voice.stop()
            } else {
                save()
            }
        } label: {
            HStack(spacing: 8) {
                if isSaving {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: voice.isCapturing ? "stop.fill" : "checkmark")
                }
                Text(voice.isCapturing ? "Stop" : isSaving ? "Saving…" : "Save weigh-in")
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(actionBackground, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!voice.isCapturing && (weightKG == nil || isSaving))
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .accessibilityLabel(voice.isCapturing ? "Stop listening" : "Save weigh-in")
    }

    private var actionBackground: AnyShapeStyle {
        if voice.isCapturing { return AnyShapeStyle(Design.Color.danger) }
        return weightKG == nil
            ? AnyShapeStyle(Design.Color.subtle)
            : AnyShapeStyle(Design.Color.ctaPrimary)
    }

    private func loadMirrorPickerItem(_ item: PhotosPickerItem?) {
        guard let item else { return }
        voice.stop()
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                errorMessage = "That photo couldn’t be loaded."
                return
            }
            let image = await Task.detached(priority: .userInitiated) {
                ImageProcessor.downsample(data: data)
            }.value
            guard let image else {
                errorMessage = "That photo couldn’t be prepared."
                return
            }
            mirrorPhoto = image
            mirrorPickerItem = nil
            errorMessage = nil
        }
    }

    private func save() {
        guard let weightKG else { return }
        voice.stop()
        isSaving = true
        errorMessage = nil
        let mirrorPhoto = mirrorPhoto
        Task {
            let encoded = await Task.detached(priority: .userInitiated) {
                mirrorPhoto.flatMap { ImageProcessor.uploadJPEGData(from: [$0]) }
            }.value
            guard mirrorPhoto == nil || encoded != nil else {
                isSaving = false
                errorMessage = "The photo couldn’t be prepared. Choose it again and retry."
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            do {
                let saved = try await service.saveWeightCheckIn(
                    localDay: localDay,
                    weightKG: weightKG,
                    progressJPEG: encoded,
                    replacing: existing
                )
                onSaved(saved)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }
}
