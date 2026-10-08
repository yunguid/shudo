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

/// The hold menu's live state. The bar owns the gesture; the shell draws
/// the fan above everything (the bar's accessory clips its own content).
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

    /// The thumb lifted: choose what it's on, stay up if it never moved,
    /// otherwise close.
    func release(_ translation: CGSize) {
        if let index = CaptureFanLayout.selection(for: translation, count: options.count) {
            choose(index)
        } else if hypot(translation.width, translation.height) < CaptureFanLayout.deadZone {
            isPinned = true
        } else {
            close()
        }
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

/// The options sit in a row above the bar, the first straight above the
/// thumb: slide up for it, then right for the rest.
enum CaptureFanLayout {
    static let spacing: CGFloat = 92
    static let lift: CGFloat = 104
    /// Movement below this is still a press, not a choice.
    static let deadZone: CGFloat = 20

    static func offset(index: Int) -> CGSize {
        CGSize(width: CGFloat(index) * spacing, height: -lift)
    }

    /// The option nearest the thumb, horizontal distance weighted over
    /// vertical so a sideways slide reads as left/right. Nil inside the
    /// dead zone or once the thumb heads down or left of the mark.
    static func selection(for translation: CGSize, count: Int) -> Int? {
        guard count > 0,
              hypot(translation.width, translation.height) >= deadZone,
              translation.width > -spacing * 0.6,
              translation.height < spacing * 0.5 else { return nil }
        return (0..<count).min { a, b in
            distance(translation, offset(index: a)) < distance(translation, offset(index: b))
        }
    }

    private static func distance(_ point: CGSize, _ target: CGSize) -> CGFloat {
        hypot(point.width - target.width, (point.height - target.height) * 0.45)
    }
}

/// Draws the open fan over the whole app: a light scrim, then each option
/// springing out of the Shudo mark into its spot.
struct CaptureFanOverlay: View {
    @ObservedObject var fan: CaptureFan

    var body: some View {
        ZStack(alignment: .topLeading) {
            if fan.isOpen {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.45))
                    .onTapGesture { fan.close() }
                    .accessibilityHidden(true)
                    .transition(.opacity)
                // The mark stays lit under the thumb: the options come out of it.
                CoachAvatar(size: 42)
                    .shadow(color: Design.Color.ember.opacity(0.5), radius: 12)
                    .position(fan.origin)
                    .transition(.opacity)
                ForEach(Array(fan.options.enumerated()), id: \.element.id) { index, option in
                    let offset = CaptureFanLayout.offset(index: index)
                    CaptureFanItem(
                        option: option,
                        index: index,
                        offset: offset,
                        isSelected: fan.selection == index,
                        onTap: { fan.choose(index) }
                    )
                    .position(x: fan.origin.x + offset.width, y: fan.origin.y + offset.height)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(fan.isPinned)
        .animation(Design.Motion.snap, value: fan.isOpen)
        .sensoryFeedback(.selection, trigger: fan.selection) { _, new in new != nil }
    }
}

private struct CaptureFanItem: View {
    let option: CaptureFan.Option
    let index: Int
    let offset: CGSize
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isOut = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let size: CGFloat = 60

    var body: some View {
        Button(action: onTap) {
            Image(systemName: option.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(isSelected ? Design.Color.onEmber : Design.Color.textPrimary)
                .frame(width: Self.size, height: Self.size)
                .background {
                    Circle()
                        .fill(isSelected ? AnyShapeStyle(Design.Color.ember) : AnyShapeStyle(Design.Color.surface3))
                        .overlay(Circle().stroke(Design.Color.strokeStrong, lineWidth: isSelected ? 0 : 0.5))
                        .shadow(color: isSelected ? Design.Color.ember.opacity(0.55) : .black.opacity(0.4), radius: 14)
                }
                .overlay(alignment: .top) {
                    Text(option.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(isSelected ? Design.Color.textPrimary : Design.Color.textSecondary)
                        .fixedSize()
                        .offset(y: Self.size + 6)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityIdentifier("capture.fan.\(option.id)")
        .scaleEffect(isOut ? (isSelected ? 1.16 : 1) : 0.3)
        .offset(isOut ? .zero : CGSize(width: -offset.width, height: -offset.height))
        .opacity(isOut ? 1 : 0)
        .animation(.snappy(duration: 0.18), value: isSelected)
        .onAppear {
            let spring = Animation.spring(response: 0.34, dampingFraction: 0.72).delay(Double(index) * 0.035)
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : spring) { isOut = true }
        }
    }
}
