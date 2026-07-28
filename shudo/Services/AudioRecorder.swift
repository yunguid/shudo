import AVFoundation
import Foundation
import os

@MainActor
final class AudioRecorder: NSObject, ObservableObject, @preconcurrency AVAudioRecorderDelegate {
    nonisolated static let maximumDuration: TimeInterval = 15 * 60

    @Published private(set) var isRecording = false
    /// True while the audio session activates and the recorder warms up.
    /// Session activation is a blocking system call that can take seconds
    /// (Bluetooth negotiation, post-picker handoff), so the UI shows a
    /// starting state instead of freezing or silently ignoring the tap.
    @Published private(set) var isStartingRecording = false
    @Published private(set) var recordedFileURL: URL?
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var meterLevels: [CGFloat] = Array(repeating: 0.06, count: 28)
    @Published private(set) var didReachMaximumDuration = false
    @Published var errorMessage: String?

    nonisolated static let startTimeout: TimeInterval = 12
    /// Right after a camera or picker dismissal the audio hardware is still
    /// being handed back to the app, and activation or record() fails for a
    /// beat before recovering. Retry a bounded number of times so those
    /// transients never read as a dead microphone, while a genuinely broken
    /// start still surfaces its real error quickly.
    nonisolated static let maximumStartAttempts = 6
    nonisolated static let startRetryDelay: TimeInterval = 0.4

