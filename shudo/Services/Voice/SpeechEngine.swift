import AVFoundation
import Foundation

/// A started recognition pass. `format` is the PCM format the engine wants
/// (nil: it accepts the microphone's native format); engines convert
/// internally in `append`, never on the audio thread.
struct SpeechRun {
    let format: AVAudioFormat?
    let events: AsyncThrowingStream<SpeechEvent, Error>
}

/// An on-device recognizer. Implementations must never send audio off the
/// device. Lifecycle: `start` once, `append` buffers (from a single consumer
/// task), then either `finish` (flushes final results and ends `events`) or
/// `cancel`.
protocol SpeechEngine: AnyObject, Sendable {
    var id: SpeechEngineID { get }
    func start(locale: Locale, profile: VoiceProfile, vocabulary: [String]) async throws -> SpeechRun
    func append(_ buffer: AVAudioPCMBuffer)
    func finish() async throws
    func cancel() async
}

enum SpeechEngineError: LocalizedError, Equatable {
    case unavailable
    case noCompatibleAudioFormat
    case notStarted

    var errorDescription: String? {
        switch self {
        case .unavailable: return VoiceCopy.unsupported
        case .noCompatibleAudioFormat, .notStarted: return VoiceCopy.recognizerFailed
        }
    }
}

/// Converts microphone buffers to the recognizer's format. Not thread-safe;
/// each engine guards its converter with its own lock.
final class SpeechBufferConverter {
    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }
        if converter == nil
            || converter?.inputFormat != inputFormat
            || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            // No priming: the first buffer must not be eaten by the
            // converter's look-ahead, or the first syllable goes missing.
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else { return nil }
        return output
    }
}

extension AVAudioPCMBuffer {
    /// A detached copy, so a tap buffer the engine may recycle is never read
    /// after the tap block returns.
    func shudoCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(1, frameLength)) else {
            return nil
        }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
