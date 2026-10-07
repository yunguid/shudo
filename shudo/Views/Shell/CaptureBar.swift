import SwiftUI
import UIKit

/// What the capture bar can ask the shell to do.
struct CaptureBarActions {
    /// Send a message to Shudo (the coach routes meals/workouts via tools).
    var send: (_ text: String, _ mode: CoachInputMode, _ speechEngine: String?) -> Void
    /// The classic meal composer (`autoStartRecording` starts its own
    /// recording; the bar itself never asks for that).
    var openComposer: (_ autoStartRecording: Bool) -> Void
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

/// "Tell Shudo anything…" — the one input on every tab, mounted as the
/// TabView's bottom accessory, and the app's only voice entry point
/// (other screens call `CaptureController`).
///
/// Left-handed by design: the bottom-left button is both start and send.
/// Tap the mic and it records (no live words: the field becomes a pulsing
/// dot, timer and level meter) while the button turns into the ember send
/// arrow in place; tap it again to stop → "Transcribing…" → the text goes
/// straight to Shudo. ✕ to discard sits on the trailing edge, away from the
/// thumb. Hold the mic to talk and release to send (slide away to cancel).
/// A failed transcription keeps the recording: the same button retries.
/// Tapping the field opens a keyboard-docked composer; "+" opens the meal
/// composer; the camera menu routes photos. The placeholder and the
/// `context_hint` follow `context` (the tab, or a screen's request).
struct CaptureBar: View {
    @ObservedObject var voice: VoiceTranscriber
    @Binding var draft: CaptureDraft
    var context: CaptureContext = .today
    let actions: CaptureBarActions

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    private var isVoiceActive: Bool { voice.isBusy || voice.canRetryTranscription || isHolding }
    private var showsDraftSend: Bool { !isVoiceActive && !draft.isEmpty }

