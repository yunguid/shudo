import SwiftUI
import UIKit

/// The shared dictation control for the meal composer, the correction sheet
/// and onboarding: level meter, timer, the words as they are heard
/// (committed in ink, the still-changing tail muted), undo for the last
/// take, and the mic button. Finished takes are handed to `onTake`; the
/// owning screen appends them to its editable note.
///
/// This view observes the transcriber, so the ~16 Hz meter and transcript
/// updates re-render only the card, never the screen's text editor.
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
            idleDetail: "Tap to talk — your words land in the note",
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
            idleDetail: "Tap to talk — your words land in the note",
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
            idleDetail: "Tap to talk — your words land below",
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
                Text(headline)
                    .font(voice.isListening ? .system(size: 26, weight: .medium) : .headline)
                    .monospacedDigit()
                    .foregroundStyle(Design.Color.ink)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                Text(detail)
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(Design.Color.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if voice.isListening || voice.isFinishing {
                liveTranscript
                    .transition(.opacity)
            }

            statusLine

            HStack(spacing: 16) {
                if canUndo && !voice.isBusy {
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

    private var liveTranscript: some View {
        let transcript = voice.transcript
        let committed = Text(transcript.displayCommitted).foregroundStyle(Design.Color.ink)
        let tail = Text(transcript.displayVolatile).foregroundStyle(Design.Color.muted)
        return Group {
            if transcript.isEmpty {
                Text(voice.isFinishing ? "…" : "Listening…")
                    .foregroundStyle(Design.Color.subtle)
            } else {
                Text("\(committed)\(tail)")
            }
        }
        .font(.body)
        .lineLimit(4)
        .truncationMode(.head)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live transcript")
        .accessibilityValue(transcript.displayText)
        .accessibilityIdentifier("Live transcript")
    }

    @ViewBuilder
    private var statusLine: some View {
        if let error = voice.errorMessage {
            VStack(spacing: 8) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Design.Color.danger)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
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
                ? "Adds what you said to the note"
                : "Transcribes your voice on this iPhone"
        )
    }

    // MARK: Copy

    private var headline: String {
        switch voice.phase {
        case .starting: return "Starting…"
        case .listening: return VoiceCopy.clock(voice.elapsedTime)
        case .finishing: return "Finishing…"
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
            case .remaining: return "\(VoiceCopy.clock(voice.remainingTime)) remaining · tap when done"
            case .elapsed, .none: return "Tap when you’re done"
            }
        case .finishing:
            return "Writing down the last words"
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
            return "Finishing dictation"
        case .preparingModel(let progress):
            return VoiceCopy.preparing(progress: progress)
        case .idle, .ready, .unavailable, .failed:
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

    private func deliver(_ take: VoiceTake) {
        onTake(take)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIAccessibility.post(notification: .announcement, argument: "Added to your note")
    }
}

/// Bar meter shared by every voice surface.
struct VoiceMeterView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let levels: [CGFloat]
    let isActive: Bool
    var tint: Color = Design.Color.accentPrimary

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 4
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
