import AVFoundation
import Foundation

/// An engine that records the whole take and transcribes it once the take
/// ends — no live words while Luke speaks.
protocol RecordingTranscriptionEngine: SpeechEngine {
    /// Closes the recording (on the first call), uploads it and returns the
    /// text, deleting the recording on success. On failure the recording is
    /// kept, so calling again re-uploads the same audio under the same
    /// `client_request_id`.
    func transcribeRecording() async throws -> String
}

/// Uploads one finished recording and returns its transcript.
protocol SpeechTranscriptionUploading: Sendable {
    func transcribe(audio: Data, purpose: TranscriptionPurpose, clientRequestId: UUID) async throws -> String
}

/// Why a recorded take couldn't be turned into text. `isRetryable` says
/// whether re-uploading the same recording could help (network, timeouts,
/// rate limits, provider outages) — those keep the recording.
enum TranscriptionError: LocalizedError, Equatable {
    /// No audio reached the file (an instant stop).
    case nothingRecorded
    /// The recording couldn't be written.
    case recordingFailed
    /// The kept recording is gone (already sent or discarded).
    case recordingMissing
    case tooLarge
    /// The transcript came back empty.
    case nothingHeard
    case server(status: Int, message: String)
    case offline
    case timedOut
    case signedOut
    case invalidResponse
    case failed

    var errorDescription: String? {
        switch self {
        case .nothingRecorded: return VoiceCopy.didNotCatchThat
        case .recordingFailed: return "The recording couldn’t be saved. Try again or type it."
        case .recordingMissing: return "That recording is gone — record it again."
        case .tooLarge: return "That recording is too long to transcribe. Try a shorter one."
        case .nothingHeard: return "Didn’t catch anything. Try again."
        // The server's own words, as-is (it already speaks to Luke).
        case .server(_, let message): return message
        case .offline: return VoiceCopy.transcriptionOffline
        case .timedOut: return VoiceCopy.transcriptionTimedOut
        case .signedOut: return VoiceCopy.transcriptionSignedOut
        case .invalidResponse, .failed: return VoiceCopy.transcriptionFailed
        }
    }

    var message: String { errorDescription ?? VoiceCopy.transcriptionFailed }

    var isRetryable: Bool {
        switch self {
        case .nothingRecorded, .recordingFailed, .recordingMissing, .tooLarge, .nothingHeard:
            return false
        case .server(let status, _):
            // 400 bad request, 413 too long, 415 format, 422 nothing heard:
            // the same audio would fail the same way.
            return status == 401 || status == 403 || status == 408 || status == 429 || status >= 500
        case .offline, .timedOut, .signedOut, .invalidResponse, .failed:
            return true
        }
    }

    static func from(_ error: Error) -> TranscriptionError {
        if let error = error as? TranscriptionError { return error }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut:
                return .timedOut
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed,
                 .internationalRoamingOff, .callIsActive:
                return .offline
            default:
                return .failed
            }
        }
        return .failed
    }
}

/// Records the microphone into a temporary AAC `.m4a` (mono, 44.1/48 kHz)
/// and, when the take ends, uploads it to Shudo's `transcribe` function
/// (OpenAI gpt-4o-transcribe). Emits no volatile events; `finish()` yields
/// one `.finalized(text)`. The file is deleted once transcribed or
/// cancelled; a failed upload keeps it so a retry can re-upload.
final class ServerTranscriptionEngine: RecordingTranscriptionEngine, @unchecked Sendable {
    static let filePrefix = "shudo-voice-"
    static let encoderBitRate = 64_000
    /// A buffer louder than this (RMS, dBFS) counts as voice; room tone and
    /// a phone in a pocket sit well below it.
    static let voiceThresholdDB: Float = -45
    /// Less voice than this and nothing is uploaded: near-silence makes the
    /// transcriber invent a whole message.
    static let minimumVoicedSeconds: Double = 0.25

    let id: SpeechEngineID = .openAITranscribe

    private let uploader: any SpeechTranscriptionUploading
    private let directory: URL
    private let lock = NSLock()
    private let converter = SpeechBufferConverter()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var framesWritten: AVAudioFramePosition = 0
    private var voicedSeconds: Double = 0
    private var writeFailed = false
    private var isClosed = false
    private var purpose: TranscriptionPurpose = .meal
    private var clientRequestId = UUID()
    private var continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation?

