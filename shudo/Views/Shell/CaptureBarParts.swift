import SwiftUI
import UIKit

// The pieces every capture bar is built from, so the tab bar's bar and the
// sheets that cover it (meal composer, Update meal, first run) look and
// behave the same: the bottom-left button starts, sends and retries in one
// spot; the field turns into a timer and meter while recording (no live
// words); ✕ sits on the trailing edge, away from Luke's left thumb.

/// What the bottom-left button is right now.
enum CaptureLeadingRole: Equatable {
    /// Idle: tap to record.
    case mic
    /// Push-to-talk is held down (the tab bar's bar only).
    case hold
    /// Recording: the same spot sends.
    case send
    /// Transcribing or sending.
    case working
    /// A transcription failed and the recording was kept: tap to retry.
    case retry

    @MainActor
    static func role(for voice: VoiceTranscriber, isHolding: Bool = false, isSending: Bool = false) -> Self {
        if isHolding { return .hold }
        if voice.isFinishing || (isSending && !voice.isListening) { return .working }
        if voice.canRetryTranscription { return .retry }
        if voice.isListening || voice.isStarting { return .send }
        return .mic
    }

    var symbol: String {
        switch self {
        case .mic: return "mic.fill"
        case .hold: return "waveform"
        case .send, .working: return "arrow.up"
        case .retry: return "arrow.clockwise"
        }
    }

    /// The recording, transcribing or retry strip replaces the field.
    @MainActor
    static func isVoiceActive(_ voice: VoiceTranscriber) -> Bool {
        voice.isBusy || voice.canRetryTranscription
    }
}

/// The bottom-left circle: ember mic at rest, the brighter ember send arrow
/// while recording, a spinner while transcribing, retry after a failure.
/// Purely visual; the owner decides what a tap or a hold does.
struct CaptureLeadingFace: View {
    let role: CaptureLeadingRole
    var size: CGFloat = 36
    /// The tab bar's bar: Shudo's mark at rest instead of the mic.
    var showsMark = false

    var body: some View {
        if showsMark, role == .mic {
            CoachAvatar(size: size + 2)
                .shadow(color: Design.Color.ember.opacity(0.3), radius: 6)
                .frame(width: size + 6, height: size + 6)
                .contentShape(Circle())
        } else {
            face
        }
    }

    private var face: some View {
        let active = role != .mic
        return ZStack {
            Circle()
                .fill(active ? AnyShapeStyle(Design.Color.ember) : AnyShapeStyle(Design.Color.emberFill))
                .frame(width: size, height: size)
                .scaleEffect(role == .hold ? 1.14 : (active ? 1.06 : 1))
                .shadow(color: Design.Color.ember.opacity(active ? 0.5 : 0.22), radius: active ? 10 : 6)
            if role == .working {
                ProgressView()
                    .controlSize(.small)
                    .tint(Design.Color.onEmber)
            } else {
                Image(systemName: role.symbol)
                    .font(.system(size: size * 0.42, weight: role == .send ? .heavy : .bold))
                    .foregroundStyle(Design.Color.onEmber)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.variableColor.iterative, isActive: role == .hold)
            }
        }
        .frame(width: size + 6, height: size + 6)
        .contentShape(Circle())
    }
}

