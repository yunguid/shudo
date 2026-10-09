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

/// The command band: the app's one capture entry point and its tab bar, in
/// one reserved strip along the bottom (other screens call
/// `CaptureController`; sheets that cover it use `SheetCaptureBar`).
///
/// Bottom-left, carved into the screen's corner under Luke's left thumb:
/// Shudo's key. Tap it to record (the tab bar gives way to a timer and a
/// meter, no live words), tap the same spot to send (it transcribes, then
/// goes to Shudo). Touch and hold it and the cream dial fans out — Type,
/// Log food, Photo (the tab's own kinds on Train and Body) — slide onto one
/// and let go. A failed transcription keeps the recording and the same spot
/// retries; ✕ on the far right discards. A draft kept from the keyboard
/// composer shows as a Pernambuco dot on the key; Type reopens it.
struct CaptureBar: View {
    @ObservedObject var voice: VoiceTranscriber
    @Binding var draft: CaptureDraft
    var context: CaptureContext = .today
    let actions: CaptureBarActions
    @ObservedObject var fan: CaptureFan
    @Binding var tab: AppTab
    var todayBadge: Int = 0
    let metrics: CommandBandMetrics

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var holdTask: Task<Void, Never>?
    /// This press only closes a fan left open; it does nothing else.
    @State private var pressClosesFan = false
    @State private var isPressed = false
    @State private var keyCenter: CGPoint = .zero
    /// Send was tapped: the take this stop produces goes to Shudo, not into
    /// the draft.
    @State private var isSendingVoice = false
    @State private var sentCount = 0
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?

