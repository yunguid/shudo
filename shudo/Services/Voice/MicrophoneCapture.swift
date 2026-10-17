import Accelerate
import AVFoundation
import Foundation
import os

/// Why live capture ended without the person asking.
enum AudioCaptureEvent: Equatable, Sendable {
    /// A phone call, Siri, or another app took the microphone.
    case interrupted
    case mediaServicesReset
    case preempted
    /// A route or format change stopped the input and it couldn't be
    /// reopened. (A change that can be reopened never ends the take.)
    case inputLost
}

/// Live microphone input. `buffers` buffers without bound, so words spoken
/// before the recognizer is ready are kept and fed in once it is.
struct AudioCaptureRun {
    let format: AVAudioFormat
    let buffers: AsyncStream<AVAudioPCMBuffer>
}

@MainActor
protocol AudioCapturing: AnyObject {
    /// Activates the shared session and starts delivering input buffers.
    func start(onEvent: @escaping @MainActor (AudioCaptureEvent) -> Void) async throws -> AudioCaptureRun
    /// Synchronously stops the input — freeing the microphone for the camera
    /// or a picker — and finishes the buffer stream. Safe to call repeatedly.
    func stop()
    /// Latest input power in dBFS (≤ 0), sampled by the meter tick.
    var currentPowerDecibels: Float { get }
    /// Waits until the input carries real sound — not the digital silence a
    /// Bluetooth headset sends while its microphone link comes up — or until
    /// `timeout`. Returns whether it heard anything.
    func waitUntilHearing(timeout: TimeInterval) async -> Bool
}

extension AudioCapturing {
    func waitUntilHearing(timeout: TimeInterval) async -> Bool { true }
}

/// `AVAudioEngine` input-node tap. Session activation and engine start are
/// blocking system calls, so they run on the session queue with the shared
/// bounded retry; buffer conversion happens in the recognizer's consumer
/// task, never on the audio thread.
///
/// A route or format change mid-take (AirPods switching to their mic, a
/// car, a headset pulled out) stops the engine. The capture reopens the
/// input on the new route and keeps feeding the same stream, so the take
/// carries on into the same recording (its consumer converts the new
/// format) instead of ending at the change and dropping everything said
/// after it.
@MainActor
final class MicrophoneCapture: AudioCapturing {
    private final class Live: @unchecked Sendable {
        let engine: AVAudioEngine
        let format: AVAudioFormat

        init(engine: AVAudioEngine, format: AVAudioFormat) {
            self.engine = engine
            self.format = format
        }

        func tearDown() {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    /// What the tap shares with the main actor.
    private struct Signal: Sendable {
        var decibels: Float = -160
        /// Uptime (ns) of the latest buffer, or of the last (re)start.
        var lastBufferAt: UInt64 = 0
    }

    private struct NoInput: LocalizedError {
        var errorDescription: String? { VoiceCopy.microphoneFailed }
    }

    /// Quieter than this is digital silence, not a live microphone: even a
    /// still room sits around -60 to -90 dBFS.
    nonisolated static let liveSignalFloor: Float = -110
    /// How long reopening the input after a route change may take.
    nonisolated static let reopenDeadline: TimeInterval = 4
    /// A stopped engine that has delivered nothing for this long died
    /// without posting a configuration change.
    nonisolated static let stallInterval: TimeInterval = 1.2

    private let signal = OSAllocatedUnfairLock(initialState: Signal())
    private var live: Live?
    /// From a successful start until `stop()`: the session and the stream
    /// are this take's, even while the input is being reopened.
    private var ownsSession = false
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var onEvent: (@MainActor (AudioCaptureEvent) -> Void)?
    private var ownerToken: AudioSessionController.OwnerToken?
    private var configurationObserver: NSObjectProtocol?
    private var reopenTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var startGeneration = 0

    var currentPowerDecibels: Float { signal.withLock { $0.decibels } }

    func start(onEvent: @escaping @MainActor (AudioCaptureEvent) -> Void) async throws -> AudioCaptureRun {
        stop()
        startGeneration += 1
        let generation = startGeneration
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.continuation = continuation
        self.onEvent = onEvent
        signal.withLock { $0 = Signal() }
        let signal = self.signal

        ownerToken = AudioSessionController.shared.claim { [weak self] event in
            switch event {
            case .interruptionBegan: onEvent(.interrupted)
            case .routeLost: self?.scheduleReopen(reason: "route_lost")
            case .mediaServicesReset: onEvent(.mediaServicesReset)
            case .preempted: onEvent(.preempted)
            }
        }

        let started: Live
        do {
            started = try await AudioSessionController.startRetryingWithinDeadline(
                attempt: {
                    try Self.activateAndStartEngine(continuation: continuation, signal: signal)
                },
                discardOrphan: { orphan in orphan.tearDown() }
            )
        } catch {
            if generation == startGeneration { stop() }
            throw error
        }

        guard generation == startGeneration else {
            // stop() ran while the engine warmed up; don't surface it.
            started.tearDown()
            AudioSessionController.deactivateSessionInBackground()
            throw CancellationError()
        }
        ownsSession = true
        attach(started)
        startWatchdog()
        return AudioCaptureRun(format: started.format, buffers: stream)
    }

    func stop() {
        startGeneration += 1
        watchdog?.cancel()
        watchdog = nil
        // A reopen still running sees the new generation and discards what
        // it started.
        reopenTask = nil
        detachConfigurationObserver()
        live?.tearDown()
        live = nil
        if ownsSession {
            AudioSessionController.deactivateSessionInBackground()
        }
        ownsSession = false
        continuation?.finish()
        continuation = nil
        onEvent = nil
        if let ownerToken {
            AudioSessionController.shared.release(ownerToken)
        }
        ownerToken = nil
    }

    func waitUntilHearing(timeout: TimeInterval) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        while currentPowerDecibels <= Self.liveSignalFloor {
            guard DispatchTime.now().uptimeNanoseconds < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    // MARK: Route changes

    private func attach(_ started: Live) {
        live = started
        signal.withLock { $0.lastBufferAt = DispatchTime.now().uptimeNanoseconds }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: started.engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReopen(reason: "format_change") }
        }
    }

