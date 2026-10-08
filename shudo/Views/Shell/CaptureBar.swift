import SwiftUI
import UIKit

/// What the capture bar can ask the shell to do.
struct CaptureBarActions {
    /// Send a message to Shudo (the coach routes meals/workouts via tools).
    var send: (_ text: String, _ mode: CoachInputMode, _ speechEngine: String?) -> Void
    /// The meal logger (photo, barcode, typed or spoken meal).
    var logMeal: () -> Void = {}
    /// The typed workout logger.
    var logWorkout: () -> Void = {}
    var mealPhoto: () -> Void
    var scanBarcode: () -> Void
    var workoutPhoto: () -> Void
    var checkIn: () -> Void
    /// Open the keyboard composer (the bottom accessory sits under the
    /// keyboard, so typing happens in a field docked above it).
    var beginTyping: () -> Void
    /// The bar is about to listen or type: a chance to warm location.
    var willCompose: () -> Void = {}
    /// A send went out or a recording was discarded (ends a one-off
    /// context such as `.bio`).
    var captureEnded: () -> Void = {}
}

/// The draft lives in the shell so it survives tab switches.
struct CaptureDraft: Equatable {
    var text = ""
    /// Set while the draft holds dictated words (sent as `input_mode: dictated`).
    var speechEngine: String?

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isEmpty: Bool { trimmed.isEmpty }

    mutating func append(_ take: VoiceTake) {
        let merged = DictationMergePolicy.appending(
            take.text,
            to: text,
            limit: CoachSendRequest.maximumTextLength
        )
        guard merged.record != nil else { return }
        text = merged.note
        speechEngine = take.engine.rawValue
    }

    mutating func clear() {
        text = ""
        speechEngine = nil
    }

    /// What a send carries: the trimmed text, and dictated vs typed.
    var submission: (text: String, mode: CoachInputMode, speechEngine: String?)? {
        guard !isEmpty else { return nil }
        return (trimmed, speechEngine == nil ? .typed : .dictated, speechEngine)
    }
}