    /// Every AVAudioSession mutation runs on this one serial queue. Stops
    /// used to deactivate via unordered fire-and-forget tasks, so a stale
    /// deactivation could land after the next start's activation and kill
    /// the new recording.
    private nonisolated static let sessionQueue = DispatchQueue(
        label: "shudo.audio-session",
        qos: .userInitiated
    )

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startedAt: Date?
    private var systemAudioObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        observeSystemAudioNotifications()
        // Category configuration is sticky and does not touch the microphone
        // or other apps' audio; doing it once at creation keeps that IPC off
        // the tap-to-recording critical path.
        Self.prewarmSessionCategory()
    }

    deinit {
        for token in systemAudioObservers {
            NotificationCenter.default.removeObserver(token)
        }
        // A recorder torn down without a finish path must not leave a live
        // timer firing forever. deinit can run off the main thread, and
        // Timer.invalidate is only safe on the installing run loop's thread,
        // so route the call to the main thread without capturing the timer
        // in a closure (Timer is not Sendable).
        meterTimer?.perform(
            #selector(Timer.invalidate),
            on: .main,
            with: nil,
            waitUntilDone: false
        )
    }

    var remainingTime: TimeInterval {
        Self.remainingTime(after: elapsedTime)
    }

    static func remainingTime(after elapsedTime: TimeInterval) -> TimeInterval {
        max(0, maximumDuration - max(0, elapsedTime))
    }

    func startRecording() async -> Bool {
        guard !Task.isCancelled, !isRecording, !isStartingRecording else { return false }
        Perf.mark("mic.start.begin")
        errorMessage = nil
        // Discard before flagging the start: discardRecording clears
        // isStartingRecording so a composer teardown can abort a warm-up
        // already in flight.
        discardRecording()
        isStartingRecording = true
        defer { isStartingRecording = false }

        let granted = await requestPermission()
        guard !Task.isCancelled, isStartingRecording else { return false }
        guard granted else {
            errorMessage = "Microphone access is required to record a meal."
            return false
        }
        Perf.mark("mic.permission.ok")

        let url = Self.makeTempURL()
        do {
            // Session activation and input warm-up are blocking system calls
            // that can take seconds; running them on the main actor froze the
            // whole composer and made queued taps stop the recording the
            // moment it finally began.
            let recorder = try await Self.startRecorderRetryingWithinDeadline {
                try Self.activateSessionAndStartRecorder(url: url)
            }
            guard !Task.isCancelled, isStartingRecording else {
                // The composer went away while the recorder warmed up.
                recorder.stop()
                try? FileManager.default.removeItem(at: url)
                Self.deactivateSessionInBackground()
                return false
            }

            recorder.delegate = self
            self.recorder = recorder
            recordedFileURL = url
            startedAt = Date()
            elapsedTime = 0
            didReachMaximumDuration = false
            isRecording = true
            startMetering()
            Perf.mark("mic.record.live")
            return true
        } catch {
            Perf.mark("mic.start.fail")
            isRecording = false
            recordedFileURL = nil
            errorMessage = (error as? AudioStartError)?.message
                ?? "The microphone couldn’t start. Try again."
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    private struct AudioStartError: Error {
        let message: String
    }

    /// Serialized on `sessionQueue`. Set on first configure; cleared when a
    /// media-services reset wipes the session's state.
    private nonisolated(unsafe) static var sessionCategoryConfigured = false

    /// Applies the recording category off the critical path. Safe to run at
    /// any time: category alone never interrupts other audio or lights the
    /// microphone indicator — only activation does.
    nonisolated static func prewarmSessionCategory() {
        sessionQueue.async { try? configureSessionCategoryIfNeeded() }
    }

    private nonisolated static func configureSessionCategoryIfNeeded() throws {
        guard !sessionCategoryConfigured else { return }
        try AVAudioSession.sharedInstance().setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        sessionCategoryConfigured = true
    }

    private nonisolated static func activateSessionAndStartRecorder(
        url: URL
    ) throws -> AVAudioRecorder {
        Perf.mark("mic.session.begin")
        let session = AVAudioSession.sharedInstance()
        try configureSessionCategoryIfNeeded()
        try session.setActive(true)
        Perf.mark("mic.session.active")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record(forDuration: maximumDuration) else {
            throw AudioStartError(message: "Recording could not start.")
        }
        return recorder
    }

    /// Runs the blocking start work off the main actor, retrying transient
    /// failures, bounded so a wedged audio server surfaces as a retryable
    /// error instead of a stuck button. Attempts run serially on the session
    /// queue with a session reset between tries: right after a camera or
    /// picker dismissal the first activation often fails or record() returns
    /// false while the hardware is handed back, and a one-shot start read as
    /// a dead microphone. Deliberately an unstructured race: a task group
    /// would await the uncancellable blocked child before rethrowing,
    /// defeating the deadline.
    nonisolated static func startRecorderRetryingWithinDeadline(
        deadline: TimeInterval = startTimeout,
        retryDelay: TimeInterval = startRetryDelay,
        maximumAttempts: Int = maximumStartAttempts,
        attempt: @escaping () throws -> AVAudioRecorder
    ) async throws -> AVAudioRecorder {
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
                        let recorder = try sessionQueue.sync { try attempt() }
                        if claimResume() {
                            continuation.resume(returning: recorder)
                        } else {
                            // The deadline already fired; stop the orphan so
                            // it cannot keep recording invisibly.
                            recorder.stop()
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
                try? await Task.sleep(
                    nanoseconds: UInt64(deadline * 1_000_000_000)
                )
                if claimResume() {
                    continuation.resume(throwing: AudioStartError(
                        message: "The microphone is taking too long to start. Try again."
                    ))
                }
            }
        }
    }

    private nonisolated static func deactivateSessionInBackground() {
        sessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    func stopRecording() {
        finishActiveRecording(reachedMaximum: false)
    }

    /// Cancels an in-flight microphone warm-up without touching a finished
    /// voice note. Media buttons call this before presenting the camera or a
    /// picker so a warm-up can't complete into a live recording underneath a
    /// system capture surface, which would then kill it and strand the UI.
    func abortStartingRecording() {
        isStartingRecording = false
    }

    func recordedData() -> Data? {
        guard let recordedFileURL else { return nil }
        return try? Data(contentsOf: recordedFileURL, options: .mappedIfSafe)
    }

    func discardRecording() {
        if isRecording { stopRecording() }
        // Aborts an in-flight start: the warm-up continuation checks this
        // flag and tears its recorder down instead of surfacing it.
        isStartingRecording = false
        if let recordedFileURL { try? FileManager.default.removeItem(at: recordedFileURL) }
        recordedFileURL = nil
        recorder = nil
        startedAt = nil
        elapsedTime = 0
        didReachMaximumDuration = false
        meterLevels = Array(repeating: 0.06, count: 28)
    }

    func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        guard self.recorder === recorder, isRecording else { return }
        let duration = currentDuration(recorder: recorder)
        finishSystemEndedRecording(
            error: flag ? nil : "Recording stopped before it could be saved.",
            duration: duration,
            reachedMaximum: flag && Self.remainingTime(after: duration) <= 0.5
        )
    }

    func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error: Error?
    ) {
        guard self.recorder === recorder else { return }
        finishSystemEndedRecording(
            error: error?.localizedDescription ?? "Recording couldn’t be saved.",
            duration: currentDuration(recorder: recorder),
            reachedMaximum: false
        )
    }

    private func observeSystemAudioNotifications() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        systemAudioObservers = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated { self?.handleInterruption(notification) }
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleMediaServicesReset() }
            }
        ]
    }

    /// The system can end a recording without any delegate callback — a
    /// phone call, Siri, or another capture session taking the input. Finish
    /// honestly and keep the audio captured so far; stale isRecording state
    /// otherwise turns the next mic tap into a silent no-op stop.
    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: rawType) == .began,
              isRecording else { return }
        finishActiveRecording(reachedMaximum: false)
    }

    /// After a media-server crash every audio object this class holds is
    /// dead and the file under it is unreliable; drop the take and say so.
    private func handleMediaServicesReset() {
        // The reset wiped the session's configuration; the next start must
        // re-apply the category.
        Self.sessionQueue.async { Self.sessionCategoryConfigured = false }
        guard isRecording else { return }
        finishSystemEndedRecording(
            error: "Recording was interrupted by a system audio reset. Record again.",
            duration: currentDuration(recorder: recorder),
            reachedMaximum: false
        )
    }

    private func requestPermission() async -> Bool {
        // Already-granted permission answers synchronously; the async request
        // is only needed to show the system prompt (or confirm a denial).
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func startMetering() {
        stopMetering()
        // A block timer with a weak reference lets the recorder deallocate
        // even if a finish path is somehow bypassed; a target/selector timer
        // would retain it through the run loop.
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleMeters() }
        }
        meterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func sampleMeters() {
        recorder?.updateMeters()
        let decibels = recorder?.averagePower(forChannel: 0) ?? -60
        let amplitude = max(0.035, min(1, pow(10, CGFloat(decibels) / 24)))
        meterLevels.append(amplitude)
        if meterLevels.count > 28 { meterLevels.removeFirst() }
        elapsedTime = currentDuration(recorder: recorder)
        if remainingTime == 0 {
            finishActiveRecording(reachedMaximum: true)
        }
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func finishActiveRecording(reachedMaximum: Bool) {
        guard isRecording else { return }
        let activeRecorder = recorder
        let duration = currentDuration(recorder: activeRecorder)
        recorder = nil
        activeRecorder?.stop()
        isRecording = false
        stopMetering()
        elapsedTime = reachedMaximum ? Self.maximumDuration : duration
        didReachMaximumDuration = reachedMaximum
        Self.deactivateSessionInBackground()
    }

    private func finishSystemEndedRecording(
        error: String?,
        duration: TimeInterval,
        reachedMaximum: Bool
    ) {
        recorder = nil
        isRecording = false
        stopMetering()
        elapsedTime = reachedMaximum ? Self.maximumDuration : duration
        didReachMaximumDuration = reachedMaximum
        if let error {
            errorMessage = error
            if let recordedFileURL { try? FileManager.default.removeItem(at: recordedFileURL) }
            recordedFileURL = nil
        }
        Self.deactivateSessionInBackground()
    }

    private func currentDuration(recorder: AVAudioRecorder?) -> TimeInterval {
        let recorderTime = recorder?.currentTime ?? 0
        let wallTime = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        return min(Self.maximumDuration, max(0, max(recorderTime, wallTime)))
    }

    private static func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shudo-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
    }
}
