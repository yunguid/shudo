import PhotosUI
import SwiftUI
import UIKit

struct WeightCheckInView: View {
    private enum PhotoKind: String, Identifiable {
        case progress
        case scale
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var weightText: String
    @State private var progressPhoto: UIImage?
    @State private var scalePhoto: UIImage?
    @State private var progressPickerItem: PhotosPickerItem?
    @State private var scalePickerItem: PhotosPickerItem?
    @State private var cameraKind: PhotoKind?
    @State private var isSaving = false
    @State private var isReadingScale = false
    @State private var errorMessage: String?

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
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    intro
                    weightField
                    photoSlot(
                        title: "Mirror photo",
                        detail: "Optional progress photo",
                        systemImage: "person.crop.rectangle",
                        kind: .progress,
                        image: progressPhoto,
                        pickerItem: $progressPickerItem,
                        alreadySaved: existing?.progressPhotoPath != nil
                    )
                    photoSlot(
                        title: "Scale photo",
                        detail: "Optional photo of the display",
                        systemImage: "scalemass",
                        kind: .scale,
                        image: scalePhoto,
                        pickerItem: $scalePickerItem,
                        alreadySaved: existing?.scalePhotoPath != nil
                    )
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(Design.Color.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
                .padding(.bottom, 96)
            }
            .background(AppBackground())
            .navigationTitle(existing == nil ? "Morning check-in" : "Edit check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(isSaving)
                }
            }
            .safeAreaInset(edge: .bottom) { saveBar }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $cameraKind) { kind in
            CameraPicker { image in
                setImage(ImageProcessor.resizedForUpload(image), for: kind)
            }
            .ignoresSafeArea()
        }
        .onChange(of: progressPickerItem) { _, item in loadPickerItem(item, for: .progress) }
        .onChange(of: scalePickerItem) { _, item in loadPickerItem(item, for: .scale) }
        .interactiveDismissDisabled(isSaving)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localDay)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Design.Color.accentSecondary)
            Text(
                "Use the same time and conditions when you can. Daily changes are noisy; the trend matters more."
            )
            .font(.footnote)
            .foregroundStyle(Design.Color.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var weightField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Weight")
                .font(.headline)
                .foregroundStyle(Design.Color.ink)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("0.0", text: $weightText)
                    .keyboardType(.decimalPad)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(Design.Color.ink)
                    .monospacedDigit()
                    .onChange(of: weightText) { _, value in
                        let filtered = value.filter { $0.isNumber || $0 == "." || $0 == "," }
                        if filtered != value { weightText = filtered }
                    }
                Text(unitLabel)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Design.Color.muted)
            }
            .padding(18)
            .background(
                Design.Color.elevated,
                in: RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous)
            )
        }
    }

    private func photoSlot(
        title: String,
        detail: String,
        systemImage: String,
        kind: PhotoKind,
        image: UIImage?,
        pickerItem: Binding<PhotosPickerItem?>,
        alreadySaved: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(Design.Color.accentPrimary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Design.Color.ink)
                    Text(
                        alreadySaved && image == nil
                            ? "Saved — choose another to replace it"
                            : kind == .scale && isReadingScale ? "Reading the display…" : detail
                    )
                    .font(.caption)
                    .foregroundStyle(Design.Color.muted)
                }
                Spacer()
                if alreadySaved || image != nil {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Design.Color.success)
                }
            }

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous))
            }

            HStack(spacing: 10) {
                Button {
                    cameraKind = kind
                } label: {
                    Label("Camera", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity).frame(height: 44)
                }
                .buttonStyle(.plain)
                .background(Design.Color.elevated, in: Capsule())

                PhotosPicker(selection: pickerItem, matching: .images) {
                    Label("Photos", systemImage: "photo")
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .contentShape(Rectangle())
                }
                .background(Design.Color.elevated, in: Capsule())
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Design.Color.ink)
        }
        .padding(16)
        .background(
            Design.Color.glassFill,
            in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
        )
    }

    private var saveBar: some View {
        Button {
            save()
        } label: {
            HStack(spacing: 8) {
                if isSaving { ProgressView().tint(.white) }
                Text(isSaving ? "Saving…" : "Save check-in")
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(
                weightKG == nil ? Design.Color.subtle : Design.Color.ctaPrimary,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(weightKG == nil || isSaving)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    private func loadPickerItem(_ item: PhotosPickerItem?, for kind: PhotoKind) {
        guard let item else { return }
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
            setImage(image, for: kind)
        }
    }

    private func setImage(_ image: UIImage, for kind: PhotoKind) {
        switch kind {
        case .progress: progressPhoto = image
        case .scale:
            scalePhoto = image
            isReadingScale = true
            Task {
                let detected = await ScaleWeightReader.recognizedDisplayedWeight(
                    in: image,
                    units: units
                )
                isReadingScale = false
                guard let detected else { return }
                weightText = String(format: "%.1f", detected)
            }
        }
        errorMessage = nil
    }

    private func save() {
        guard let weightKG else { return }
        isSaving = true
        errorMessage = nil
        let progressPhoto = progressPhoto
        let scalePhoto = scalePhoto
        Task {
            let encoded = await Task.detached(priority: .userInitiated) {
                (
                    progressPhoto.flatMap { ImageProcessor.uploadJPEGData(from: [$0]) },
                    scalePhoto.flatMap { ImageProcessor.uploadJPEGData(from: [$0]) }
                )
            }.value
            guard (progressPhoto == nil || encoded.0 != nil),
                (scalePhoto == nil || encoded.1 != nil)
            else {
                isSaving = false
                errorMessage = "One of the photos couldn’t be prepared. Choose it again and retry."
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                return
            }
            do {
                let saved = try await service.saveWeightCheckIn(
                    localDay: localDay,
                    weightKG: weightKG,
                    progressJPEG: encoded.0,
                    scaleJPEG: encoded.1,
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
