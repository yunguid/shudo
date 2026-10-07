import AVFoundation
import Foundation
import Speech

/// Last-resort recognizer: `SFSpeechRecognizer` with
/// `requiresOnDeviceRecognition`. When on-device recognition isn't supported
/// for the locale it reports unavailable — it never silently falls back to
/// Apple's servers.
final class OnDeviceRecognizerEngine: SpeechEngine, @unchecked Sendable {
    let id = SpeechEngineID.sfSpeechOnDevice

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation?

    func start(locale: Locale, profile: VoiceProfile, vocabulary: [String]) async throws -> SpeechRun {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(),
              recognizer.supportsOnDeviceRecognition,
              recognizer.isAvailable else {
            throw SpeechEngineError.unavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = Array(vocabulary.prefix(PersonalVocabulary.maximumTerms))

        let (events, continuation) = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        let segmenter = RecognizerSegmenter()
        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                for event in segmenter.events(
                    for: result.bestTranscription.formattedString,
                    isFinal: result.isFinal
                ) {
                    continuation.yield(event)
                }
                if result.isFinal { continuation.finish() }
            } else if let error {
                continuation.finish(throwing: error)
            }
        }
        lock.withLock {
            self.request = request
            self.task = task
            self.continuation = continuation
        }
        return SpeechRun(format: nil, events: events)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request }?.append(buffer)
    }

    func finish() async throws {
        let request = lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            defer { self.request = nil }
            return self.request
        }
        guard let request else { throw SpeechEngineError.notStarted }
        request.endAudio()
    }

    func cancel() async {
        let (task, continuation) = lock.withLock {
            defer {
                self.request = nil
                self.task = nil
                self.continuation = nil
            }
            return (self.task, self.continuation)
        }
        task?.cancel()
        continuation?.finish()
    }
}

/// `SFSpeechRecognizer` partial results are cumulative for the whole
/// request, except that on-device recognition can silently restart from an
/// empty transcript after a long pause. Commit the earlier segment when that
/// happens so it isn't lost.
final class RecognizerSegmenter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPartial = ""

    func events(for text: String, isFinal: Bool) -> [SpeechEvent] {
        lock.withLock {
            var events: [SpeechEvent] = []
            if Self.isRestart(previous: lastPartial, current: text) {
                events.append(.finalized(lastPartial))
            }
            if isFinal {
                events.append(.finalized(text))
                lastPartial = ""
            } else {
                events.append(.volatile(text))
                lastPartial = text
            }
            return events
        }
    }

    static func isRestart(previous: String, current: String) -> Bool {
        let previous = previous.trimmingCharacters(in: .whitespaces)
        let current = current.trimmingCharacters(in: .whitespaces)
        guard previous.count >= 12, !current.isEmpty, current.count < previous.count / 2 else {
            return false
        }
        let probe = min(6, current.count)
        return previous.lowercased().prefix(probe) != current.lowercased().prefix(probe)
    }
}
