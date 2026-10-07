#if DEBUG
import AVFoundation
import Combine
import Foundation

/// Deterministic voice for PolishPreview and UI tests (the Simulator can't
/// run SpeechTranscriber). Launch arguments:
///
///     -shudoScriptedSpeech "two scrambled eggs and toast"
///     -shudoScriptedSpeechMode denied|unavailable|downloading|uploadFailsOnce
///
/// The scripted capture never touches AVAudioSession, so tests don't depend
/// on the simulator's microphone permission. Like the real stack, a server
/// profile (meal, coach, …) shows no words while recording and gets the
/// whole script only after stop, following a short "Transcribing…" beat;
/// `uploadFailsOnce` fails that first upload (retryable) so the retry path
/// can be driven. The on-device weigh-in engine streams the script word by
/// word as volatile results and finalizes it on stop.
struct ScriptedVoiceConfiguration: Equatable {
    enum Mode: String {
        case normal
        case denied
        case unavailable
        case downloading
        case uploadFailsOnce
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
        let uploads = ScriptedUploads.shared
        if mode == .uploadFailsOnce { uploads.armFailureOnce() }
        return VoiceEnvironment(
            permissions: ScriptedVoicePermissions(grantsMicrophone: mode != .denied),
            assets: ScriptedSpeechAssets(snapshot: Self.snapshot(for: mode)),
            makeCapture: { ScriptedAudioCapture() },
            makeEngine: { id in ScriptedSpeechEngine(id: id, script: text, uploads: uploads) },
            vocabulary: { [] }
        )
    }

    static func snapshot(for mode: Mode) -> SpeechAssetSnapshot {
        switch mode {
        case .normal, .denied, .uploadFailsOnce:
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

/// One shared "the next upload fails" switch for every scripted engine in
/// the process (each take makes a fresh engine).
final class ScriptedUploads: @unchecked Sendable {
    static let shared = ScriptedUploads()
    private let lock = NSLock()
    private var failuresRemaining = 0
    private var armed = false

    func armFailureOnce() {
        lock.withLock {
            guard !armed else { return }
            armed = true
            failuresRemaining = 1
        }
    }

    func consumeFailure() -> Bool {
        lock.withLock {
            guard failuresRemaining > 0 else { return false }
            failuresRemaining -= 1
            return true
        }
    }
}

/// A server engine (`.openAITranscribe`) records silently and hands back
/// the whole script only after stop, like the real upload. An on-device
/// engine streams the script word by word as volatile results; `finish()`
/// finalizes the whole script.
final class ScriptedSpeechEngine: RecordingTranscriptionEngine, @unchecked Sendable {
    static let uploadFailureMessage = "Transcription failed. Try again."

    let id: SpeechEngineID
    private let script: String
    private let wordInterval: UInt64
    private let uploadDelay: UInt64
    private let uploads: ScriptedUploads
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation?
    private var feeder: Task<Void, Never>?

    init(
        id: SpeechEngineID,
        script: String,
        wordInterval: TimeInterval = 0.18,
        uploadDelay: TimeInterval = 0.9,
        uploads: ScriptedUploads = ScriptedUploads()
    ) {
        self.id = id
        self.script = script
        self.wordInterval = UInt64(wordInterval * 1_000_000_000)
        self.uploadDelay = UInt64(uploadDelay * 1_000_000_000)
        self.uploads = uploads
    }

    func start(locale: Locale, profile: VoiceProfile, vocabulary: [String]) async throws -> SpeechRun {
        let (events, continuation) = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        guard !id.transcribesAfterRecording else {
            lock.withLock { self.continuation = continuation }
            return SpeechRun(format: nil, events: events)
        }
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

    /// The "upload": a short beat, then the whole script.
    func transcribeRecording() async throws -> String {
        try await Task.sleep(nanoseconds: uploadDelay)
        if uploads.consumeFailure() {
            throw TranscriptionError.server(status: 502, message: Self.uploadFailureMessage)
        }
        return script
    }

    func finish() async throws {
        if id.transcribesAfterRecording {
            let text = try await transcribeRecording()
            let continuation = lock.withLock { () -> AsyncThrowingStream<SpeechEvent, Error>.Continuation? in
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.yield(.finalized(text))
            continuation?.finish()
            return
        }
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
