import AVFoundation
import Foundation
import Speech

/// iOS 26 `SpeechAnalyzer` recognizer, on-device only (the model runs outside
/// the app's memory space and never uploads audio).
///
/// - `.transcriber`: `SpeechTranscriber` with volatile results — the primary
///   engine. Contextual strings are ignored by this module (Apple, forums
///   thread 811083), so brand repair happens downstream and in the editable
///   note.
/// - `.dictation`: `DictationTranscriber` with punctuation and the personal
///   vocabulary as contextual strings — the in-API fallback.
///
/// Profanity redaction (`etiquetteReplacements`) is deliberately never
/// enabled: Luke and the coach both swear.
final class AnalyzerSpeechEngine: SpeechEngine, @unchecked Sendable {
    enum Module: Sendable {
        case transcriber
        case dictation
    }

    private struct State {
        var analyzer: SpeechAnalyzer?
        var input: AsyncStream<AnalyzerInput>.Continuation?
        var format: AVAudioFormat?
        var resultsTask: Task<Void, Never>?
    }

    let id: SpeechEngineID
    private let module: Module
    private let lock = NSLock()
    private var state = State()
    private let converter = SpeechBufferConverter()

    init(module: Module) {
        self.module = module
        id = module == .transcriber ? .speechTranscriber : .dictationTranscriber
    }

    func start(locale: Locale, profile: VoiceProfile, vocabulary: [String]) async throws -> SpeechRun {
        let modules: [any SpeechModule]
        let (events, eventContinuation) = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        let resultsTask: Task<Void, Never>

        switch module {
        case .transcriber:
            var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
            if profile.prefersFastResults { reporting.insert(.fastResults) }
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: reporting,
                attributeOptions: []
            )
            modules = [transcriber]
            resultsTask = Task {
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        eventContinuation.yield(result.isFinal ? .finalized(text) : .volatile(text))
                    }
                    eventContinuation.finish()
                } catch {
                    eventContinuation.finish(throwing: error)
                }
            }
        case .dictation:
            let dictation = DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
            modules = [dictation]
            resultsTask = Task {
                do {
                    for try await result in dictation.results {
                        let text = String(result.text.characters)
                        eventContinuation.yield(result.isFinal ? .finalized(text) : .volatile(text))
                    }
                    eventContinuation.finish()
                } catch {
                    eventContinuation.finish(throwing: error)
                }
            }
        }

        do {
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
                throw SpeechEngineError.noCompatibleAudioFormat
            }
            let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream(
                bufferingPolicy: .unbounded
            )
            let analyzer = SpeechAnalyzer(
                modules: modules,
                options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
            )
            if module == .dictation, !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocabulary
                try await analyzer.setContext(context)
            }
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: inputSequence)
            lock.withLock {
                state.analyzer = analyzer
                state.input = inputContinuation
                state.format = format
                state.resultsTask = resultsTask
            }
            return SpeechRun(format: format, events: events)
        } catch {
            resultsTask.cancel()
            eventContinuation.finish(throwing: error)
            throw error
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let input = state.input, let format = state.format,
                  let converted = converter.convert(buffer, to: format) else { return }
            input.yield(AnalyzerInput(buffer: converted))
        }
    }

    func finish() async throws {
        let (analyzer, input) = lock.withLock {
            let pair = (state.analyzer, state.input)
            state.input = nil
            return pair
        }
        input?.finish()
        guard let analyzer else { throw SpeechEngineError.notStarted }
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    func cancel() async {
        let (analyzer, input, resultsTask) = lock.withLock {
            let captured = (state.analyzer, state.input, state.resultsTask)
            state = State()
            return captured
        }
        input?.finish()
        resultsTask?.cancel()
        await analyzer?.cancelAndFinishNow()
    }
}
