import AVFoundation
import Foundation
import Testing
@testable import shudo

// MARK: - Upload request (POST /functions/v1/transcribe)

struct ServerTranscriptionClientTests {
    private let client = ServerTranscriptionClient(
        supabaseURL: URL(string: "https://example.supabase.co")!,
        publishableKey: "publishable-test-key",
        sessionJWTProvider: { "session-jwt" }
    )

    @Test func theRequestCarriesAuthAndTheThreeMultipartFields() throws {
        let requestId = try #require(UUID(uuidString: "A1B2C3D4-E5F6-4711-8899-AABBCCDDEEFF"))
        let audio = Data([0x00, 0x00, 0x00, 0x1C, 0x66, 0x74, 0x79, 0x70])
        let request = client.makeRequest(
            audio: audio,
            purpose: .coach,
            clientRequestId: requestId,
            jwt: "session-jwt",
            boundary: "shudo-test-boundary"
        )

        #expect(request.url?.absoluteString == "https://example.supabase.co/functions/v1/transcribe")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 60)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-jwt")
        #expect(request.value(forHTTPHeaderField: "apikey") == "publishable-test-key")
        #expect(request.value(forHTTPHeaderField: "Content-Type")
            == "multipart/form-data; boundary=shudo-test-boundary")

        let body = try #require(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("--shudo-test-boundary\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\ncoach\r\n"))
        #expect(text.contains(
            "Content-Disposition: form-data; name=\"client_request_id\"\r\n\r\na1b2c3d4-e5f6-4711-8899-aabbccddeeff\r\n"
        ))
        #expect(!text.contains("A1B2C3D4"), "the id must be lowercase")
        #expect(text.contains(
            "Content-Disposition: form-data; name=\"audio\"; filename=\"voice.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n"
        ))
        #expect(body.range(of: audio) != nil, "the recording bytes are sent as-is")
        #expect(text.hasSuffix("--shudo-test-boundary--\r\n"))
    }

    @Test func everyPurposeIsSentByItsWireName() {
        for purpose in TranscriptionPurpose.allCases {
            let body = ServerTranscriptionClient.multipartBody(
                boundary: "b",
                audio: Data([1]),
                purpose: purpose,
                clientRequestId: UUID()
            )
            #expect(String(decoding: body, as: UTF8.self)
                .contains("name=\"purpose\"\r\n\r\n\(purpose.rawValue)\r\n"))
        }
    }

    @Test func aSuccessReturnsTheText() throws {
        let data = Data(#"{"text":"two eggs and toast","model":"gpt-4o-transcribe","speech_engine":"openai.gpt-4o-transcribe"}"#.utf8)
        #expect(try ServerTranscriptionClient.parse(statusCode: 200, data: data) == "two eggs and toast")
        #expect(throws: TranscriptionError.invalidResponse) {
            try ServerTranscriptionClient.parse(statusCode: 200, data: Data("{}".utf8))
        }
    }

    @Test func serverErrorsKeepTheServersWordsAndKnowWhetherARetryHelps() {
        func failure(_ status: Int, _ body: String) -> TranscriptionError? {
            do {
                _ = try ServerTranscriptionClient.parse(statusCode: status, data: Data(body.utf8))
                return nil
            } catch {
                return error as? TranscriptionError
            }
        }
        let nothingHeard = failure(422, #"{"error":"Didn’t catch anything. Try again."}"#)
        #expect(nothingHeard == .server(status: 422, message: "Didn’t catch anything. Try again."))
        #expect(nothingHeard?.message == "Didn’t catch anything. Try again.")
        #expect(nothingHeard?.isRetryable == false)

        for status in [400, 413, 415] {
            #expect(failure(status, #"{"error":"Nope"}"#)?.isRetryable == false)
        }
        for status in [429, 502, 504, 500] {
            let error = failure(status, #"{"error":"Out of transcription credit"}"#)
            #expect(error?.isRetryable == true)
            #expect(error?.message == "Out of transcription credit")
        }
        #expect(failure(401, #"{"code":401,"message":"Invalid JWT"}"#) == .signedOut)
        #expect(failure(503, "not json")?.message == VoiceCopy.transcriptionFailed)
    }

    @Test func networkErrorsAreRetryable() {
        #expect(TranscriptionError.from(URLError(.notConnectedToInternet)) == .offline)
        #expect(TranscriptionError.from(URLError(.networkConnectionLost)) == .offline)
        #expect(TranscriptionError.from(URLError(.timedOut)) == .timedOut)
        #expect(TranscriptionError.offline.isRetryable)
        #expect(TranscriptionError.timedOut.isRetryable)
        #expect(TranscriptionError.signedOut.isRetryable)
        #expect(!TranscriptionError.nothingRecorded.isRetryable)
        #expect(!TranscriptionError.nothingHeard.isRetryable)
    }
}

// MARK: - Recording engine

private final class FakeUploader: SpeechTranscriptionUploading, @unchecked Sendable {
    struct Call {
        let audio: Data
        let purpose: TranscriptionPurpose
        let clientRequestId: UUID
    }

    private let lock = NSLock()
    private var _results: [Result<String, Error>]
    private var _calls: [Call] = []

    init(results: [Result<String, Error>]) {
        _results = results
    }

    var calls: [Call] { lock.withLock { _calls } }

    func transcribe(audio: Data, purpose: TranscriptionPurpose, clientRequestId: UUID) async throws -> String {
        let result = lock.withLock { () -> Result<String, Error> in
            _calls.append(Call(audio: audio, purpose: purpose, clientRequestId: clientRequestId))
            return _results.count > 1 ? _results.removeFirst() : _results[0]
        }
        return try result.get()
    }
}

struct ServerTranscriptionEngineTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shudo-engine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Half a second of a 220 Hz tone at the microphone's usual format.
    private func toneBuffer(sampleRate: Double = 48_000, seconds: Double = 0.5) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = Float(0.3 * sin(2 * .pi * 220 * Double(index) / sampleRate))
        }
        return buffer
    }

    @Test func recordsAnM4AUploadsItWithThePurposeAndDeletesItAfter() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploader = FakeUploader(results: [.success("  Two scrambled eggs.  ")])
        let engine = ServerTranscriptionEngine(uploader: uploader, directory: directory)
        #expect(engine.id == .openAITranscribe)

        let run = try await engine.start(locale: Locale(identifier: "en_US"), profile: .correction, vocabulary: [])
        #expect(run.format == nil)
        for _ in 0..<3 { engine.append(try toneBuffer()) }
        #expect(engine.recordedFrames > 0)
        let file = try #require(engine.recordingURL)
        #expect(file.pathExtension == "m4a")
        #expect(FileManager.default.fileExists(atPath: file.path))

        let collector = Task { () -> [SpeechEvent] in
            var events: [SpeechEvent] = []
            for try await event in run.events { events.append(event) }
            return events
        }
        try await engine.finish()
        // No volatile words: one final event with the transcript.
        #expect(try await collector.value == [.finalized("Two scrambled eggs.")])

        let call = try #require(uploader.calls.first)
        #expect(uploader.calls.count == 1)
        #expect(call.purpose == .correction)
        #expect(call.audio.count > 100)
        // An MPEG-4 container ("ftyp" box) of AAC audio.
        #expect(String(decoding: call.audio.subdata(in: 4..<8), as: UTF8.self) == "ftyp")
        #expect(!FileManager.default.fileExists(atPath: file.path), "transcribed audio is not kept")
    }

    @Test func aRetryableFailureKeepsTheFileAndRetryReusesTheRequestId() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploader = FakeUploader(results: [
            .failure(URLError(.notConnectedToInternet)),
            .success("Chicken and rice"),
        ])
        let engine = ServerTranscriptionEngine(uploader: uploader, directory: directory)
        _ = try await engine.start(locale: Locale(identifier: "en_US"), profile: .meal, vocabulary: [])
        engine.append(try toneBuffer(sampleRate: 44_100))
        let file = try #require(engine.recordingURL)

        await #expect(throws: TranscriptionError.offline) { try await engine.transcribeRecording() }
        #expect(FileManager.default.fileExists(atPath: file.path), "kept for a retry")
        // Audio arriving after the take ended is ignored.
        engine.append(try toneBuffer())

        #expect(try await engine.transcribeRecording() == "Chicken and rice")
        #expect(uploader.calls.count == 2)
        #expect(uploader.calls[0].clientRequestId == uploader.calls[1].clientRequestId)
        #expect(uploader.calls[0].audio == uploader.calls[1].audio)
        #expect(uploader.calls[0].purpose == .meal)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aFinalFailureDeletesTheFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploader = FakeUploader(results: [
            .failure(TranscriptionError.server(status: 422, message: "Didn’t catch anything. Try again.")),
        ])
        let engine = ServerTranscriptionEngine(uploader: uploader, directory: directory)
        _ = try await engine.start(locale: Locale(identifier: "en_US"), profile: .coach, vocabulary: [])
        engine.append(try toneBuffer())
        let file = try #require(engine.recordingURL)
        await #expect(throws: TranscriptionError.server(status: 422, message: "Didn’t catch anything. Try again.")) {
            try await engine.transcribeRecording()
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func nothingRecordedNeverUploads() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploader = FakeUploader(results: [.success("ghost")])
        let engine = ServerTranscriptionEngine(uploader: uploader, directory: directory)
        _ = try await engine.start(locale: Locale(identifier: "en_US"), profile: .meal, vocabulary: [])
        await #expect(throws: TranscriptionError.nothingRecorded) { try await engine.transcribeRecording() }
        #expect(uploader.calls.isEmpty)
    }

    @Test func anEmptyTranscriptIsNothingHeard() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let uploader = FakeUploader(results: [.success("   ")])
        let engine = ServerTranscriptionEngine(uploader: uploader, directory: directory)
        _ = try await engine.start(locale: Locale(identifier: "en_US"), profile: .meal, vocabulary: [])
        engine.append(try toneBuffer())
        await #expect(throws: TranscriptionError.nothingHeard) { try await engine.transcribeRecording() }
    }

    @Test func cancelDeletesTheRecordingAndEndsTheEvents() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = ServerTranscriptionEngine(uploader: FakeUploader(results: [.success("x")]), directory: directory)
        let run = try await engine.start(locale: Locale(identifier: "en_US"), profile: .meal, vocabulary: [])
        engine.append(try toneBuffer())
        let file = try #require(engine.recordingURL)
        await engine.cancel()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        var events: [SpeechEvent] = []
        for try await event in run.events { events.append(event) }
        #expect(events.isEmpty)
    }

    @Test func recordingsKeepTheMicrophoneRate() {
        #expect(ServerTranscriptionEngine.recordingSampleRate(forInputRate: 44_100) == 44_100)
        #expect(ServerTranscriptionEngine.recordingSampleRate(forInputRate: 48_000) == 48_000)
        #expect(ServerTranscriptionEngine.recordingSampleRate(forInputRate: 16_000) == 48_000)
    }

    @Test func staleRecordingsAreSwept() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stale = directory.appendingPathComponent("shudo-voice-old.m4a")
        let fresh = directory.appendingPathComponent("shudo-voice-new.m4a")
        let unrelated = directory.appendingPathComponent("other.m4a")
        for url in [stale, fresh, unrelated] {
            FileManager.default.createFile(atPath: url.path, contents: Data([1]))
        }
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7_200)],
            ofItemAtPath: stale.path
        )
        ServerTranscriptionEngine.sweepStaleRecordings(in: directory)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
}

