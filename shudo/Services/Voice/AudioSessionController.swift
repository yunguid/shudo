import AVFoundation
import Foundation
import os

/// System audio events relevant to whoever currently owns the microphone.
enum AudioSessionEvent: Equatable, Sendable {
    /// A phone call, Siri, or another app's capture took the session.
    case interruptionBegan
    /// The media server crashed; every audio object is dead.
    case mediaServicesReset
    /// Another voice surface in Shudo claimed the session.
    case preempted
}

/// The one place that configures, activates, and deactivates the shared
/// AVAudioSession for voice capture (meal composer, correction sheet,
/// onboarding, coach). Extracted from the original AudioRecorder with the
/// same guarantees:
///
/// - every session mutation runs on one serial queue, so a stale
///   deactivation can never land after the next start's activation;
/// - starts retry transient failures (post-camera/picker hardware handoff)
///   within a hard deadline;
/// - interruption, media-services-reset and route-change notifications are
///   observed once and routed to the single current owner.
@MainActor
final class AudioSessionController {
    static let shared = AudioSessionController()

    struct OwnerToken: Hashable, Sendable {
        fileprivate let id = UUID()
    }

    nonisolated static let startTimeout: TimeInterval = 12
    /// Right after a camera or picker dismissal the audio hardware is still
    /// being handed back to the app, and activation or the input start fails
    /// for a beat before recovering. Retry a bounded number of times so those
    /// transients never read as a dead microphone, while a genuinely broken
    /// start still surfaces its real error quickly.
    nonisolated static let maximumStartAttempts = 6
    nonisolated static let startRetryDelay: TimeInterval = 0.4

    /// Every AVAudioSession mutation runs on this one serial queue.
    nonisolated static let sessionQueue = DispatchQueue(
        label: "shudo.audio-session",
        qos: .userInitiated
    )

    nonisolated static let categoryOptions: AVAudioSession.CategoryOptions = [
        .defaultToSpeaker,
        .allowBluetoothHFP,
    ]

    private var owner: (token: OwnerToken, onEvent: (AudioSessionEvent) -> Void)?
    private var observers: [NSObjectProtocol] = []

    private init() {
        observeSystemAudioNotifications()
        // Category configuration does not touch the microphone or other
        // apps' audio; doing it once up front keeps that IPC off the
        // tap-to-listening critical path.
        Self.prewarmSessionCategory()
    }

    // MARK: Ownership

    /// Makes the caller the session's single owner. A previous owner is told
    /// it was preempted so it can end its take honestly.
    func claim(onEvent: @escaping (AudioSessionEvent) -> Void) -> OwnerToken {
        let previous = owner
        let token = OwnerToken()
        owner = (token, onEvent)
        previous?.onEvent(.preempted)
        return token
    }

    func release(_ token: OwnerToken) {
        guard owner?.token == token else { return }
        owner = nil
    }

    func isOwner(_ token: OwnerToken) -> Bool {
        owner?.token == token
    }

    // MARK: Permission

