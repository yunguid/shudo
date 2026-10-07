import SwiftUI
import UIKit

/// The shared voice control for the meal composer, the correction sheet,
/// onboarding and the bio: record → stop → "Transcribing…" → the text lands
/// in the owner's editable note (`onTake`). While recording there are no
/// live words, just a pulsing ember dot, the elapsed time, a level meter, a
/// discard ✕ and the stop button. A failed upload keeps the recording and
/// offers Retry / Discard.
///
/// This view observes the transcriber, so the ~16 Hz meter updates
/// re-render only the card, never the screen's text editor.
struct VoiceCaptureCard: View {
    struct Style {
        enum StopDetail {
            case remaining
            case elapsed
            case none
        }

        var idleHeadline: String
        var idleDetail: String
        var startLabel: String
        var stopLabel: String
        var stopDetail: StopDetail
        var idleIcon: String
        var meterTint: Color
        var meterHeight: CGFloat
        var showsBackground: Bool
        var undoLabel = "Undo last dictation"

        static let meal = Style(
            idleHeadline: "Describe what you ate",
            idleDetail: "Tap to record — stop, and your words land in the note",
            startLabel: "Start recording",
            stopLabel: "Stop recording",
            stopDetail: .remaining,
            idleIcon: "mic.fill",
            meterTint: Design.Color.accentPrimary,
            meterHeight: 76,
            showsBackground: false
        )

        static let correction = Style(
            idleHeadline: "Speak the correction",
            idleDetail: "Tap to record — stop, and your words land in the note",
            startLabel: "Start correction recording",
            stopLabel: "Stop correction recording",
            stopDetail: .elapsed,
            idleIcon: "mic.fill",
            meterTint: Design.Color.accentSecondary,
            meterHeight: 60,
            showsBackground: true
        )

        static let onboarding = Style(
            idleHeadline: "Describe your goals",
            idleDetail: "Tap to record — stop, and your words land below",
            startLabel: "Start recording",
            stopLabel: "Stop recording",
            stopDetail: .none,
            idleIcon: "waveform",
            meterTint: Design.Color.accentPrimary,
            meterHeight: 66,
            showsBackground: true
        )
    }