#if DEBUG
/// The DEBUG scripted engine mimics the server stack for UI tests: no
/// words while recording, the whole script only after stop.
struct ScriptedServerEngineTests {
    @Test func aScriptedServerTakeShowsNothingUntilStop() async throws {
        let engine = ScriptedSpeechEngine(
            id: .openAITranscribe,
            script: "two bananas",
            wordInterval: 0.01,
            uploadDelay: 0.01
        )
        let run = try await engine.start(locale: Locale(identifier: "en_US"), profile: .meal, vocabulary: [])
        let collector = Task { () -> [SpeechEvent] in
            var events: [SpeechEvent] = []
            for try await event in run.events { events.append(event) }
            return events
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        try await engine.finish()
        #expect(try await collector.value == [.finalized("two bananas")])
    }

    @Test func uploadFailsOnceFailsOnlyTheFirstUpload() async throws {
        let uploads = ScriptedUploads()
        uploads.armFailureOnce()
        uploads.armFailureOnce()
        let engine = ScriptedSpeechEngine(id: .openAITranscribe, script: "oats", uploadDelay: 0, uploads: uploads)
        await #expect(throws: TranscriptionError.server(status: 502, message: ScriptedSpeechEngine.uploadFailureMessage)) {
            try await engine.transcribeRecording()
        }
        #expect(try await engine.transcribeRecording() == "oats")
        #expect(ScriptedVoiceConfiguration.parse(["app", "-shudoScriptedSpeechMode", "uploadFailsOnce"])?.mode
            == .uploadFailsOnce)
    }
}
#endif
