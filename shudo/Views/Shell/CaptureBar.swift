import SwiftUI
import UIKit

/// What the capture bar can ask the shell to do.
struct CaptureBarActions {
    /// Send a message to Shudo (the coach routes meals/workouts via tools).
    var send: (_ text: String, _ mode: CoachInputMode, _ speechEngine: String?) -> Void
    /// The classic meal composer (`autoStartRecording` = quick voice meal).
    var openComposer: (_ autoStartRecording: Bool) -> Void
    var mealPhoto: () -> Void
    var scanBarcode: () -> Void
    var workoutPhoto: () -> Void
    var checkIn: () -> Void
    /// The bar is about to listen or type: a chance to warm location.
    var willCompose: () -> Void = {}
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
}

/// "Tell Shudo anything…" — the one input on every tab, mounted as the
/// TabView's bottom accessory. The ember mic dictates on-device:
/// tap = words stream into the field (edit, then send), hold = talk and
/// release to send (slide left to cancel). The field sends to the coach;
/// "+" opens the classic meal composer; the camera menu routes photos.
struct CaptureBar: View {
    @ObservedObject var voice: VoiceTranscriber
    @Binding var draft: CaptureDraft
    let actions: CaptureBarActions

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    @Environment(\.openURL) private var openURL
    @FocusState private var isFocused: Bool
    @State private var pressStartedAt: Date?
    @State private var holdTask: Task<Void, Never>?
    @State private var isHolding = false
    @State private var holdCancels = false
    @State private var sentCount = 0
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?

    private var isInline: Bool { placement == .inline }
    private var isCapturing: Bool { voice.isBusy }
    private var showsSend: Bool { !draft.isEmpty || voice.isListening }

    var body: some View {
        HStack(spacing: isInline ? 6 : 8) {
            micButton
            field
            if showsSend {
                sendButton
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                if !isInline { composerButton }
                cameraMenu
            }
        }
        .padding(.leading, isInline ? 4 : 6)
        .padding(.trailing, isInline ? 4 : 8)
        .animation(Design.Motion.snap, value: showsSend)
        .sensoryFeedback(.impact(weight: .light), trigger: sentCount)
        .onChange(of: voice.phase) { _, phase in
            // A take the system ended on its own (time limit, interruption)
            // parks as `.ready`; fold it into the draft.
            if phase == .ready, !isHolding, let take = voice.collectReadyTake() {
                draft.append(take)
            }
            if let message = voice.errorMessage { show(notice: message) }
        }
    }

    // MARK: Mic

    private var micButton: some View {
        let size: CGFloat = isInline ? 30 : 36
        return ZStack {
            Circle()
                .fill(Design.Color.emberFill)
                .frame(width: size, height: size)
                .scaleEffect(isHolding ? 1.12 : 1)
                .shadow(color: Design.Color.ember.opacity(isCapturing ? 0.55 : 0.25), radius: isCapturing ? 10 : 6)
            Image(systemName: micSymbol)
                .font(.system(size: isInline ? 13 : 15, weight: .bold))
                .foregroundStyle(Design.Color.onEmber)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.variableColor.iterative, isActive: isHolding)
        }
        .frame(width: size + 6, height: size + 6)
        .contentShape(Circle())
        .gesture(pressGesture)
        .sensoryFeedback(trigger: voice.isListening) { _, listening in listening ? .start : .stop }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isCapturing ? "Stop dictation" : "Talk to Shudo")
        .accessibilityHint(isCapturing ? "Keeps your words in the field" : "Dictates into the field. Hold to talk and send.")
        .accessibilityIdentifier("capture.mic")
        .accessibilityAction { Task { await toggleDictation() } }
        .animation(Design.Motion.snap, value: isHolding)
    }

    private var micSymbol: String {
        if isHolding { return "waveform" }
        if isCapturing { return "stop.fill" }
        return "mic.fill"
    }

    /// One gesture for both: a quick tap toggles dictation into the field; a
    /// hold past ~0.35 s is push-to-talk (release sends, slide left cancels).
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pressStartedAt == nil {
                    pressStartedAt = Date()
                    holdTask?.cancel()
                    guard !voice.isBusy else { return }
                    holdTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        guard !Task.isCancelled, pressStartedAt != nil else { return }
                        isHolding = true
                        holdCancels = false
                        actions.willCompose()
                        isFocused = false
                        _ = await voice.start()
                    }
                }
                if isHolding { holdCancels = value.translation.width < -70 }
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
                    Task { await toggleDictation() }
                }
            }
    }

    private func toggleDictation() async {
        if voice.isBusy {
            if let take = await voice.stop() { draft.append(take) }
            return
        }
        if voice.phase == .ready, let take = voice.collectReadyTake() {
            draft.append(take)
            return
        }
        if voice.needsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
            return
        }
        actions.willCompose()
        isFocused = false
        if !(await voice.start()), let message = voice.errorMessage {
            show(notice: message)
        }
    }

    private func finishHold(cancelled: Bool) async {
        if cancelled {
            voice.cancel()
            show(notice: "Cancelled")
            return
        }
        if let take = await voice.stop() { draft.append(take) }
        send()
    }

    // MARK: Field

    private var field: some View {
        ZStack(alignment: .leading) {
            if isCapturing {
                liveTranscript
            } else if let notice {
                Text(notice)
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.honey)
                    .lineLimit(1)
                    .transition(.opacity)
            }
            TextField(
                "",
                text: $draft.text,
                prompt: Text(isInline ? "Tell Shudo…" : "Tell Shudo anything…")
                    .foregroundStyle(Design.Color.textTertiary)
            )
            .font(.body)
            .foregroundStyle(Design.Color.textPrimary)
            .tint(Design.Color.ember)
            .focused($isFocused)
            .submitLabel(.send)
            .onSubmit(send)
            .opacity(isCapturing || notice != nil ? 0 : 1)
            .disabled(isCapturing)
            .accessibilityIdentifier("capture.field")
            .onChange(of: isFocused) { _, focused in
                if focused { actions.willCompose() }
            }
            .onChange(of: draft.text) { _, text in
                if text.isEmpty { draft.speechEngine = nil }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        // Long-press on the empty field: the classic meal composer.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                guard draft.isEmpty, !isFocused, !isCapturing else { return }
                actions.openComposer(false)
            }
        )
    }

    private var liveTranscript: some View {
        let heard = voice.transcript.displayText
        let prefix = draft.trimmed
        let text = [prefix, heard].filter { !$0.isEmpty }.joined(separator: " ")
        return Text(text.isEmpty ? (voice.isStarting ? "Starting…" : "Listening…") : text)
            .font(.body)
            .foregroundStyle(text.isEmpty ? Design.Color.textTertiary : Design.Color.textPrimary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Live transcript")
            .accessibilityValue(text)
            .accessibilityIdentifier("capture.live")
    }

    // MARK: Trailing controls

    private var sendButton: some View {
        Button {
            if voice.isBusy {
                Task {
                    if let take = await voice.stop() { draft.append(take) }
                    send()
                }
            } else {
                send()
            }
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
            Button("Quick voice meal", systemImage: "mic.badge.plus") { actions.openComposer(true) }
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
        .accessibilityHint("Opens the meal composer. Touch and hold for more.")
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

    private func send() {
        let text = draft.trimmed
        guard !text.isEmpty else { return }
        let engine = draft.speechEngine
        actions.send(text, engine == nil ? .typed : .dictated, engine)
        draft.clear()
        isFocused = false
        sentCount += 1
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