/// The one input on every tab, mounted as the TabView's bottom accessory,
/// and the app's only voice entry point (other screens call
/// `CaptureController`; sheets that cover it use `SheetCaptureBar`, the
/// same shape).
///
/// Bottom-left, under Luke's left thumb: the Shudo mark. Tap it to record
/// (the field becomes a timer and meter, no live words), tap the same spot
/// to send (it transcribes, then goes to Shudo). Touch and hold it and three
/// options fan out above — Talk, Log food, Photo (the tab's own kinds on
/// Train and Body) — slide onto one and let go. A failed transcription keeps
/// the recording and the same spot retries. The field opens the keyboard;
/// trailing is send for a draft, or ✕ to discard while recording. The
/// placeholder and `context_hint` follow `context`.
struct CaptureBar: View {
    @ObservedObject var voice: VoiceTranscriber
    @Binding var draft: CaptureDraft
    var context: CaptureContext = .today
    let actions: CaptureBarActions
    @ObservedObject var fan: CaptureFan

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.openURL) private var openURL
    @State private var holdTask: Task<Void, Never>?
    /// This press only closes a fan left open; it does nothing else.
    @State private var pressClosesFan = false
    @State private var buttonCenter: CGPoint = .zero
    /// Send was tapped: the take this stop produces goes to Shudo, not into
    /// the draft.
    @State private var isSendingVoice = false
    @State private var sentCount = 0
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?

    private var isInline: Bool { placement == .inline }
    /// The field is a recording / transcribing / retry strip.
    private var isVoiceActive: Bool { CaptureLeadingRole.isVoiceActive(voice) }
    private var showsDraftSend: Bool { !isVoiceActive && !draft.isEmpty }

    var body: some View {
        HStack(spacing: isInline ? 6 : 8) {
            // Always the same view, so its gesture survives the role change:
            // Shudo → send arrow → (spinner) → Shudo.
            leadingButton
            if isVoiceActive {
                CaptureVoiceStrip(voice: voice, compact: isInline)
                CaptureCircleButton(kind: .discard, action: discardRecording)
                    .accessibilityLabel("Discard recording")
                    .accessibilityIdentifier("capture.discard")
            } else {
                field
                if showsDraftSend {
                    CaptureCircleButton(kind: .send, action: send)
                        .accessibilityLabel("Send to Shudo")
                        .accessibilityIdentifier("capture.send")
                }
            }
        }
        .padding(.leading, isInline ? 4 : 6)
        .padding(.trailing, isInline ? 4 : 8)
        .animation(Design.Motion.snap, value: isVoiceActive)
        .animation(Design.Motion.snap, value: showsDraftSend)
        .sensoryFeedback(.impact(weight: .light), trigger: sentCount)
        #if DEBUG
        .task {
            // `-shudoPreviewFan`: open the fan with the second option lit.
            guard ProcessInfo.processInfo.arguments.contains("-shudoPreviewFan") else { return }
            try? await Task.sleep(for: .milliseconds(1_500))
            openFan()
            fan.track(CaptureFanLayout.offset(index: 1, count: 3))
        }
        #endif
        .onChange(of: voice.phase) { _, phase in
            // A take the system ended on its own (time limit, interruption)
            // parks as `.ready`; fold it into the draft to review and send.
            if phase == .ready, !isSendingVoice, let take = voice.collectReadyTake() {
                draft.append(take)
            }
            if !voice.canRetryTranscription, let message = voice.errorMessage {
                show(notice: message)
            } else if phase == .idle, voice.notice == .didNotCatchThat, !isSendingVoice {
                show(notice: VoiceCopy.didNotCatchThat)
            }
        }
    }

    // MARK: Leading: Shudo / send / retry (one spot)

    private var leadingRole: CaptureLeadingRole { .role(for: voice) }

    private var leadingButton: some View {
        let role = leadingRole
        return CaptureLeadingFace(role: role, size: isInline ? 30 : 36, showsMark: true)
            .scaleEffect(fan.isOpen ? 1.12 : 1)
            .gesture(pressGesture)
            .onGeometryChange(for: CGPoint.self) { proxy in
                let frame = proxy.frame(in: .global)
                return CGPoint(x: frame.midX, y: frame.midY)
            } action: { buttonCenter = $0 }
            .sensoryFeedback(trigger: voice.isListening) { _, listening in listening ? .start : .stop }
            .sensoryFeedback(.impact(weight: .medium), trigger: fan.isOpen) { _, open in open }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(leadingLabel(role))
            .accessibilityHint(role == .mic ? "Tap to talk. Touch and hold for more." : CaptureBarCopy.leadingHint(role))
            .accessibilityIdentifier(leadingIdentifier(role))
            .accessibilityAction { Task { await leadingTapped() } }
            .accessibilityActions {
                if role == .mic {
                    ForEach(fanItems.dropFirst(), id: \.option.id) { item in
                        Button(item.option.title, action: item.action)
                    }
                }
            }
            .animation(Design.Motion.snap, value: fan.isOpen)
    }

    private func leadingLabel(_ role: CaptureLeadingRole) -> String {
        switch role {
        case .mic: return "Shudo"
        case .send: return "Send to Shudo"
        case .hold, .working, .retry: return CaptureBarCopy.leadingLabel(role, send: "Send to Shudo")
        }
    }

    private func leadingIdentifier(_ role: CaptureLeadingRole) -> String {
        switch role {
        case .mic, .hold: return "capture.mic"
        case .send, .working: return "capture.send"
        case .retry: return "capture.retry"
        }
    }

    /// One UIKit press owns the touch from the first contact: a quick tap
    /// is start / send / retry; holding ~0.2 s (or starting to slide) fans
    /// the options out, and the same touch slides onto one and lets go.
    private var pressGesture: ThumbPressGesture {
        ThumbPressGesture(
            onBegan: pressBegan,
            onChanged: pressMoved,
            onEnded: pressEnded,
            onCancelled: pressCancelled
        )
    }

    private func pressBegan() {
        holdTask?.cancel()
        pressClosesFan = fan.isOpen
        if pressClosesFan {
            fan.close()
            return
        }
        guard leadingRole == .mic else { return }
        holdTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, !fan.isOpen else { return }
            openFan()
        }
    }

    private func pressMoved(_ translation: CGSize) {
        guard !pressClosesFan, leadingRole == .mic else { return }
        // Sliding before the hold lands opens the fan right away.
        if !fan.isOpen, hypot(translation.width, translation.height) > 12 {
            holdTask?.cancel()
            openFan()
        }
        if fan.isOpen { fan.track(translation) }
    }

    private func pressEnded(_ translation: CGSize) {
        holdTask?.cancel()
        holdTask = nil
        if pressClosesFan {
            pressClosesFan = false
        } else if fan.isOpen {
            fan.release(translation)
        } else if hypot(translation.width, translation.height) < 12 {
            Task { await leadingTapped() }
        }
    }

    private func pressCancelled() {
        holdTask?.cancel()
        holdTask = nil
        pressClosesFan = false
        // The system took the touch: leave the fan up for a tap.
        if fan.isOpen { fan.pin() }
    }

    // MARK: Fan

    private struct FanItem {
        let option: CaptureFan.Option
        let action: () -> Void
    }

    /// Talk first (straight up from the thumb), then the tab's own logging.
    private var fanItems: [FanItem] {
        let talk = FanItem(option: .init(id: "talk", title: "Talk", symbol: "mic.fill")) {
            Task { await startRecording() }
        }
        let food = FanItem(option: .init(id: "food", title: "Log food", symbol: "fork.knife"), action: actions.logMeal)
        switch context {
        case .train:
            return [
                talk,
                FanItem(option: .init(id: "workout", title: "Log workout", symbol: "dumbbell.fill"), action: actions.logWorkout),
                FanItem(option: .init(id: "photo", title: "Photo", symbol: "camera.fill"), action: actions.workoutPhoto),
            ]
        case .body:
            return [
                talk,
                FanItem(option: .init(id: "checkin", title: "Check-in", symbol: "figure.arms.open"), action: actions.checkIn),
                food,
            ]
        case .today, .bio:
            return [
                talk,
                food,
                FanItem(option: .init(id: "photo", title: "Photo", symbol: "camera.fill"), action: actions.mealPhoto),
            ]
        }
    }

    private func openFan() {
        let items = fanItems
        fan.open(options: items.map(\.option), origin: buttonCenter) { index in
            guard items.indices.contains(index) else { return }
            items[index].action()
        }
    }

    private func leadingTapped() async {
        switch leadingRole {
        case .retry:
            await retryAndSend()
        case .send:
            if voice.isStarting {
                // Nothing recorded yet; the next tap sends.
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                return
            }
            await sendRecording()
        case .working, .hold:
            return
        case .mic:
            if voice.phase == .ready, let take = voice.collectReadyTake() {
                draft.append(take)
                return
            }
            if voice.needsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
                return
            }
            await startRecording()
        }
    }

    private func startRecording() async {
        actions.willCompose()
        voice.transcriptionPurposeOverride = context.transcriptionPurpose
        if !(await voice.start()), let message = voice.errorMessage {
            show(notice: message)
        }
    }

    // MARK: Field

    private var field: some View {
        Button {
            actions.beginTyping()
        } label: {
            Group {
                if let notice {
                    Text(notice).foregroundStyle(Design.Color.honey)
                } else if draft.isEmpty {
                    Text(isInline ? context.compactPlaceholder : context.placeholder)
                        .foregroundStyle(Design.Color.textTertiary)
                } else {
                    Text(draft.text).foregroundStyle(Design.Color.textPrimary)
                }
            }
            .font(.body)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(draft.isEmpty ? context.placeholder : "Draft: \(draft.text)")
        .accessibilityHint("Opens the keyboard")
        .accessibilityIdentifier("capture.field")
    }

    // MARK: Actions

    /// Stop → transcribe → the text goes to Shudo. A failed upload leaves
    /// the retry state; nothing heard says so.
    private func sendRecording() async {
        guard !isSendingVoice else { return }
        isSendingVoice = true
        defer { isSendingVoice = false }
        guard let take = await voice.stop() else {
            reportMissingTake()
            return
        }
        deliverAndSend(take)
    }

    private func retryAndSend() async {
        guard !isSendingVoice else { return }
        isSendingVoice = true
        defer { isSendingVoice = false }
        guard let take = await voice.retryTranscription() else {
            reportMissingTake()
            return
        }
        deliverAndSend(take)
    }

    private func deliverAndSend(_ take: VoiceTake) {
        draft.append(take)
        send()
    }

    private func reportMissingTake() {
        // The retry state carries a kept recording's error itself.
        guard !voice.canRetryTranscription else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        if let message = voice.errorMessage {
            show(notice: message)
        } else if voice.notice == .didNotCatchThat {
            show(notice: VoiceCopy.didNotCatchThat)
        }
    }

    private func discardRecording() {
        voice.cancel()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        actions.captureEnded()
    }

    private func send() {
        guard let submission = draft.submission else { return }
        actions.send(submission.text, submission.mode, submission.speechEngine)
        draft.clear()
        sentCount += 1
        actions.captureEnded()
    }

    private func show(notice message: String) {
        noticeTask?.cancel()
        withAnimation(Design.Motion.snap) { notice = message }
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(Design.Motion.snap) { notice = nil }
        }
    }
}