/// What the field shows while voice is active: a breathing dot, the timer
/// and a level meter while recording; the frozen meter shimmering while it
/// transcribes; one short line when a transcription failed.
struct CaptureVoiceStrip: View {
    @ObservedObject var voice: VoiceTranscriber
    var isSending = false
    var compact = false
    /// Push-to-talk: "Release to send" / "Release to cancel".
    var holdHint: String?
    var holdCancels = false
    var identifierPrefix = "capture"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if voice.isFinishing || (isSending && !voice.isListening) {
                VoiceMeterView(levels: meterLevels, isActive: false, spacing: 2)
                    .frame(height: 14)
                    .shimmering()
                    .accessibilityElement()
                    .accessibilityLabel(VoiceCopy.transcribing)
                    .accessibilityIdentifier("\(identifierPrefix).transcribing")
            } else if voice.canRetryTranscription {
                Text(CaptureBarCopy.retryLine(for: voice.errorMessage))
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.honey)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityIdentifier("\(identifierPrefix).error")
            } else {
                recording
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private var meterLevels: [CGFloat] {
        Array(voice.meterLevels.suffix(compact ? 10 : 16))
    }

    private var recording: some View {
        HStack(spacing: 8) {
            RecordingPulseDot(size: 8)
            Text(VoiceCopy.clock(voice.elapsedTime))
                .font(Design.Typeface.numeral(.body, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Design.Color.textPrimary)
                .contentTransition(reduceMotion ? .identity : .numericText())
            if let holdHint {
                Text(holdHint)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(holdCancels ? Design.Color.danger : Design.Color.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VoiceMeterView(levels: meterLevels, isActive: voice.isListening, tint: Design.Color.ember, spacing: 2)
                    .frame(height: 20)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(holdHint.map { "Recording. \($0)." } ?? "Recording")
        .accessibilityValue(VoiceCopy.clock(voice.elapsedTime))
        .accessibilityIdentifier("\(identifierPrefix).recording")
    }
}

/// The small trailing circles: ✕ discard and the ember send arrow.
struct CaptureCircleButton: View {
    enum Kind {
        case discard
        case send
    }

    let kind: Kind
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: kind == .send ? "arrow.up" : "xmark")
                .font(.system(size: kind == .send ? 15 : 14, weight: .bold))
                .foregroundStyle(kind == .send ? Design.Color.onEmber : Design.Color.textSecondary)
                .frame(width: 32, height: 32)
                .background(
                    kind == .send
                        ? (isEnabled ? Design.Color.ember : Design.Color.surface3)
                        : Design.Color.surface3,
                    in: Circle()
                )
                .contentShape(Circle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}

/// Short lines for a bar-sized space.
enum CaptureBarCopy {
    /// One line for a kept recording whose transcription failed; the
    /// bottom-left button is the retry.
    static func retryLine(for message: String?) -> String {
        switch message {
        case VoiceCopy.transcriptionOffline: return "You’re offline. Tap to retry."
        case VoiceCopy.transcriptionSignedOut: return "Sign in again to send."
        default: return "Didn’t go through. Tap to retry."
        }
    }

    static func leadingLabel(_ role: CaptureLeadingRole, send: String) -> String {
        switch role {
        case .mic: return "Record"
        case .hold: return "Recording"
        case .send: return send
        case .working: return VoiceCopy.transcribing
        case .retry: return "Retry"
        }
    }

    static func leadingHint(_ role: CaptureLeadingRole) -> String {
        switch role {
        case .mic: return "Tap again to send."
        case .hold: return "Release to send."
        case .send: return "Stops recording and sends."
        case .working: return ""
        case .retry: return "Sends the kept recording again."
        }
    }
}

/// The capture bar's shape for sheets that cover it (meal composer, Update
/// meal, first run): mic at the bottom-left — tap to record, tap the same
/// spot to send — the text field beside it, send (or ✕ while recording) on
/// the right. Same states as the tab bar's bar, so muscle memory carries
/// over.
///
/// Observes the transcriber, so meter updates re-render only the bar.
struct SheetCaptureBar: View {
    @ObservedObject var voice: VoiceTranscriber
    @Binding var text: String
    let placeholder: String
    /// Something to send without a recording (typed words, a photo).
    var canSend: Bool
    /// False while the owner can't take a send yet (photos preparing).
    var isSendEnabled = true
    /// The owner is finishing the take and handing the result off.
    var isSending = false
    /// VoiceOver name for send ("Log meal", "Update estimate", …).
    var sendLabel = "Send"
    /// One short line above the bar (the owner's error).
    var message: String?
    var identifierPrefix = "sheetCapture"
    /// Right before a take starts (clear errors).
    var onWillRecord: () -> Void = {}
    /// Send: the owner stops/transcribes (or retries) any take and submits.
    let onSend: () -> Void
    /// A take that ended by itself (time limit, interruption, a camera tap)
    /// lands in the field for review.
    let onTake: (VoiceTake) -> Void

    @FocusState private var focused: Bool
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var role: CaptureLeadingRole { .role(for: voice, isSending: isSending) }
    private var isVoiceActive: Bool { CaptureLeadingRole.isVoiceActive(voice) || isSending }

    var body: some View {
        VStack(spacing: 8) {
            if let line = notice ?? message {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(Design.Color.honey)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .transition(.opacity)
                    .accessibilityIdentifier("\(identifierPrefix).message")
            }
            bar
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion), value: isVoiceActive)
        .animation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion), value: showsSend)
        .animation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion), value: notice ?? message)
        .sensoryFeedback(trigger: voice.isListening) { _, listening in listening ? .start : .stop }
        .onChange(of: voice.phase) { _, phase in
            // A take the system ended by itself parks as `.ready`: its words
            // go into the field to review.
            if phase == .ready, !isSending, let take = voice.collectReadyTake() {
                onTake(take)
            }
            if !voice.canRetryTranscription, let error = voice.errorMessage {
                show(error)
            } else if phase == .idle, voice.notice == .didNotCatchThat, !isSending {
                show(VoiceCopy.didNotCatchThat)
            }
        }
        .onDisappear { noticeTask?.cancel() }
    }

    private var showsSend: Bool {
        !isVoiceActive && (canSend || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var bar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: leadingTapped) {
                CaptureLeadingFace(role: role)
            }
            .buttonStyle(.plain)
            .disabled(role == .working)
            .accessibilityLabel(CaptureBarCopy.leadingLabel(role, send: sendLabel))
            .accessibilityHint(CaptureBarCopy.leadingHint(role))
            .accessibilityIdentifier("\(identifierPrefix).\(role == .retry ? "retry" : (role == .mic ? "mic" : "send"))")

            if isVoiceActive {
                CaptureVoiceStrip(voice: voice, isSending: isSending, identifierPrefix: identifierPrefix)
                    .padding(.bottom, 3)
                if !isSending {
                    CaptureCircleButton(kind: .discard) {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        voice.cancel()
                    }
                    .padding(.bottom, 5)
                    .accessibilityLabel("Discard recording")
                    .accessibilityIdentifier("\(identifierPrefix).discard")
                }
            } else {
                TextField(
                    "",
                    text: $text,
                    prompt: Text(placeholder).foregroundStyle(Design.Color.textTertiary),
                    axis: .vertical
                )
                .lineLimit(1...5)
                .font(.body)
                .foregroundStyle(Design.Color.textPrimary)
                .tint(Design.Color.ember)
                .focused($focused)
                .padding(.vertical, 9)
                .accessibilityIdentifier("\(identifierPrefix).input")

                if showsSend {
                    CaptureCircleButton(kind: .send, isEnabled: isSendEnabled) {
                        focused = false
                        onSend()
                    }
                    .padding(.bottom, 5)
                    .accessibilityLabel(sendLabel)
                    .accessibilityIdentifier("\(identifierPrefix).submit")
                }
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .chromeGlass(
            in: RoundedRectangle(cornerRadius: 24, style: .continuous),
            tint: Design.Color.canvas.opacity(0.35),
            interactive: true
        )
    }

    private func leadingTapped() {
        switch role {
        case .mic:
            if voice.phase == .ready, let take = voice.collectReadyTake() {
                onTake(take)
                return
            }
            if voice.needsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
                return
            }
            CaptureDiagnostics.record(.microphoneTapAcceptedStart, state: voice.controlState)
            focused = false
            notice = nil
            onWillRecord()
            Task {
                if !(await voice.start()), let error = voice.errorMessage, !voice.canRetryTranscription {
                    show(error)
                }
            }
        case .send:
            guard !voice.isStarting else {
                // Nothing recorded yet; the next tap sends.
                CaptureDiagnostics.record(.microphoneTapRejectedStarting, state: voice.controlState)
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                return
            }
            CaptureDiagnostics.record(.microphoneTapAcceptedStop, state: voice.controlState)
            focused = false
            onSend()
        case .retry:
            onSend()
        case .working, .hold:
            return
        }
    }

    private func show(_ line: String) {
        noticeTask?.cancel()
        notice = line
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }
}

