#if DEBUG
import AVFoundation
import Combine
import Foundation

/// Deterministic voice for PolishPreview and UI tests (the Simulator can't
/// run SpeechTranscriber). Launch arguments:
///
///     -shudoScriptedSpeech "two scrambled eggs and toast"
///     -shudoScriptedSpeechMode denied|unavailable|downloading
///
/// The scripted capture never touches AVAudioSession, so tests don't depend
/// on the simulator's microphone permission. The engine streams the script
/// word by word as volatile results and finalizes the whole script on stop.
struct ScriptedVoiceConfiguration: Equatable {
    enum Mode: String {
        case normal
        case denied
        case unavailable
        case downloading
    }

    static let textFlag = "-shudoScriptedSpeech"
    static let modeFlag = "-shudoScriptedSpeechMode"
    static let defaultText = "two scrambled eggs and a slice of toast"

    let text: String
    let mode: Mode

    static var launchValue: ScriptedVoiceConfiguration? {
        parse(ProcessInfo.processInfo.arguments)
    }

    static func parse(_ arguments: [String]) -> ScriptedVoiceConfiguration? {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        let text = value(after: textFlag)
        let mode = value(after: modeFlag).flatMap(Mode.init(rawValue:))
        guard text != nil || mode != nil else { return nil }
        return ScriptedVoiceConfiguration(
            text: text?.isEmpty == false ? text! : defaultText,
            mode: mode ?? .normal
        )
    }

    @MainActor
    var environment: VoiceEnvironment {
        let text = self.text
        let mode = self.mode
        return VoiceEnvironment(
            permissions: ScriptedVoicePermissions(grantsMicrophone: mode != .denied),
            assets: ScriptedSpeechAssets(snapshot: Self.snapshot(for: mode)),
            makeCapture: { ScriptedAudioCapture() },
            makeEngine: { id in ScriptedSpeechEngine(id: id, script: text) },
            vocabulary: { [] }
        )
    }

    static func snapshot(for mode: Mode) -> SpeechAssetSnapshot {
        switch mode {
        case .normal, .denied:
            return SpeechAssetSnapshot(
                transcriber: .installed,
                dictation: .installed,
                supportsOnDeviceRecognizer: true,
                transcriberLocale: Locale(identifier: "en_US"),
                dictationLocale: Locale(identifier: "en_US")
            )
        case .unavailable:
            return SpeechAssetSnapshot(
                transcriber: .unsupported,
                dictation: .unsupported,
                supportsOnDeviceRecognizer: false,
                transcriberLocale: nil,
                dictationLocale: nil
            )
        case .downloading:
            return SpeechAssetSnapshot(
                transcriber: .downloading(progress: 0.42),
                dictation: .unsupported,
                supportsOnDeviceRecognizer: false,
                transcriberLocale: Locale(identifier: "en_US"),
                dictationLocale: nil
            )
        }
    }
}

@MainActor
final class ScriptedVoicePermissions: VoicePermissionProviding {
    private let grantsMicrophone: Bool

    init(grantsMicrophone: Bool) {
        self.grantsMicrophone = grantsMicrophone
    }

    func requestMicrophone() async -> Bool { grantsMicrophone }

    func speechAuthorization(requestIfNeeded: Bool) async -> SpeechAuthorizationState {
        .authorized
    }
}

@MainActor
final class ScriptedSpeechAssets: SpeechAssetProviding {
    @Published private(set) var snapshot: SpeechAssetSnapshot

    init(snapshot: SpeechAssetSnapshot) {
        self.snapshot = snapshot
    }

    var snapshotUpdates: AnyPublisher<SpeechAssetSnapshot, Never> {
        $snapshot.removeDuplicates().eraseToAnyPublisher()
    }

    func prepare() {}

    func resolvedSnapshot() async -> SpeechAssetSnapshot { snapshot }
}

/// Synthetic meter levels, no AVAudioSession, no buffers.
@MainActor
final class ScriptedAudioCapture: AudioCapturing {
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var startedAt = Date()

    var currentPowerDecibels: Float {
        let phase = Date().timeIntervalSince(startedAt) * 7
        return Float(-30 + 14 * sin(phase) + 6 * sin(phase * 2.3))
    }

    func start(onEvent: @escaping @MainActor (AudioCaptureEvent) -> Void) async throws -> AudioCaptureRun {
        // Roughly the real session-activation beat, so "Starting…" renders.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = continuation
        startedAt = Date()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        return AudioCaptureRun(format: format, buffers: stream)
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }
}

/// Streams the script word by word as volatile results; `finish()`
/// finalizes the whole script.
final class ScriptedSpeechEngine: SpeechEngine, @unchecked Sendable {
    let id: SpeechEngineID
    private let script: String
    private let wordInterval: UInt64
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation?
    private var feeder: Task<Void, Never>?

    init(id: SpeechEngineID, script: String, wordInterval: TimeInterval = 0.18) {
        self.id = id
        self.script = script
        self.wordInterval = UInt64(wordInterval * 1_000_000_000)
    }

    func start(locale: Locale, profile: VoiceProfile, vocabulary: [String]) async throws -> SpeechRun {
        let (events, continuation) = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        let words = script.split(separator: " ").map(String.init)
        let interval = wordInterval
        let feeder = Task {
            for count in 1...max(1, words.count) {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                continuation.yield(.volatile(words.prefix(count).joined(separator: " ")))
            }
        }
        lock.withLock {
            self.continuation = continuation
            self.feeder = feeder
        }
        return SpeechRun(format: nil, events: events)
    }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func finish() async throws {
        let (continuation, feeder) = lock.withLock {
            defer {
                self.continuation = nil
                self.feeder = nil
            }
            return (self.continuation, self.feeder)
        }
        feeder?.cancel()
        continuation?.yield(.finalized(script))
        continuation?.finish()
    }

    func cancel() async {
        let (continuation, feeder) = lock.withLock {
            defer {
                self.continuation = nil
                self.feeder = nil
            }
            return (self.continuation, self.feeder)
        }
        feeder?.cancel()
        continuation?.finish()
    }
}
#endif