    init(
        uploader: any SpeechTranscriptionUploading,
        directory: URL = FileManager.default.temporaryDirectory
    ) {
        self.uploader = uploader
        self.directory = directory
    }

    /// The recording on disk, for tests and diagnostics.
    var recordingURL: URL? { lock.withLock { fileURL } }
    var recordedFrames: AVAudioFramePosition { lock.withLock { framesWritten } }
    var requestId: UUID { lock.withLock { clientRequestId } }

    func start(locale: Locale, profile: VoiceProfile, vocabulary: [String]) async throws -> SpeechRun {
        let (events, continuation) = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        let url = directory.appendingPathComponent(
            "\(Self.filePrefix)\(UUID().uuidString.lowercased()).m4a"
        )
        lock.withLock {
            purpose = profile.transcriptionPurpose ?? .meal
            clientRequestId = UUID()
            fileURL = url
            file = nil
            framesWritten = 0
            voicedSeconds = 0
            writeFailed = false
            isClosed = false
            self.continuation = continuation
        }
        return SpeechRun(format: nil, events: events)
    }

    /// Writes one microphone buffer (called from the single pump task). The
    /// file is created on the first buffer, at the microphone's own rate.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !isClosed, !writeFailed, let fileURL, buffer.frameLength > 0 else { return }
            if Self.loudnessDB(of: buffer) > Self.voiceThresholdDB, buffer.format.sampleRate > 0 {
                voicedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            }
            if file == nil {
                do {
                    file = try Self.makeFile(at: fileURL, inputFormat: buffer.format)
                } catch {
                    writeFailed = true
                    return
                }
            }
            guard let file,
                  let converted = converter.convert(buffer, to: file.processingFormat) else { return }
            do {
                try file.write(from: converted)
                framesWritten += AVAudioFramePosition(converted.frameLength)
            } catch {
                writeFailed = true
            }
        }
    }

    func finish() async throws {
        let text = try await transcribeRecording()
        let continuation = lock.withLock { () -> AsyncThrowingStream<SpeechEvent, Error>.Continuation? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.yield(.finalized(text))
        continuation?.finish()
    }

    func transcribeRecording() async throws -> String {
        let (url, frames, failedWrite, purpose, requestId, voiced) = lock.withLock {
            closeFileLocked()
            return (fileURL, framesWritten, writeFailed, self.purpose, clientRequestId, voicedSeconds)
        }
        guard let url else { throw TranscriptionError.recordingMissing }
        guard frames > 0 else {
            removeRecording()
            throw failedWrite ? TranscriptionError.recordingFailed : TranscriptionError.nothingRecorded
        }
        guard voiced >= Self.minimumVoicedSeconds else {
            removeRecording()
            throw TranscriptionError.nothingHeard
        }
        let audio: Data
        do {
            audio = try Data(contentsOf: url)
        } catch {
            throw TranscriptionError.recordingMissing
        }
        guard audio.count <= ServerTranscriptionClient.maximumAudioBytes else {
            removeRecording()
            throw TranscriptionError.tooLarge
        }
        CaptureDiagnostics.record(.speechUploadStarted, state: purpose.rawValue)
        let text: String
        do {
            text = try await uploader.transcribe(audio: audio, purpose: purpose, clientRequestId: requestId)
        } catch {
            let failure = TranscriptionError.from(error)
            CaptureDiagnostics.record(.speechUploadFailed, state: failure.isRetryable ? "retryable" : "final")
            if !failure.isRetryable { removeRecording() }
            throw failure
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            removeRecording()
            throw TranscriptionError.nothingHeard
        }
        CaptureDiagnostics.record(.speechUploadSucceeded, state: purpose.rawValue)
        removeRecording()
        return cleaned
    }

    func cancel() async {
        let continuation = lock.withLock { () -> AsyncThrowingStream<SpeechEvent, Error>.Continuation? in
            closeFileLocked()
            defer { self.continuation = nil }
            return self.continuation
        }
        removeRecording()
        continuation?.finish()
    }

    /// RMS loudness of a microphone buffer in dBFS. Non-float formats count
    /// as voice, so nothing real is ever dropped for being unmeasurable.
    static func loudnessDB(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return -160 }
        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }

    // MARK: File

    /// AAC-LC at the microphone's rate (44.1 or 48 kHz; anything else is
    /// resampled to 48 kHz), mono.
    static func recordingSampleRate(forInputRate rate: Double) -> Double {
        rate == 44_100 ? 44_100 : 48_000
    }

    static func makeFile(at url: URL, inputFormat: AVAudioFormat) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: recordingSampleRate(forInputRate: inputFormat.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: encoderBitRate,
        ]
        return try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    /// Caller holds `lock`. Closing writes the AAC container's index.
    private func closeFileLocked() {
        isClosed = true
        file?.close()
        file = nil
    }

    private func removeRecording() {
        let url = lock.withLock { () -> URL? in
            defer { fileURL = nil }
            return fileURL
        }
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    /// Deletes recordings a crash or a kill left behind.
    static func sweepStaleRecordings(
        in directory: URL = FileManager.default.temporaryDirectory,
        olderThan age: TimeInterval = 60 * 60,
        now: Date = Date()
    ) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(filePrefix) && name.hasSuffix(".m4a") {
            let url = directory.appendingPathComponent(name)
            let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let modified, now.timeIntervalSince(modified) < age { continue }
            try? fileManager.removeItem(at: url)
        }
    }
}

