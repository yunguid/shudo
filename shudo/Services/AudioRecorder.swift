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

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startedAt: Date?

    deinit {
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

        let url = Self.makeTempURL()
        do {
            // Session activation and input warm-up are blocking system calls
            // that can take seconds; running them on the main actor froze the
            // whole composer and made queued taps stop the recording the
            // moment it finally began.
            let recorder = try await Self.withStartDeadline {
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
            return true
        } catch {
            isRecording = false
            recordedFileURL = nil
            errorMessage = (error as? AudioStartError)?.message
                ?? "The microphone couldn’t start. Try again."
            Self.deactivateSessionInBackground()
            return false
        }
    }

    private struct AudioStartError: Error {
        let message: String
    }

    private nonisolated static func activateSessionAndStartRecorder(
        url: URL
    ) throws -> AVAudioRecorder {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true)

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

    /// Runs the blocking start work off the main actor, bounded so a wedged
    /// audio server surfaces as a retryable error instead of a stuck button.
    /// Deliberately an unstructured race: a task group would await the
    /// uncancellable blocked child before rethrowing, defeating the deadline.
    private nonisolated static func withStartDeadline(
        _ work: @escaping () throws -> AVAudioRecorder
    ) async throws -> AVAudioRecorder {
        let hasResumed = OSAllocatedUnfairLock(initialState: false)
        func claimResume() -> Bool {
            hasResumed.withLock { resumed in
                if resumed { return false }
                resumed = true
                return true
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let recorder = try work()
                    if claimResume() {
                        continuation.resume(returning: recorder)
                    } else {
                        // The deadline already fired; stop the orphan so it
                        // cannot keep recording invisibly.
                        recorder.stop()
                        deactivateSessionInBackground()
                    }
                } catch {
                    if claimResume() {
                        continuation.resume(throwing: error)
                    }
                }
            }
            Task.detached {
                try? await Task.sleep(
                    nanoseconds: UInt64(startTimeout * 1_000_000_000)
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
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    func stopRecording() {
        finishActiveRecording(reachedMaximum: false)
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

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
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
