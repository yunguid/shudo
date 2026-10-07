import Accelerate
import AVFoundation
import Foundation
import os

/// Why live capture ended without the person asking.
enum AudioCaptureEvent: Equatable, Sendable {
    case interrupted
    case mediaServicesReset
    /// The input route or format changed under the engine (AirPods
    /// connecting mid-take). The take ends honestly; no hot-swap.
    case configurationChanged
    case preempted
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
}

/// `AVAudioEngine` input-node tap. Session activation and engine start are
/// blocking system calls, so they run on the session queue with the shared
/// bounded retry; buffer conversion happens in the recognizer's consumer
/// task, never on the audio thread.
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

    private struct NoInput: LocalizedError {
        var errorDescription: String? { VoiceCopy.microphoneFailed }
    }

    private let power = OSAllocatedUnfairLock<Float>(initialState: -160)
    private var live: Live?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var ownerToken: AudioSessionController.OwnerToken?
    private var configurationObserver: NSObjectProtocol?
    private var startGeneration = 0

    var currentPowerDecibels: Float { power.withLock { $0 } }

    func start(onEvent: @escaping @MainActor (AudioCaptureEvent) -> Void) async throws -> AudioCaptureRun {
        stop()
        startGeneration += 1
        let generation = startGeneration
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.continuation = continuation
        power.withLock { $0 = -160 }
        let power = self.power

        ownerToken = AudioSessionController.shared.claim { event in
            switch event {
            case .interruptionBegan: onEvent(.interrupted)
            case .mediaServicesReset: onEvent(.mediaServicesReset)
            case .preempted: onEvent(.preempted)
            }
        }

        let started: Live
        do {
            started = try await AudioSessionController.startRetryingWithinDeadline(
                attempt: {
                    try Self.activateAndStartEngine(continuation: continuation, power: power)
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
        live = started
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: started.engine,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onEvent(.configurationChanged) }
        }
        return AudioCaptureRun(format: started.format, buffers: stream)
    }

    func stop() {
        startGeneration += 1
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        if let live {
            live.tearDown()
            AudioSessionController.deactivateSessionInBackground()
        }
        live = nil
        continuation?.finish()
        continuation = nil
        if let ownerToken {
            AudioSessionController.shared.release(ownerToken)
        }
        ownerToken = nil
    }

    /// Runs on the session queue inside a start attempt.
    private nonisolated static func activateAndStartEngine(
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation,
        power: OSAllocatedUnfairLock<Float>
    ) throws -> Live {
        try AudioSessionController.activateSession()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw NoInput() }
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in
            let decibels = Self.powerDecibels(of: buffer)
            power.withLock { $0 = decibels }
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