/// The "recording" tell: an ember dot breathing in and out (steady under
/// Reduce Motion).
struct RecordingPulseDot: View {
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Design.Color.ember)
            .frame(width: size, height: size)
            .phaseAnimator(reduceMotion ? [false] : [false, true]) { dot, dimmed in
                dot
                    .opacity(dimmed ? 0.3 : 1)
                    .scaleEffect(dimmed ? 0.8 : 1)
            } animation: { _ in
                .easeInOut(duration: 0.75)
            }
            .accessibilityHidden(true)
    }
}

/// Bar meter shared by every voice surface.
struct VoiceMeterView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let levels: [CGFloat]
    let isActive: Bool
    var tint: Color = Design.Color.accentPrimary
    var spacing: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, levels.count)
            let barWidth = max(2, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(isActive ? tint : Design.Color.subtle.opacity(0.55))
                        .frame(width: barWidth, height: max(4, geometry.size.height * level))
                        .animation(reduceMotion ? nil : .linear(duration: 0.055), value: level)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}


// MARK: - Fan (hold the Shudo mark)

/// The hold menu's live state. The bar owns the press; the shell draws the
/// fan above everything (the bar's accessory clips its own content).
@MainActor
final class CaptureFan: ObservableObject {
    struct Option: Identifiable, Equatable {
        let id: String
        let title: String
        let symbol: String
    }