extension EnvironmentValues {
    /// Height of the keyboard composer while it's open (0 otherwise). A
    /// scrolling screen under it adds this to its bottom inset so its newest
    /// content stays visible above the composer.
    @Entry var captureComposerInset: CGFloat = 0
}

/// The typing surface: the tab bar's accessory sits under the keyboard, so
/// tapping the field opens this glass field docked right above it, bound to
/// the same draft. Same shape as the bar: mic bottom-left, send trailing.
/// Losing focus (swipe the thread, tap away) tucks it back into the bar with
/// the draft kept.
struct CaptureComposer: View {
    @Binding var draft: CaptureDraft
    var placeholder = CaptureContext.today.placeholder
    var onSend: () -> Void
    var onDictate: () -> Void
    var onClose: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button(action: onDictate) {
                CaptureLeadingFace(role: .mic)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Record instead")

            TextField(
                "",
                text: $draft.text,
                prompt: Text(placeholder).foregroundStyle(Design.Color.textTertiary),
                axis: .vertical
            )
            .lineLimit(1...6)
            .font(.body)
            .foregroundStyle(Design.Color.textPrimary)
            .tint(Design.Color.ember)
            .focused($focused)
            .padding(.vertical, 9)
            .accessibilityIdentifier("capture.input")
            .onChange(of: draft.text) { _, text in
                if text.isEmpty { draft.speechEngine = nil }
            }

            CaptureCircleButton(kind: .send, isEnabled: !draft.isEmpty, action: onSend)
                .padding(.bottom, 5)
                .accessibilityLabel("Send to Shudo")
                .accessibilityIdentifier("capture.input.send")
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .chromeGlass(
            in: RoundedRectangle(cornerRadius: 24, style: .continuous),
            tint: Design.Color.canvas.opacity(0.35),
            interactive: true
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onAppear { focused = true }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { onClose() }
        }
    }
}