    /// Reopens after the notification handler returns: the engine must not
    /// be torn down or released from inside its own configuration-change
    /// callback (Apple: that can deadlock).
    private func scheduleReopen(reason: String) {
        let generation = startGeneration
        Task { [weak self] in
            guard let self, generation == self.startGeneration else { return }
            self.reopenInput(reason: reason)
        }
    }

    private func detachConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
    }

    /// Reopens the input on whatever route the system moved to, feeding the
    /// same stream. Only when that fails (no input left) does the take end,
    /// keeping what it recorded.
    private func reopenInput(reason: String) {
        guard ownsSession, reopenTask == nil, let continuation else { return }
        CaptureDiagnostics.record(.recorderReopening, state: reason)
        detachConfigurationObserver()
        live?.tearDown()
        live = nil
        signal.withLock { $0.decibels = -160 }
        let generation = startGeneration
        let signal = self.signal
        reopenTask = Task { [weak self] in
            let reopened = try? await AudioSessionController.startRetryingWithinDeadline(
                deadline: Self.reopenDeadline,
                attempt: {
                    try Self.activateAndStartEngine(continuation: continuation, signal: signal)
                },
                discardOrphan: { orphan in orphan.tearDown() }
            )
            guard let self, generation == self.startGeneration else {
                // The take ended meanwhile.
                if let reopened {
                    reopened.tearDown()
                    AudioSessionController.deactivateSessionInBackground()
                }
                return
            }
            self.reopenTask = nil
            guard let reopened else {
                CaptureDiagnostics.record(.recorderReopenFailed, state: reason)
                self.onEvent?(.inputLost)
                return
            }
            self.attach(reopened)
            CaptureDiagnostics.record(.recorderReopened, state: reason)
        }
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self else { return }
                self.reopenIfStalled()
            }
        }
    }

    /// An engine can stop without posting a configuration change (a
    /// Bluetooth route flapping): a stopped engine that has gone quiet is
    /// reopened like any other route change.
    private func reopenIfStalled() {
        guard ownsSession, reopenTask == nil, let live, !live.engine.isRunning else { return }
        let last = signal.withLock { $0.lastBufferAt }
        let quiet = DispatchTime.now().uptimeNanoseconds &- last
        guard quiet > UInt64(Self.stallInterval * 1_000_000_000) else { return }
        reopenInput(reason: "stalled")
    }

    /// Runs on the session queue inside a start attempt.
    private nonisolated static func activateAndStartEngine(
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        signal: OSAllocatedUnfairLock<Signal>
    ) throws -> Live {
        try AudioSessionController.activateSession()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NoInput() }
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in
            let decibels = Self.powerDecibels(of: buffer)
            let now = DispatchTime.now().uptimeNanoseconds
            signal.withLock {
                $0.decibels = decibels
                $0.lastBufferAt = now
            }
            if let copy = buffer.shudoCopy() {
                continuation.yield(copy)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        return Live(engine: engine, format: format)
    }

    /// RMS of the first channel in dBFS; float formats only (the input node
    /// always delivers float), silence otherwise.
    nonisolated static func powerDecibels(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            return -160
        }
        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(buffer.frameLength))
        guard rms > 0 else { return -160 }
        return max(-160, 20 * log10(rms))
    }
}

enum VoiceMeterPolicy {
    static let barCount = 28
    static let restingLevel: CGFloat = 0.06
    static let floorLevel: CGFloat = 0.035
    static let tickInterval: TimeInterval = 0.06

    static var restingLevels: [CGFloat] { Array(repeating: restingLevel, count: barCount) }

    /// The same perceptual curve the recorder meter always used.
    static func amplitude(decibels: Float) -> CGFloat {
        max(floorLevel, min(1, pow(10, CGFloat(decibels) / 24)))
    }

    static func appending(_ level: CGFloat, to levels: [CGFloat]) -> [CGFloat] {
        var updated = levels
        updated.append(level)
        if updated.count > barCount { updated.removeFirst(updated.count - barCount) }
        return updated
    }
}