    @Published private(set) var options: [Option] = []
    /// The Shudo mark's center, in global coordinates.
    @Published private(set) var origin: CGPoint = .zero
    @Published private(set) var selection: Int?
    @Published private(set) var isOpen = false
    /// Let go without sliding: the fan stays up for a tap.
    @Published private(set) var isPinned = false
    private var onChoose: ((Int) -> Void)?

    func open(options: [Option], origin: CGPoint, onChoose: @escaping (Int) -> Void) {
        self.options = options
        self.origin = origin
        self.onChoose = onChoose
        selection = nil
        isPinned = false
        isOpen = true
    }

    func track(_ translation: CGSize) {
        let next = CaptureFanLayout.selection(for: translation, count: options.count)
        if next != selection { selection = next }
    }

    /// The thumb lifted: choose what it points at, stay up if it barely
    /// moved, otherwise close.
    func release(_ translation: CGSize) {
        if let index = CaptureFanLayout.selection(for: translation, count: options.count) {
            choose(index)
        } else if hypot(translation.width, translation.height) < CaptureFanLayout.deadZone {
            pin()
        } else {
            close()
        }
    }

    func pin() {
        selection = nil
        isPinned = true
    }

    func choose(_ index: Int) {
        let handler = onChoose
        close()
        handler?(index)
    }

    func close() {
        isOpen = false
        isPinned = false
        selection = nil
        onChoose = nil
    }
}

/// A quarter dial around the thumb: options from straight up to straight
/// right, one radius away, chosen by the direction the thumb slides — a
/// short flick toward an option is enough.
enum CaptureFanLayout {
    static let radius: CGFloat = 96
    /// Movement below this is still a press, not a choice.
    static let deadZone: CGFloat = 26
    /// How far off an option's direction the thumb can point and still pick it.
    static let tolerance: Double = 38

    /// Degrees clockwise from straight up.
    static func angle(index: Int, count: Int) -> Double {
        count > 1 ? Double(index) * 90 / Double(count - 1) : 45
    }

    static func offset(index: Int, count: Int) -> CGSize {
        let radians = angle(index: index, count: count) * .pi / 180
        return CGSize(width: sin(radians) * radius, height: -cos(radians) * radius)
    }

    static func selection(for translation: CGSize, count: Int) -> Int? {
        guard count > 0, hypot(translation.width, translation.height) >= deadZone else { return nil }
        let pointing = atan2(translation.width, -translation.height) * 180 / .pi
        let nearest = (0..<count).min { a, b in
            abs(pointing - angle(index: a, count: count)) < abs(pointing - angle(index: b, count: count))
        }
        guard let nearest, abs(pointing - angle(index: nearest, count: count)) <= tolerance else { return nil }
        return nearest
    }
}

