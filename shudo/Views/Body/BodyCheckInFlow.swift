import SwiftUI
import UIKit

/// The morning check-in, photo first and weight optional: camera → review
/// (pose, optional weight on the keypad) → save. `.weight` opens straight on
/// the keypad for "Add weight" later the same day; that save omits every
/// photo key, so the morning photo stays untouched, and a photo-only save
/// omits `weight_kg` so an earlier weight survives. Voice lives in one place,
/// the capture bar's mic, so a spoken weight goes through the coach.
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
    @State private var step: Step
    @State private var capture: PhysiqueCapture?
    @State private var ghost: UIImage?
    @State private var pose: PhysiquePose
    @State private var weightText: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedCount = 0
    @FocusState private var weightFocused: Bool
    @Namespace private var poseNamespace
    private let weightFontSize: CGFloat = 48

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
        ZStack {
            switch step {
            case .camera:
                PhysiqueCameraView(
                    ghost: ghost,
                    onCapture: { captured in
                        capture = captured
                        go(to: .review)
                    },
                    onCancel: {
                        if capture != nil { go(to: .review) } else { dismiss() }
                    }
                )
                // The camera lives to the left of the review: each panel slides
                // off toward its own side and the next slides home a beat later.
                .transition(.shojiPage(.leading, reduceMotion: reduceMotion))
            case .review, .weight:
                entryScreen
                    .transition(.shojiPage(.trailing, reduceMotion: reduceMotion))
            }
        }
        .background {
            // The weight-only sheet shows its own walnut presentation background.
            if step != .weight { Color.black.ignoresSafeArea() }
        }
        .preferredColorScheme(.dark)
        .task { await loadGhost() }
        // The one haptic in the ritual: the check-in landed.
        .sensoryFeedback(.success, trigger: savedCount)
        .interactiveDismissDisabled(isSaving)
    }

    /// Camera ⇄ review slide like a shoji panel; a fade under Reduce Motion.
    private func go(to next: Step) {
        withAnimation(Design.Motion.calm(Design.Motion.shoji, reduceMotion: reduceMotion)) {
            step = next
        }
    }

    // MARK: Review / weight entry

    private var entryScreen: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: step == .review ? Design.Space.xl : Design.Space.s) {
                    if step == .review { photoBlock }
                    weightField
                    Text(step == .weight ? "Or just tell Shudo your weight." : "Weight, if you have it")
                        .font(Design.Typeface.text(.footnote))
                        .foregroundStyle(Design.Color.textTertiary)
                        .padding(.top, step == .review ? -Design.Space.l : 0)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(Design.Typeface.text(.footnote))
                            .foregroundStyle(Design.Color.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.ink(reduceMotion: reduceMotion))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Design.Space.gutter)
                .padding(.top, step == .weight ? 0 : Design.Space.s)
                .padding(.bottom, Design.Space.l)
                .animation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion), value: errorMessage)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            .background {
                if step == .review { Design.Color.canvas.ignoresSafeArea() }
            }
            .navigationTitle(step == .weight ? "Weight" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(isSaving)
                }
                if step == .review {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Retake") { go(to: .camera) }
                            .disabled(isSaving)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { saveBar }
        }
        .task(id: step) {
            // "Add weight" opens on the keypad; the sheet settles first so
            // the keyboard rises with it instead of jumping.
            guard step == .weight else { return }
            try? await Task.sleep(for: .milliseconds(250))
            weightFocused = true
        }
    }

    private var photoBlock: some View {
        VStack(spacing: Design.Space.l) {
            if let image = capture?.image {
                Color.clear
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .frame(maxWidth: 300)
                    .overlay {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel("Today's check-in photo")
            }
            posePicker
        }
        .frame(maxWidth: .infinity)
    }

    /// Four quiet words; the chosen one sits on a walnut step.
    private var posePicker: some View {
        HStack(spacing: Design.Space.xxs) {
            ForEach([PhysiquePose.frontRelaxed, .frontFlexed, .side, .back]) { option in
                let selected = pose == option
                Button {
                    withAnimation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion)) {
                        pose = option
                    }
                } label: {
                    Text(option.label)
                        .font(Design.Typeface.text(.footnote, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Design.Color.textPrimary : Design.Color.textTertiary)
                        .padding(.horizontal, Design.Space.m)
                        .frame(minHeight: 32)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Design.Color.surface3)
                                    .matchedGeometryEffect(id: "pose", in: poseNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.label) pose")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    /// The number is the hero of this step: a serif figure, centred, with a
    /// hairline beneath where the digits land.
    private var weightField: some View {
        VStack(spacing: Design.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                TextField("—", text: $weightText)
                    .keyboardType(.decimalPad)
                    .focused($weightFocused)
                    .font(BodyType.hero(weightFontSize))
                    .foregroundStyle(weightIsInvalid ? Design.Color.danger : Design.Color.textPrimary)
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .fixedSize()
                    .onChange(of: weightText) { _, value in
                        let filtered = value.filter { $0.isNumber || $0 == "." || $0 == "," }
                        if filtered != value { weightText = filtered }
                    }
                    .accessibilityLabel("Weight in \(unitLabel == "lb" ? "pounds" : "kilograms")")
                Text(unitLabel)
                    .font(Design.Typeface.display(.title3))
                    .foregroundStyle(Design.Color.textSecondary)
            }
            Rectangle()
                .fill(weightFocused ? Design.Color.pernambuco.opacity(0.7) : Design.Color.strokeStrong)
                .frame(width: 140, height: 1)
                .animation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion), value: weightFocused)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Design.Space.xs)
        .contentShape(Rectangle())
        .onTapGesture { weightFocused = true }
    }

    private var canSave: Bool {
        guard !isSaving, !weightIsInvalid else { return false }
        switch step {
        case .review: return capture != nil
        case .weight: return weightKG != nil
        case .camera: return false
        }
    }

    /// The step's one primary action: a hinoki slab with sumi ink.
    private var saveBar: some View {
        Button(action: save) {
            ZStack {
                Text("Save").opacity(isSaving ? 0 : 1)
                if isSaving {
                    ProgressView().tint(Design.Color.onCream)
                }
            }
            .font(Design.Typeface.text(.headline, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 26)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(!canSave)
        .accessibilityLabel(isSaving ? "Saving" : "Save")
        .padding(.horizontal, Design.Space.gutter)
        .padding(.top, Design.Space.s)
        .padding(.bottom, Design.Space.m)
    }

    // MARK: Actions

    /// What a save sends, before the photo is encoded: only what the user
    /// actually provided. A blank weight stays nil (an earlier weight that day
    /// survives) and photo columns ride along only with a new photo.
    static func draft(
        localDay: String,
        weightKG: Double?,
        includesPhoto: Bool,
        pose: PhysiquePose,
        capturedAt: Date?
    ) -> BodyCheckInDraft {
        BodyCheckInDraft(
            localDay: localDay,
            weightKG: weightKG,
            photoJPEG: nil,
            pose: includesPhoto ? pose : nil,
            capturedAt: includesPhoto ? (capturedAt ?? Date()) : nil
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

    private func save() {
        weightFocused = false
        isSaving = true
        errorMessage = nil
        let image = step == .review ? capture?.image : nil
        var draft = Self.draft(
            localDay: localDay,
            weightKG: weightKG,
            includesPhoto: image != nil,
            pose: pose,
            capturedAt: capture?.capturedAt
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