    var body: some View {
        HStack(spacing: isInline ? 6 : 8) {
            // Always the same view, so a hold that starts recording keeps
            // its gesture: mic → send arrow → (spinner) → mic.
            leadingButton
            if isVoiceActive {
                voiceStrip
                discardButton
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                field
                if showsDraftSend {
                    draftSendButton
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    if !isInline { composerButton }
                    cameraMenu
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

    private enum LeadingRole {
        case mic, hold, send, transcribing, retry
    }

    private var leadingRole: LeadingRole {
        if isHolding { return .hold }
        if voice.canRetryTranscription { return .retry }
        if voice.isFinishing { return .transcribing }
        if voice.isListening || voice.isStarting { return .send }
        return .mic
    }

    private var leadingButton: some View {
        let size: CGFloat = isInline ? 30 : 36
        let role = leadingRole
        let active = role != .mic
        return ZStack {
            Circle()
                .fill(active ? AnyShapeStyle(Design.Color.ember) : AnyShapeStyle(Design.Color.emberFill))
                .frame(width: size, height: size)
                .scaleEffect(role == .hold ? 1.14 : (active ? 1.06 : 1))
                .shadow(color: Design.Color.ember.opacity(active ? 0.55 : 0.25), radius: active ? 10 : 6)
            if role == .transcribing {
                ProgressView()
                    .controlSize(.small)
                    .tint(Design.Color.onEmber)
            } else {
                Image(systemName: leadingSymbol(role))
                    .font(.system(size: isInline ? 13 : 15, weight: role == .send ? .heavy : .bold))
                    .foregroundStyle(Design.Color.onEmber)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.variableColor.iterative, isActive: role == .hold)
            }
        }
        .frame(width: size + 6, height: size + 6)
        .contentShape(Circle())
        .gesture(pressGesture)
        .sensoryFeedback(trigger: voice.isListening) { _, listening in listening ? .start : .stop }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(leadingLabel(role))
        .accessibilityHint(leadingHint(role))
        .accessibilityIdentifier(leadingIdentifier(role))
        .accessibilityAction { Task { await leadingTapped() } }
        .animation(Design.Motion.snap, value: isHolding)
    }

    private func leadingSymbol(_ role: LeadingRole) -> String {
        switch role {
        case .mic: return "mic.fill"
        case .hold: return "waveform"
        case .send, .transcribing: return "arrow.up"
        case .retry: return "arrow.clockwise"
        }
    }

    private func leadingLabel(_ role: LeadingRole) -> String {
        switch role {
        case .mic: return "Talk to Shudo"
        case .hold: return "Recording"
        case .send: return "Send to Shudo"
        case .transcribing: return "Transcribing"
        case .retry: return "Retry transcription"
        }
    }

    private func leadingHint(_ role: LeadingRole) -> String {
        switch role {
        case .mic: return "Records a message. Tap again to send, or hold to talk and release to send."
        case .hold: return "Release to send"
        case .send: return "Stops recording, transcribes and sends"
        case .transcribing: return ""
        case .retry: return "Sends the kept recording again"
        }
    }

    private func leadingIdentifier(_ role: LeadingRole) -> String {
        switch role {
        case .mic, .hold: return "capture.mic"
        case .send, .transcribing: return "capture.send"
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
        case .transcribing, .hold:
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

    // MARK: Voice strip

    private var voiceStrip: some View {
        Group {
            if voice.canRetryTranscription {
                Text(voice.errorMessage ?? VoiceCopy.transcriptionFailed)
                    .font(.footnote)
                    .foregroundStyle(Design.Color.honey)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .accessibilityIdentifier("capture.error")
            } else if voice.isFinishing {
                Text(VoiceCopy.transcribing)
                    .font(.body)
                    .foregroundStyle(Design.Color.textSecondary)
                    .accessibilityIdentifier("capture.transcribing")
            } else if voice.isListening {
                recordingStrip
            } else {
                Text(isHolding ? "Hold to talk…" : "Starting…")
                    .font(.body)
                    .foregroundStyle(Design.Color.textTertiary)
                    .accessibilityIdentifier("capture.recording")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }

    private var recordingStrip: some View {
        HStack(spacing: 8) {
            RecordingPulseDot(size: 8)
            Text(VoiceCopy.clock(voice.elapsedTime))
                .font(Design.Typeface.numeral(.body, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Design.Color.textPrimary)
                .contentTransition(reduceMotion ? .identity : .numericText())
            if isHolding {
                Text(holdCancels ? "Release to cancel" : "Release to send")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(holdCancels ? Design.Color.danger : Design.Color.textSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VoiceMeterView(
                    levels: Array(voice.meterLevels.suffix(isInline ? 10 : 16)),
                    isActive: true,
                    tint: Design.Color.ember,
                    spacing: 2
                )
                .frame(height: 20)
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isHolding ? "Recording. Release to send." : "Recording")
        .accessibilityValue(VoiceCopy.clock(voice.elapsedTime))
        .accessibilityIdentifier("capture.recording")
    }

    // MARK: Trailing controls

    /// ✕ on the trailing edge, away from the left thumb: drops the
    /// recording (or a kept one, or a transcription in flight).
    private var discardButton: some View {
        Button(action: discardRecording) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Design.Color.textSecondary)
                .frame(width: 32, height: 32)
                .background(Design.Color.surface3, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isHolding)
        .accessibilityLabel("Discard recording")
        .accessibilityIdentifier("capture.discard")
    }

    private var draftSendButton: some View {
        Button {
            send()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Design.Color.onEmber)
                .frame(width: 32, height: 32)
                .background(Design.Color.ember, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send to Shudo")
        .accessibilityIdentifier("capture.send")
    }

    private var composerButton: some View {
        Menu {
            Button("Type a meal", systemImage: "square.and.pencil") { actions.openComposer(false) }
            Button("Scan barcode", systemImage: "barcode.viewfinder") { actions.scanBarcode() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Design.Color.textSecondary)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        } primaryAction: {
            actions.openComposer(false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Log meal")
        .accessibilityHint("Opens the meal composer. Touch and hold to scan a barcode.")
    }

    private var cameraMenu: some View {
        Menu {
            Button("Meal photo", systemImage: "fork.knife") { actions.mealPhoto() }
            Button("Scan barcode", systemImage: "barcode.viewfinder") { actions.scanBarcode() }
            Button("Workout photo", systemImage: "dumbbell.fill") { actions.workoutPhoto() }
            Button("Check-in photo", systemImage: "figure.arms.open") { actions.checkIn() }
        } label: {
            Image(systemName: "camera.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Design.Color.textSecondary)
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Camera")
        .accessibilityHint("Meal photo, barcode, workout photo or check-in")
    }

    // MARK: Actions

    /// Stop → "Transcribing…" → the text goes to Shudo. A failed upload
    /// leaves the Retry state; nothing heard says so.
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
        show(notice: "Recording discarded")
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

/// The typing surface: the tab bar's accessory sits under the keyboard, so
/// "Tell Shudo anything…" opens this glass field docked right above it,
/// bound to the same draft. Losing focus (swipe the thread, tap away)
/// tucks it back into the bar with the draft kept.
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
                Image(systemName: "mic.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Design.Color.onEmber)
                    .frame(width: 36, height: 36)
                    .background(Design.Color.emberFill, in: Circle())
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
            .padding(.vertical, 8)
            .accessibilityIdentifier("capture.input")
            .onChange(of: draft.text) { _, text in
                if text.isEmpty { draft.speechEngine = nil }
            }

            Button {
                onSend()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Design.Color.onEmber)
                    .frame(width: 34, height: 34)
                    .background(draft.isEmpty ? Design.Color.surface3 : Design.Color.ember, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty)
            .accessibilityLabel("Send to Shudo")
            .accessibilityIdentifier("capture.input.send")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