    /// The tab bar's place holds the recording / transcribing / retry strip.
    private var isVoiceActive: Bool { CaptureLeadingRole.isVoiceActive(voice) }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            base
            CommandWell(metrics: metrics)
            // Level with the key, but always clear of the home indicator.
            trailing
                .frame(height: CommandBandMetrics.barHeight)
                .padding(.leading, metrics.wellSide + CommandBandMetrics.barGap)
                .padding(.trailing, CommandBandMetrics.trailingMargin)
                .padding(.bottom, max(metrics.keyCenterInset - CommandBandMetrics.barHeight / 2, 22))
            // Always the same view, so its gesture survives the role change:
            // Shudo → send arrow → (spinner) → Shudo.
            key
                .padding(.leading, CommandBandMetrics.margin)
                .padding(.bottom, CommandBandMetrics.margin)
        }
        .frame(height: metrics.bandHeight)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topLeading) { noticeLine }
        .animation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion), value: isVoiceActive)
        .sensoryFeedback(.impact(weight: .light), trigger: sentCount)
        #if DEBUG
        .task(id: context) {
            // `-shudoPreviewFan`: open the fan with the second option lit
            // (restarts if the context settles after launch).
            guard ProcessInfo.processInfo.arguments.contains("-shudoPreviewFan") else { return }
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled else { return }
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

    // MARK: Band

    /// The band is opaque: content that scrolls down into it dissolves at
    /// its top edge instead of sliding under the well.
    private var base: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [Design.Color.canvas.opacity(0), Design.Color.canvas],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: CommandBandMetrics.topGap)
            Design.Color.canvas
        }
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailing: some View {
        if isVoiceActive {
            HStack(spacing: 8) {
                CaptureVoiceStrip(voice: voice)
                CaptureCircleButton(kind: .discard, action: discardRecording)
                    .accessibilityLabel("Discard recording")
                    .accessibilityIdentifier("capture.discard")
            }
            .padding(.leading, 18)
            .padding(.trailing, 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Design.Color.surface1, in: Capsule())
            .transition(.shoji(.leading, reduceMotion: reduceMotion))
        } else {
            ShellTabBar(tab: $tab, todayBadge: todayBadge)
                .transition(.shoji(.trailing, reduceMotion: reduceMotion))
        }
    }

    @ViewBuilder
    private var noticeLine: some View {
        if let notice {
            Text(notice)
                .font(Design.Typeface.text(.footnote, weight: .medium))
                .foregroundStyle(Design.Color.honey)
                .lineLimit(2)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .chromeGlass(in: Capsule(), tint: Design.Color.canvas.opacity(0.4))
                .padding(.leading, CommandBandMetrics.trailingMargin)
                .padding(.trailing, CommandBandMetrics.trailingMargin)
                .alignmentGuide(.top) { $0[.bottom] + 10 }
                .transition(.ink(reduceMotion: reduceMotion))
                .accessibilityIdentifier("capture.notice")
        }
    }

    // MARK: Key: Shudo / send / retry (one spot)

    private var leadingRole: CaptureLeadingRole { .role(for: voice) }

    private var key: some View {
        let role = leadingRole
        return CommandKey(role: role, metrics: metrics, isPressed: isPressed, hasDraft: !draft.isEmpty)
            .opacity(fan.isOpen ? 0 : 1)
            .gesture(pressGesture)
            .onGeometryChange(for: CGPoint.self) { proxy in
                let frame = proxy.frame(in: .global)
                return CGPoint(x: frame.midX, y: frame.midY)
            } action: { keyCenter = $0 }
            .sensoryFeedback(trigger: voice.isListening) { _, listening in listening ? .start : .stop }
            .sensoryFeedback(.impact(weight: .medium), trigger: fan.isOpen) { _, open in open }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(keyLabel(role))
            .accessibilityHint(role == .mic ? "Tap to talk. Touch and hold for more." : CaptureBarCopy.leadingHint(role))
            .accessibilityIdentifier(keyIdentifier(role))
            .accessibilityAction { Task { await leadingTapped() } }
            .accessibilityActions {
                if role == .mic {
                    ForEach(fanItems, id: \.option.id) { item in
                        Button(item.option.title, action: item.action)
                    }
                }
            }
            .animation(Design.Motion.snap, value: fan.isOpen)
    }

    private func keyLabel(_ role: CaptureLeadingRole) -> String {
        switch role {
        case .mic: return draft.isEmpty ? "Shudo" : "Shudo, draft waiting"
        case .send: return "Send to Shudo"
        case .hold, .working, .retry: return CaptureBarCopy.leadingLabel(role, send: "Send to Shudo")
        }
    }

    private func keyIdentifier(_ role: CaptureLeadingRole) -> String {
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
        isPressed = true
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
        isPressed = false
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
        isPressed = false
        pressClosesFan = false
        // The system took the touch: leave the fan up for a tap.
        if fan.isOpen { fan.pin() }
    }

    // MARK: Fan

    private struct FanItem {
        let option: CaptureFan.Option
        let action: () -> Void
    }

    /// Tapping the key already talks, so the dial holds everything else:
    /// Type straight up from the thumb, then the tab's own logging.
    private var fanItems: [FanItem] {
        let type = FanItem(
            option: .init(id: "type", title: draft.isEmpty ? "Type" : "Draft", symbol: "keyboard"),
            action: actions.beginTyping
        )
        let food = FanItem(option: .init(id: "food", title: "Log food", symbol: "fork.knife"), action: actions.logMeal)
        switch context {
        case .train:
            return [
                type,
                FanItem(option: .init(id: "workout", title: "Log workout", symbol: "dumbbell.fill"), action: actions.logWorkout),
                FanItem(option: .init(id: "photo", title: "Photo", symbol: "camera.fill"), action: actions.workoutPhoto),
            ]
        case .body:
            return [
                type,
                FanItem(option: .init(id: "checkin", title: "Check-in", symbol: "figure.arms.open"), action: actions.checkIn),
                food,
            ]
        case .today, .bio:
            return [
                type,
                food,
                FanItem(option: .init(id: "photo", title: "Photo", symbol: "camera.fill"), action: actions.mealPhoto),
            ]
        }
    }

    private func openFan() {
        isPressed = false
        let items = fanItems
        fan.open(options: items.map(\.option), origin: keyCenter) { index in
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
        withAnimation(Design.Motion.calm(Design.Motion.arrive, reduceMotion: reduceMotion)) { notice = message }
        noticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(Design.Motion.calm(Design.Motion.breath, reduceMotion: reduceMotion)) { notice = nil }
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
            .font(Design.Typeface.text(.body))
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
            tint: Design.Color.hinoki.opacity(0.04),
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

