import AVFoundation
import PhotosUI
import SwiftUI
import UIKit

struct PhysiqueCapture {
    let image: UIImage
    let capturedAt: Date
    let fromLibrary: Bool
}

/// Custom physique camera: back camera by default (prop the phone up across
/// the room), 1x wide lens, 4:3, flash off. Yesterday's photo floats over
/// the preview as a 30% ghost so the pose and distance match; a 3/5/10 s
/// timer (tap to cycle) counts down out loud; Vision watches the stance and
/// says what to fix. The Simulator has no camera, so DEBUG builds shoot a
/// fixture image.
struct PhysiqueCameraView: View {
    let ghost: UIImage?
    let onCapture: (PhysiqueCapture) -> Void
    let onCancel: () -> Void

    @StateObject private var camera = BodyCameraController()
    @State private var voice = BodyCameraVoice()
    @AppStorage("shudo.body.camera.timer") private var timerSeconds = BodyCameraTimer.five.rawValue
    @AppStorage("shudo.body.camera.ghost") private var showsGhost = true
    @AppStorage("shudo.body.camera.voice") private var voiceOn = true
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var guidanceTask: Task<Void, Never>?
    @State private var lastSpokenAt = Date.distantPast
    @State private var isCapturing = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var errorMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var timer: BodyCameraTimer { BodyCameraTimer(rawValue: timerSeconds) ?? .five }
    private var isMirrored: Bool { camera.position == .front }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            viewfinder
                .padding(.horizontal, 12)
            Spacer(minLength: 8)
            controls
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task { await camera.start() }
        .onDisappear {
            cancelCountdown()
            guidanceTask?.cancel()
            camera.stop()
            voice.deactivate()
        }
        .onChange(of: camera.poseHint) { _, hint in scheduleGuidance(hint) }
        .onChange(of: voiceOn) { _, enabled in voice.isEnabled = enabled }
        .onChange(of: libraryItem) { _, item in importFromLibrary(item) }
        .onAppear { voice.isEnabled = voiceOn }
        .sensoryFeedback(.impact(weight: .light), trigger: countdown) { _, new in new != nil }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 10) {
            circleButton("xmark", label: "Close camera") { onCancel() }
            Spacer()
            timerButton
            if ghost != nil {
                circleButton(showsGhost ? "person.fill.viewfinder" : "person.crop.rectangle", label: showsGhost ? "Hide ghost" : "Show ghost", active: showsGhost) {
                    showsGhost.toggle()
                }
            }
            circleButton(voiceOn ? "speaker.wave.2.fill" : "speaker.slash.fill", label: voiceOn ? "Mute voice" : "Voice guidance", active: voiceOn) {
                voiceOn.toggle()
            }
            if BodyCaptureEngine.hasCamera(.front) && BodyCaptureEngine.hasCamera(.back) {
                circleButton("arrow.triangle.2.circlepath.camera", label: "Switch camera") {
                    Task { await camera.flip() }
                }
                .disabled(countdown != nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// One tap cycles 3 → 5 → 10 s; the choice sticks across mornings.
    private var timerButton: some View {
        Button {
            let all = BodyCameraTimer.allCases
            let next = all[((all.firstIndex(of: timer) ?? 0) + 1) % all.count]
            timerSeconds = next.rawValue
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "timer").font(Design.Typeface.text(.footnote, weight: .bold))
                Text("\(timer.rawValue)s")
                    .font(Design.Typeface.numeral(.subheadline, weight: .bold))
                    .contentTransition(.numericText(value: Double(timer.rawValue)))
            }
            .foregroundStyle(Design.Color.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .chromeGlass(in: Capsule(), tint: Design.Color.canvas.opacity(0.4), interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(countdown != nil)
        .sensoryFeedback(.selection, trigger: timerSeconds)
        .accessibilityLabel("Timer, \(timer.rawValue) seconds")
        .accessibilityHint("Changes the countdown")
    }

    private func circleButton(_ symbol: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Design.Typeface.text(.body, weight: .semibold))
                .foregroundStyle(active ? Design.Color.ember : Design.Color.textPrimary)
                .frame(width: 40, height: 40)
                .chromeGlass(in: Circle(), tint: Design.Color.canvas.opacity(0.4), interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var viewfinder: some View {
        ZStack {
            preview
            if showsGhost, let ghost {
                Image(uiImage: ghost)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(x: isMirrored ? -1 : 1, y: 1)
                    .opacity(0.3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            framingGuides
            VStack {
                hintChip
                Spacer()
            }
            .padding(12)
            if let countdown {
                Text("\(countdown)")
                    .font(BodyType.fixed(120, weight: .light))
                    .foregroundStyle(Design.Color.cream)
                    .shadow(color: .black.opacity(0.5), radius: 12)
                    .contentTransition(.numericText(countsDown: true))
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("\(countdown) seconds")
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .stroke(camera.poseHint == .aligned ? Design.Color.positive : Design.Color.hairline, lineWidth: camera.poseHint == .aligned ? 2 : 0.5)
        )
    }

    @ViewBuilder
    private var preview: some View {
        switch camera.state {
        case .running, .starting:
            BodyCameraPreview(session: camera.session, mirrored: isMirrored)
        case .denied:
            unavailableCard(
                title: "Camera is off for Shudo",
                detail: "Turn it on in Settings, or pick a photo from your library.",
                showsSettings: true)
        case .unavailable, .idle:
            #if DEBUG
                if let fixture = BodyFixtureArt.cameraFixture {
                    Image(uiImage: fixture).resizable().scaledToFill()
                } else {
                    unavailableCard(title: "No camera here", detail: "Pick a photo from your library.", showsSettings: false)
                }
            #else
                unavailableCard(title: "No camera here", detail: "Pick a photo from your library.", showsSettings: false)
            #endif
        }
    }

    private func unavailableCard(title: String, detail: String, showsSettings: Bool) -> some View {
        ZStack {
            Design.Color.surface1
            VStack(spacing: 10) {
                Image(systemName: "camera.fill").font(Design.Typeface.text(.title)).foregroundStyle(Design.Color.textTertiary)
                Text(title).font(Design.Typeface.text(.headline, weight: .semibold)).foregroundStyle(Design.Color.textPrimary)
                Text(detail).font(Design.Typeface.text(.footnote)).foregroundStyle(Design.Color.textSecondary)
                    .multilineTextAlignment(.center)
                if showsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                    Link("Open Settings", destination: url)
                        .font(Design.Typeface.text(.subheadline, weight: .semibold))
                        .foregroundStyle(Design.Color.ember)
                }
            }
            .padding(24)
        }
    }

    /// Thirds plus head/feet marks: same framing every morning.
    private var framingGuides: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width, h = geo.size.height
                path.move(to: CGPoint(x: w / 2, y: h * 0.04))
                path.addLine(to: CGPoint(x: w / 2, y: h * 0.96))
                for y in [h * 0.06, h * 0.94] {
                    path.move(to: CGPoint(x: w * 0.38, y: y))
                    path.addLine(to: CGPoint(x: w * 0.62, y: y))
                }
            }
            .stroke(Design.Color.cream.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var hintChip: some View {
        if camera.state == .running {
            let hint = camera.poseHint
            Label(hint.text, systemImage: hint == .aligned ? "checkmark.circle.fill" : "figure.stand")
                .font(Design.Typeface.text(.footnote, weight: .semibold))
                .foregroundStyle(hint == .aligned ? Design.Color.positive : Design.Color.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .chromeGlass(in: Capsule(), tint: Design.Color.canvas.opacity(0.5))
                .contentTransition(.opacity)
                .animation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion), value: hint)
        }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if let errorMessage {
                Text(errorMessage).font(Design.Typeface.text(.footnote)).foregroundStyle(Design.Color.danger)
            }
            HStack {
                PhotosPicker(selection: $libraryItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle")
                        .font(Design.Typeface.text(.title3, weight: .semibold))
                        .foregroundStyle(Design.Color.textPrimary)
                        .frame(width: 52, height: 52)
                        .background(Design.Color.surface2, in: Circle())
                }
                .accessibilityLabel("Choose from library")
                .disabled(countdown != nil || isCapturing)
                Spacer()
                shutter
                Spacer()
                Color.clear.frame(width: 52, height: 52)
            }
            .padding(.horizontal, 28)
        }
        .padding(.bottom, 18)
    }

    private var shutter: some View {
        Button {
            if countdown != nil { cancelCountdown() } else { startCountdown() }
        } label: {
            ZStack {
                Circle().stroke(Design.Color.cream, lineWidth: 4).frame(width: 78, height: 78)
                if countdown != nil {
                    RoundedRectangle(cornerRadius: 6).fill(Design.Color.danger).frame(width: 28, height: 28)
                } else {
                    Circle().fill(Design.Color.emberFill).frame(width: 64, height: 64)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isCapturing || !canShoot)
        .accessibilityLabel(countdown != nil ? "Cancel timer" : "Start \(timer.rawValue) second timer")
    }

    private var canShoot: Bool {
        #if DEBUG
            return camera.state == .running || BodyFixtureArt.cameraFixture != nil
        #else
            return camera.state == .running
        #endif
    }

    // MARK: Countdown + capture

    private func startCountdown() {
        errorMessage = nil
        guidanceTask?.cancel()
        let seconds = timer.rawValue
        countdownTask = Task { @MainActor in
            for remaining in stride(from: seconds, through: 1, by: -1) {
                withAnimation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion)) {
                    countdown = remaining
                }
                voice.tick()
                if remaining <= 3 || remaining == seconds { voice.say("\(remaining)") }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            await shoot()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    private func shoot() async {
        isCapturing = true
        defer { isCapturing = false }
        if camera.state == .running {
            do {
                let image = try await camera.capture()
                camera.stop()
                onCapture(PhysiqueCapture(image: image, capturedAt: Date(), fromLibrary: false))
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }
        #if DEBUG
            if let fixture = BodyFixtureArt.cameraFixture {
                onCapture(PhysiqueCapture(image: fixture, capturedAt: Date(), fromLibrary: false))
            }
        #endif
    }

    /// Spoken stance guidance, debounced: only a hint that holds for 1.2 s,
    /// at most every 3 s, and never over the countdown.
    private func scheduleGuidance(_ hint: BodyPoseHint) {
        guidanceTask?.cancel()
        guard voiceOn, countdown == nil, camera.state == .running, camera.position == .back else { return }
        guidanceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled, countdown == nil, camera.poseHint == hint,
                Date().timeIntervalSince(lastSpokenAt) > 3
            else { return }
            lastSpokenAt = Date()
            voice.say(hint.spoken)
        }
    }

    private func importFromLibrary(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            defer { libraryItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self),
                let image = await Task.detached(priority: .userInitiated, operation: {
                    ImageProcessor.downsample(data: data)
                }).value
            else {
                errorMessage = "That photo couldn’t be loaded."
                return
            }
            camera.stop()
            onCapture(PhysiqueCapture(image: image, capturedAt: Date(), fromLibrary: true))
        }
    }
}

/// AVCaptureVideoPreviewLayer host, portrait, aspect-fill.
struct BodyCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        guard let connection = view.previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }
}
