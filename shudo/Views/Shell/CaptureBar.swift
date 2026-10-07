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
/// Three controls. Bottom-left, under Luke's left thumb: the mic — tap to
/// record (the field becomes a timer and meter, no live words), tap the
/// same spot to send (it transcribes, then goes to Shudo); hold to talk and
/// release to send. A failed transcription keeps the recording and the same
/// spot retries. The field opens the keyboard. Trailing: "+" — a labeled
/// menu to log a meal, photo, barcode, workout or check-in, the tab's own
/// first — or ✕ to discard while recording. The placeholder and `context_hint`
/// follow `context`.
struct CaptureBar: View {
    @ObservedObject var voice: VoiceTranscriber
    @Binding var draft: CaptureDraft
    var context: CaptureContext = .today
    let actions: CaptureBarActions

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.openURL) private var openURL
    @State private var pressStartedAt: Date?
    @State private var holdTask: Task<Void, Never>?
    @State private var isHolding = false
    @State private var holdCancels = false
    /// Send was tapped: the take this stop produces goes to Shudo, not into
    /// the draft.
    @State private var isSendingVoice = false
    @State private var sentCount = 0
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?

    private var isInline: Bool { placement == .inline }
    /// The field is a recording / transcribing / retry strip.
    private var isVoiceActive: Bool { CaptureLeadingRole.isVoiceActive(voice) || isHolding }
    private var showsDraftSend: Bool { !isVoiceActive && !draft.isEmpty }

    var body: some View {
        HStack(spacing: isInline ? 6 : 8) {
            // Always the same view, so a hold that starts recording keeps
            // its gesture: mic → send arrow → (spinner) → mic.
            leadingButton
            if isVoiceActive {
                CaptureVoiceStrip(
                    voice: voice,
                    compact: isInline,
                    holdHint: isHolding ? (holdCancels ? "Release to cancel" : "Release to send") : nil,
                    holdCancels: holdCancels
                )
                CaptureCircleButton(kind: .discard, isEnabled: !isHolding, action: discardRecording)
                    .accessibilityLabel("Discard recording")
                    .accessibilityIdentifier("capture.discard")
            } else {
                field
                if showsDraftSend {
                    CaptureCircleButton(kind: .send, action: send)
                        .accessibilityLabel("Send to Shudo")
                        .accessibilityIdentifier("capture.send")
                } else if context != .bio {
                    logButton
                }
            }
        }
        .padding(.leading, isInline ? 4 : 6)
        .padding(.trailing, isInline ? 4 : 8)
        .animation(Design.Motion.snap, value: isVoiceActive)
        .animation(Design.Motion.snap, value: showsDraftSend)
        .sensoryFeedback(.impact(weight: .light), trigger: sentCount)
        .onChange(of: voice.phase) { _, phase in
            // A take the system ended on its own (time limit, interruption)
            // parks as `.ready`; fold it into the draft to review and send.
            if phase == .ready, !isHolding, !isSendingVoice, let take = voice.collectReadyTake() {
                draft.append(take)
            }
            if !voice.canRetryTranscription, let message = voice.errorMessage {
                show(notice: message)
            } else if phase == .idle, voice.notice == .didNotCatchThat, !isSendingVoice {
                show(notice: VoiceCopy.didNotCatchThat)
            }
        }
    }

    // MARK: Leading: mic / send / retry (one spot)

    private var leadingRole: CaptureLeadingRole { .role(for: voice, isHolding: isHolding) }

    private var leadingButton: some View {
        let role = leadingRole
        return CaptureLeadingFace(role: role, size: isInline ? 30 : 36)
            .gesture(pressGesture)
            .sensoryFeedback(trigger: voice.isListening) { _, listening in listening ? .start : .stop }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(leadingLabel(role))
            .accessibilityHint(CaptureBarCopy.leadingHint(role))
            .accessibilityIdentifier(leadingIdentifier(role))
            .accessibilityAction { Task { await leadingTapped() } }
            .animation(Design.Motion.snap, value: isHolding)
    }

    private func leadingLabel(_ role: CaptureLeadingRole) -> String {
        switch role {
        case .mic: return "Talk to Shudo"
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

    /// A quick tap is start / send / retry; a hold past ~0.35 s from idle is
    /// push-to-talk (release sends; slide well away to cancel).
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pressStartedAt == nil {
                    pressStartedAt = Date()
                    holdTask?.cancel()
                    guard leadingRole == .mic else { return }
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled, pressStartedAt != nil else { return }
                        isHolding = true
                        holdCancels = false
                        await startRecording()
                    }
                }
                if isHolding {
                    holdCancels = abs(value.translation.width) > 110 || value.translation.height < -90
                }
            }
            .onEnded { _ in
                holdTask?.cancel()
                holdTask = nil
                pressStartedAt = nil
                let wasHolding = isHolding
                isHolding = false
                if wasHolding {
                    Task { await finishHold(cancelled: holdCancels) }
                } else {
                    Task { await leadingTapped() }
                }
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
        if !(await voice.start()), !isHolding, let message = voice.errorMessage {
            show(notice: message)
        }
    }

    private func finishHold(cancelled: Bool) async {
        if cancelled {
            discardRecording()
            return
        }
        await sendRecording()
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

    // MARK: Log

    private struct LogOption {
        let title: String
        let symbol: String
        let action: () -> Void
    }

    /// Everything Luke can log, the tab's own kind first.
    private var logOptions: [LogOption] {
        let meal = LogOption(title: "Log a meal", symbol: "fork.knife", action: actions.logMeal)
        let mealPhoto = LogOption(title: "Meal photo", symbol: "camera", action: actions.mealPhoto)
        let barcode = LogOption(title: "Scan barcode", symbol: "barcode.viewfinder", action: actions.scanBarcode)
        let workout = LogOption(title: "Log a workout", symbol: "dumbbell", action: actions.logWorkout)
        let workoutPhoto = LogOption(title: "Workout photo", symbol: "camera", action: actions.workoutPhoto)
        let checkIn = LogOption(title: "Daily check-in", symbol: "figure.arms.open", action: actions.checkIn)
        switch context {
        case .train: return [workout, workoutPhoto, meal, checkIn]
        case .body: return [checkIn, meal, workout]
        case .today, .bio: return [meal, mealPhoto, barcode, workout, checkIn]
        }
    }

    /// A tap opens the labeled menu, so every way to log is findable.
    private var logButton: some View {
        Menu {
            ForEach(logOptions, id: \.title) { option in
                Button(option.title, systemImage: option.symbol, action: option.action)
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: isInline ? 16 : 18, weight: .semibold))
                .foregroundStyle(Design.Color.textPrimary)
                .frame(width: 36, height: 36)
                .background(Design.Color.textPrimary.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .menuOrder(.priority)
        .buttonStyle(.plain)
        .accessibilityLabel("Log")
        .accessibilityHint("A meal, photo, barcode, workout or check-in")
        .accessibilityIdentifier("capture.log")
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
