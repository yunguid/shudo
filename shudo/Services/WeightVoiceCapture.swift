import AVFoundation
import Speech

/// Live dictation for the weigh-in sheet: starts listening as the sheet
/// appears, publishes the running transcript, and is torn down by an explicit
/// stop. Distinct from AudioRecorder on purpose — meal voice notes upload
/// audio for server transcription, while a weigh-in needs only one number,
/// parsed locally, with no audio ever stored or uploaded.
@MainActor
final class WeightVoiceCapture: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case listening
        case stopped
        /// Microphone/speech permission missing or recognition unavailable;
        /// the sheet falls back to the manual number field.
        case unavailable
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Ignores recognition callbacks from a session the user already ended.
    private var generation = 0

    var isCapturing: Bool { phase == .starting || phase == .listening }

    func start() async {
        // Restartable from any settled state — including .unavailable, so a
        // user who just granted permission in Settings gets a live retry
        // instead of a dead mic button.
        guard !isCapturing else { return }
        phase = .starting
        transcript = ""
        generation += 1
        let activeGeneration = generation

        guard await Self.requestPermissions() else {
            if generation == activeGeneration { phase = .unavailable }
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            if generation == activeGeneration { phase = .unavailable }
            return
        }
        self.recognizer = recognizer

        // Category setup and activation block for ~200 ms; keep them off the
        // main actor so the sheet's presentation animation never hitches.
        let sessionReady = await Task.detached(priority: .userInitiated) {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
                try session.setActive(true, options: [])
                return true
            } catch {
                return false
            }
        }.value
        guard generation == activeGeneration else {
            if sessionReady { Self.deactivateSessionInBackground() }
            return
        }
        guard sessionReady else {
            phase = .unavailable
            return
        }

        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak request] buffer, _ in
                request?.append(buffer)
            }
            engine.prepare()
            try engine.start()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                Task { @MainActor [weak self] in
                    guard let self, self.generation == activeGeneration else { return }
                    if let text, self.isCapturing { self.transcript = text }
                    // A recognition error mid-listen (silence timeout, service
                    // hiccup) quietly ends the voice path; whatever was parsed
                    // stays in the field and manual entry continues.
                    if error != nil, self.isCapturing { self.stop() }
                }
            }
            phase = .listening
        } catch {
            teardown()
            phase = .unavailable
        }
    }

    func stop() {
        guard isCapturing else { return }
        teardown()
        phase = .stopped
    }

    private func teardown() {
        generation += 1
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        Self.deactivateSessionInBackground()
    }

    private static func deactivateSessionInBackground() {
        DispatchQueue.global(qos: .utility).async {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
    }

    private static func requestPermissions() async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else { return false }
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return status == .authorized
    }
}