    @ObservedObject var voice: VoiceTranscriber
    let style: Style
    var isDisabled = false
    var canUndo = false
    var onUndo: () -> Void = {}
    /// Runs right before a take starts (clear errors, drop keyboard focus).
    var onWillStart: () -> Void = {}
    let onTake: (VoiceTake) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 16) {
            VoiceMeterView(
                levels: voice.meterLevels,
                isActive: voice.isListening,
                tint: style.meterTint
            )
            .frame(height: style.meterHeight)
            .padding(.horizontal, style.showsBackground ? 0 : 18)

            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    if voice.isListening {
                        RecordingPulseDot(size: 10)
                    } else if voice.isFinishing {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Design.Color.ember)
                    }
                    Text(headline)
                        .font(voice.isListening ? .system(size: 26, weight: .medium) : .headline)
                        .monospacedDigit()
                        .foregroundStyle(Design.Color.ink)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                }
                Text(detail)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Design.Color.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("Voice status")

            statusLine

            controls
        }
        .padding(style.showsBackground ? 22 : 0)
        .padding(.vertical, style.showsBackground ? 0 : 8)
        .background {
            if style.showsBackground {
                RoundedRectangle(cornerRadius: Design.Radius.hero, style: .continuous)
                    .fill(Design.Color.elevated)
            }
        }
        .animation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion), value: voice.phase)
        .onChange(of: voice.phase) { _, phase in
            // A take that ended by itself (interruption, limits, a camera
            // tap) is parked; hand it over as soon as it lands.
            if phase == .ready, let take = voice.collectReadyTake() {
                deliver(take)
            }
        }
        .onChange(of: voice.notice) { _, notice in
            if notice == .didNotCatchThat {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var statusLine: some View {
        if let error = voice.errorMessage {
            VStack(spacing: 8) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Design.Color.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("Voice error")
                if voice.needsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(url) }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Design.Color.accentSecondary)
                        .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity)
        } else if let notice = voice.notice, !voice.isBusy {
            Text(notice.message)
                .font(.footnote)
                .foregroundStyle(notice == .didNotCatchThat ? Design.Color.warning : Design.Color.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var controls: some View {
        if voice.canRetryTranscription {
            HStack(spacing: 16) {
                Button(action: discard) {
                    Label("Discard", systemImage: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.muted)
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                        .background(Design.Color.glassFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityLabel("Discard recording")
                .accessibilityIdentifier("Discard recording")

                Button(action: retry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.onEmber)
                        .padding(.horizontal, 22)
                        .frame(height: 48)
                        .background(Design.Color.emberFill, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityLabel("Retry transcription")
                .accessibilityIdentifier("Retry transcription")
            }
        } else {
            HStack(spacing: 16) {
                if voice.isListening {
                    Button(action: discard) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Design.Color.muted)
                            .frame(width: 48, height: 48)
                            .background(Design.Color.glassFill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Discard recording")
                    .accessibilityIdentifier("Discard recording")
                } else if canUndo && !voice.isBusy {
                    Button(action: onUndo) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Design.Color.muted)
                            .frame(width: 48, height: 48)
                            .background(Design.Color.glassFill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                    .accessibilityLabel(style.undoLabel)
                }

                micButton
            }
        }
    }

    private var micButton: some View {
        Button(action: toggle) {
            ZStack {
                Circle()
                    .fill(
                        voice.isListening
                            ? AnyShapeStyle(Design.Color.danger)
                            : AnyShapeStyle(LinearGradient(
                                colors: [Design.Color.accentPrimary, Design.Color.accentSecondary],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                    )
                    .frame(width: 76, height: 76)
                    .opacity(voice.isPreparingModel ? 0.45 : 1)
                    .shadow(
                        color: Design.Color.accentPrimary.opacity(
                            reduceMotion ? 0 : (voice.isListening ? 0.12 : 0.28)
                        ),
                        radius: reduceMotion ? 0 : 24
                    )

                if voice.isStarting || voice.isFinishing {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: voice.isListening ? "stop.fill" : style.idleIcon)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .disabled(isDisabled || voice.isPreparingModel || voice.isFinishing)
        .accessibilityIdentifier("Voice recording control")
        .accessibilityLabel(buttonLabel)
        .accessibilityHint(
            voice.isListening
                ? "Transcribes what you said into the note"
                : "Records your voice, then transcribes it"
        )
    }

    // MARK: Copy

    private var headline: String {
        switch voice.phase {
        case .starting: return "Starting…"
        case .listening: return VoiceCopy.clock(voice.elapsedTime)
        case .finishing: return voice.transcribesOnServer ? VoiceCopy.transcribing : "Finishing…"
        case .transcriptionFailed: return "Couldn’t transcribe"
        case .preparingModel(let progress): return VoiceCopy.preparing(progress: progress)
        case .idle, .ready, .unavailable, .failed: return style.idleHeadline
        }
    }

    private var detail: String {
        switch voice.phase {
        case .starting:
            return "Getting the microphone ready"
        case .listening:
            switch style.stopDetail {
            case .remaining: return "Recording · \(VoiceCopy.clock(voice.remainingTime)) left · tap stop when done"
            case .elapsed, .none: return "Recording · tap stop when you’re done"
            }
        case .finishing:
            return voice.transcribesOnServer ? "Turning your recording into text" : "Writing down the last words"
        case .transcriptionFailed:
            return "Your recording is kept"
        case .preparingModel:
            return "The on-device speech model is downloading. Type in the meantime."
        case .idle, .ready, .unavailable, .failed:
            return style.idleDetail
        }
    }

    private var buttonLabel: String {
        switch voice.phase {
        case .starting:
            return "Starting the microphone"
        case .listening:
            switch style.stopDetail {
            case .remaining:
                return "\(style.stopLabel), \(VoiceCopy.clock(voice.remainingTime)) remaining"
            case .elapsed:
                return "\(style.stopLabel), \(VoiceCopy.clock(voice.elapsedTime)) recorded"
            case .none:
                return style.stopLabel
            }
        case .finishing:
            return voice.transcribesOnServer ? "Transcribing your recording" : "Finishing dictation"
        case .preparingModel(let progress):
            return VoiceCopy.preparing(progress: progress)
        case .idle, .ready, .transcriptionFailed, .unavailable, .failed:
            return style.startLabel
        }
    }

    // MARK: Actions

    private func toggle() {
        CaptureDiagnostics.record(.microphoneTapped, state: voice.controlState)
        // Ignore taps while the microphone warms up; a queued toggle used to
        // stop the take the instant it finally started.
        guard !voice.isStarting else {
            CaptureDiagnostics.record(.microphoneTapRejectedStarting, state: voice.controlState)
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            return
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if voice.isListening {
            CaptureDiagnostics.record(.microphoneTapAcceptedStop, state: voice.controlState)
            Task {
                if let take = await voice.stop() { deliver(take) }
            }
        } else {
            CaptureDiagnostics.record(.microphoneTapAcceptedStart, state: voice.controlState)
            onWillStart()
            Task { await voice.start() }
        }
    }

    private func retry() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            if let take = await voice.retryTranscription() { deliver(take) }
        }
    }

    private func discard() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        voice.cancel()
        UIAccessibility.post(notification: .announcement, argument: "Recording discarded")
    }

    private func deliver(_ take: VoiceTake) {
        onTake(take)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIAccessibility.post(notification: .announcement, argument: "Added to your note")
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