/// A press that owns its touch from first contact (UIKit long press with no
/// delay and unlimited movement). Other recognizers on the bar — the system's
/// own long presses included — wait for it to fail, so a hold that turns
/// into a slide is never stolen mid-way.
struct ThumbPressGesture: UIGestureRecognizerRepresentable {
    var onBegan: () -> Void
    var onChanged: (CGSize) -> Void
    var onEnded: (CGSize) -> Void
    var onCancelled: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var start: CGPoint = .zero

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0
        recognizer.allowableMovement = .greatestFiniteMagnitude
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let point = recognizer.location(in: nil)
        let start = context.coordinator.start
        let translation = CGSize(width: point.x - start.x, height: point.y - start.y)
        switch recognizer.state {
        case .began:
            context.coordinator.start = point
            onBegan()
        case .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }
}

/// Draws the open fan over the whole app: a light blur, a cream glass band
/// around the lit Shudo mark, the options on it, and the chosen one's name.
struct CaptureFanOverlay: View {
    @ObservedObject var fan: CaptureFan

    var body: some View {
        ZStack(alignment: .topLeading) {
            if fan.isOpen {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.3))
                    .onTapGesture { fan.close() }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                CaptureFanDial(fan: fan)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(fan.isPinned)
        .animation(.easeOut(duration: 0.16), value: fan.isOpen)
        .sensoryFeedback(.selection, trigger: fan.selection) { _, new in new != nil }
    }
}

private struct CaptureFanDial: View {
    @ObservedObject var fan: CaptureFan
    @State private var isOut = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let count = fan.options.count
        ZStack(alignment: .topLeading) {
            Color.clear
                .glassEffect(
                    Glass.regular.tint(Design.Color.cream.opacity(0.16)),
                    in: CaptureFanBand(center: fan.origin, progress: isOut ? 1 : 0)
                )
            // The mark stays lit under the thumb: the dial grows out of it.
            CoachAvatar(size: 44)
                .shadow(color: Design.Color.cream.opacity(0.45), radius: 14)
                .scaleEffect(isOut ? 1.08 : 1)
                .position(fan.origin)
            ForEach(Array(fan.options.enumerated()), id: \.element.id) { index, option in
                let offset = CaptureFanLayout.offset(index: index, count: count)
                CaptureFanItem(option: option, isSelected: fan.selection == index) { fan.choose(index) }
                    .scaleEffect(isOut ? 1 : 0.4)
                    .opacity(isOut ? 1 : 0)
                    .position(
                        x: fan.origin.x + (isOut ? offset.width : 0),
                        y: fan.origin.y + (isOut ? offset.height : 0)
                    )
            }
            if let selection = fan.selection, fan.options.indices.contains(selection) {
                Text(fan.options[selection].title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Design.Color.onEmber)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .glassEffect(Glass.regular.tint(Design.Color.cream.opacity(0.85)), in: Capsule())
                    .fixedSize()
                    .position(
                        x: fan.origin.x + CaptureFanLayout.radius * 0.6,
                        y: fan.origin.y - CaptureFanLayout.radius - 66
                    )
                    .id(selection)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .animation(.snappy(duration: 0.16), value: fan.selection)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.74)) {
                isOut = true
            }
        }
    }
}

private struct CaptureFanItem: View {
    let option: CaptureFan.Option
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: option.symbol)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(isSelected ? Design.Color.onEmber : Design.Color.cream)
                .frame(width: 54, height: 54)
                .background {
                    if isSelected {
                        Circle()
                            .fill(Design.Color.cream)
                            .shadow(color: Design.Color.cream.opacity(0.55), radius: 16)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.2 : 1)
        .accessibilityLabel(option.title)
        .accessibilityIdentifier("capture.fan.\(option.id)")
    }
}

/// The dial's glass: a thick quarter ring from straight up to straight
/// right of the mark, grown along its length as it opens.
private struct CaptureFanBand: Shape {
    var center: CGPoint
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var arc = Path()
        arc.addArc(
            center: center,
            radius: CaptureFanLayout.radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 90 * Double(max(progress, 0.001))),
            clockwise: false
        )
        return arc.strokedPath(StrokeStyle(lineWidth: 70 * max(progress, 0.3), lineCap: .round))
    }
}