/// `POST /functions/v1/transcribe`: multipart `audio` (voice.m4a,
/// audio/mp4), `purpose`, `client_request_id` (lowercase UUID), with the same
/// auth headers as every other function call. 200 → `{"text": …}`; errors
/// are `{"error": "<message for Luke>"}`.
struct ServerTranscriptionClient: SpeechTranscriptionUploading {
    static let maximumAudioBytes = 25 * 1024 * 1024
    static let requestTimeout: TimeInterval = 60
    static let audioFilename = "voice.m4a"
    static let audioContentType = "audio/mp4"

    let supabaseURL: URL
    let publishableKey: String
    let session: URLSession
    let sessionJWTProvider: @Sendable () async throws -> String

    init(
        supabaseURL: URL = AppConfig.supabaseURL,
        publishableKey: String = AppConfig.supabaseAnonKey,
        session: URLSession = .shared,
        sessionJWTProvider: @escaping @Sendable () async throws -> String = {
            try await AuthSessionManager.shared.getAccessToken()
        }
    ) {
        self.supabaseURL = supabaseURL
        self.publishableKey = publishableKey
        self.session = session
        self.sessionJWTProvider = sessionJWTProvider
    }

    func transcribe(audio: Data, purpose: TranscriptionPurpose, clientRequestId: UUID) async throws -> String {
        let jwt: String
        do {
            jwt = try await sessionJWTProvider()
        } catch {
            throw TranscriptionError.signedOut
        }
        let request = makeRequest(
            audio: audio,
            purpose: purpose,
            clientRequestId: clientRequestId,
            jwt: jwt
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TranscriptionError.from(error)
        }
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }
        return try Self.parse(statusCode: http.statusCode, data: data)
    }

    func makeRequest(
        audio: Data,
        purpose: TranscriptionPurpose,
        clientRequestId: UUID,
        jwt: String,
        boundary: String = "shudo-\(UUID().uuidString.lowercased())"
    ) -> URLRequest {
        var request = URLRequest(url: supabaseURL.appendingPathComponent("functions/v1/transcribe"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            audio: audio,
            purpose: purpose,
            clientRequestId: clientRequestId
        )
        return request
    }

    static func multipartBody(
        boundary: String,
        audio: Data,
        purpose: TranscriptionPurpose,
        clientRequestId: UUID
    ) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(Data(string.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        field("purpose", purpose.rawValue)
        field("client_request_id", clientRequestId.uuidString.lowercased())
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(audioFilename)\"\r\n")
        append("Content-Type: \(audioContentType)\r\n\r\n")
        data.append(audio)
        append("\r\n")
        append("--\(boundary)--\r\n")
        return data
    }

    static func parse(statusCode: Int, data: Data) throws -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard statusCode == 200 else {
            let message = (object?["error"] as? String)
                ?? (object?["message"] as? String)
            if statusCode == 401, message == nil || message?.lowercased().contains("jwt") == true {
                throw TranscriptionError.signedOut
            }
            throw TranscriptionError.server(
                status: statusCode,
                message: message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    ?? VoiceCopy.transcriptionFailed
            )
        }
        guard let text = object?["text"] as? String else { throw TranscriptionError.invalidResponse }
        return text
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension VoiceTiming {
    /// Runs `work`, cancelling it (an upload honors that at once) and
    /// throwing `TranscriptionError.timedOut` once `seconds` pass.
    static func deadline<T: Sendable>(
        _ seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw TranscriptionError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TranscriptionError.failed }
            return first
        }
    }
}