    nonisolated static var hasRecordPermission: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Already-granted permission answers synchronously; the async request
    /// is only needed to show the system prompt (or confirm a denial).
    static func requestRecordPermission() async -> Bool {
        if hasRecordPermission { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: Session configuration (serialized on sessionQueue)

    /// Applies the voice category off the critical path. Safe at any time:
    /// the category alone never interrupts other audio or lights the
    /// microphone indicator — only activation does.
    nonisolated static func prewarmSessionCategory() {
        sessionQueue.async { try? configureSessionCategoryIfNeeded() }
    }

    /// Re-applies the category whenever something else changed it (the
    /// weigh-in recognizer used to leave `.measurement`/`.duckOthers`
    /// behind), instead of trusting a cached flag. The getters are local
    /// reads; only an actual change pays for the IPC.
    nonisolated static func configureSessionCategoryIfNeeded() throws {
        let session = AVAudioSession.sharedInstance()
        if session.category == .playAndRecord,
           session.mode == .spokenAudio,
           session.categoryOptions == categoryOptions {
            return
        }
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: categoryOptions)
    }

    /// Must run on `sessionQueue` (inside a start attempt).
    nonisolated static func activateSession() throws {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        Perf.mark("mic.session.begin")
        try configureSessionCategoryIfNeeded()
        try AVAudioSession.sharedInstance().setActive(true)
        Perf.mark("mic.session.active")
    }

    nonisolated static func deactivateSessionInBackground() {
        sessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    struct StartTimedOut: LocalizedError {
        var errorDescription: String? { VoiceCopy.microphoneSlow }
    }

    /// Runs blocking start work off the main actor, retrying transient
    /// failures, bounded so a wedged audio server surfaces as a retryable
    /// error instead of a stuck button. Attempts run serially on the session
    /// queue with a session reset between tries. Deliberately an
    /// unstructured race: a task group would await the uncancellable blocked
    /// child before rethrowing, defeating the deadline. A result that lands
    /// after the deadline fired is handed to `discardOrphan` so it can't keep
    /// the microphone live invisibly.
    nonisolated static func startRetryingWithinDeadline<Started>(
        deadline: TimeInterval = startTimeout,
        retryDelay: TimeInterval = startRetryDelay,
        maximumAttempts: Int = maximumStartAttempts,
        attempt: @escaping () throws -> Started,
        discardOrphan: @escaping (Started) -> Void = { _ in }
    ) async throws -> Started {
        let hasResumed = OSAllocatedUnfairLock(initialState: false)
        func claimResume() -> Bool {
            hasResumed.withLock { resumed in
                if resumed { return false }
                resumed = true
                return true
            }
        }
        func deadlineAlreadyFired() -> Bool {
            hasResumed.withLock { $0 }
        }

        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                var attemptsRemaining = max(1, maximumAttempts)
                while true {
                    do {
                        CaptureDiagnostics.record(.recorderAttempt, state: "starting")
                        let started = try sessionQueue.sync { try attempt() }
                        if claimResume() {
                            continuation.resume(returning: started)
                        } else {
                            discardOrphan(started)
                            deactivateSessionInBackground()
                        }
                        return
                    } catch {
                        attemptsRemaining -= 1
                        // Reset the half-configured session so the next try
                        // (or the next tap) starts clean.
                        deactivateSessionInBackground()
                        if attemptsRemaining <= 0 {
                            if claimResume() {
                                continuation.resume(throwing: error)
                            }
                            return
                        }
                        try? await Task.sleep(
                            nanoseconds: UInt64(retryDelay * 1_000_000_000)
                        )
                        if deadlineAlreadyFired() { return }
                    }
                }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                if claimResume() {
                    continuation.resume(throwing: StartTimedOut())
                }
            }
        }
    }

    // MARK: System notifications

    private func observeSystemAudioNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                MainActor.assumeIsolated { self?.handleInterruption(rawType: rawType) }
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleMediaServicesReset() }
            },
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { _ in
                // A route change alone (AirPods connecting) never ends a take
                // here; if it reconfigures the input, the capture engine's own
                // configuration-change notification ends it honestly.
                MainActor.assumeIsolated {
                    CaptureDiagnostics.record(.audioRouteChanged, state: "route")
                }
            },
        ]
    }

    /// The system can end capture without any other callback — a phone
    /// call, Siri, or another capture session taking the input. The owner
    /// finishes honestly and keeps the text heard so far.
    private func handleInterruption(rawType: UInt?) {
        guard let rawType,
              AVAudioSession.InterruptionType(rawValue: rawType) == .began,
              let owner else { return }
        CaptureDiagnostics.record(.audioInterrupted, state: "interrupted")
        owner.onEvent(.interruptionBegan)
    }

    private func handleMediaServicesReset() {
        CaptureDiagnostics.record(.mediaServicesReset, state: "reset")
        // The reset wiped the session's configuration; re-apply it so the
        // next start doesn't pay for it.
        Self.prewarmSessionCategory()
        owner?.onEvent(.mediaServicesReset)
    }
}
