import Foundation

// Pure, platform-free policy types for on-device dictation. Everything here
// is deterministic and unit-tested; the Speech/AVFoundation plumbing lives in
// the sibling files and only feeds events into these types.

/// Identifies which recognizer produced a take. The raw values are a wire
/// contract: `speech_engine` on create_entry / correct_entry /
/// onboard_profile / coach_chat, validated server-side against the same
/// allowlist (supabase/functions/_shared/capture_validation.ts).
enum SpeechEngineID: String, CaseIterable, Codable, Sendable {
    case speechTranscriber = "apple.speech_transcriber"
    case dictationTranscriber = "apple.dictation_transcriber"
    case sfSpeechOnDevice = "apple.sf_speech_on_device"
    /// Record the take, then transcribe it on Shudo's `transcribe` function
    /// (OpenAI gpt-4o-transcribe) once Luke taps send/stop.
    case openAITranscribe = "openai.gpt-4o-transcribe"

    var diagnosticName: String {
        switch self {
        case .speechTranscriber: return "speech_transcriber"
        case .dictationTranscriber: return "dictation_transcriber"
        case .sfSpeechOnDevice: return "sf_speech_on_device"
        case .openAITranscribe: return "openai_transcribe"
        }
    }

    /// Records audio and transcribes it after the take — no live words.
    var transcribesAfterRecording: Bool { self == .openAITranscribe }
}

/// Which screen a server transcription is for (`purpose` on the
/// `transcribe` function; it picks the vocabulary prompt server-side).
enum TranscriptionPurpose: String, CaseIterable, Sendable {
    case meal
    case coach
    case correction
    case onboarding
    case workout
}

/// One recognizer update. `volatile` replaces the tentative tail of the
/// transcript; `finalized` commits text and clears the tail.
enum SpeechEvent: Equatable, Sendable {
    case volatile(String)
    case finalized(String)
}

/// Per-screen limits and recognizer preferences.
struct VoiceProfile: Equatable, Sendable {
    let name: String
    let maximumDuration: TimeInterval
    /// Transcript cap in UTF-16 units — the unit every note field bounds by.
    let maximumCharacters: Int
    /// `SpeechTranscriber.ReportingOption.fastResults`: lower latency for
    /// short utterances (a weigh-in number) at some accuracy cost.
    let prefersFastResults: Bool
    /// When set, the take ends by itself once `VoiceTranscriber.autoStopCondition`
    /// has held this long with no new recognizer output.
    let autoStopStableInterval: TimeInterval?
    /// How long a normal stop waits for the recognizer's final pass before
    /// keeping the committed + volatile text it already has.
    let finalizationTimeout: TimeInterval
    let microphoneDeniedMessage: String
    /// Set: record, then transcribe on the server after the take (no live
    /// words). Nil: live on-device recognition (the weigh-in, which stops by
    /// itself on a spoken number).
    var transcriptionPurpose: TranscriptionPurpose? = nil

    /// How long a stop waits for the server transcription before offering a
    /// retry (the recording is kept).
    static let serverTranscriptionTimeout: TimeInterval = 45

    var transcribesOnServer: Bool { transcriptionPurpose != nil }

    static let meal = VoiceProfile(
        name: "meal",
        maximumDuration: 15 * 60,
        maximumCharacters: 12_000,
        prefersFastResults: false,
        autoStopStableInterval: nil,
        finalizationTimeout: 2.5,
        microphoneDeniedMessage: "Microphone access is required to record a meal.",
        transcriptionPurpose: .meal
    )

    static let correction = VoiceProfile(
        name: "correction",
        maximumDuration: 5 * 60,
        maximumCharacters: 4_000,
        prefersFastResults: false,
        autoStopStableInterval: nil,
        finalizationTimeout: 2.5,
        microphoneDeniedMessage: "Microphone access is off for Shudo — turn it on in Settings or type the change.",
        transcriptionPurpose: .correction
    )

    static let onboarding = VoiceProfile(
        name: "onboarding",
        maximumDuration: 10 * 60,
        maximumCharacters: 30_000,
        prefersFastResults: false,
        autoStopStableInterval: nil,
        finalizationTimeout: 2.5,
        microphoneDeniedMessage: "Microphone access is off for Shudo — turn it on in Settings or type instead.",
        transcriptionPurpose: .onboarding
    )

    static let weighIn = VoiceProfile(
        name: "weigh_in",
        maximumDuration: 60,
        maximumCharacters: 500,
        prefersFastResults: true,
        autoStopStableInterval: 1.2,
        finalizationTimeout: 1.5,
        microphoneDeniedMessage: "Microphone access is off for Shudo — type your weight instead."
    )

    static let coach = VoiceProfile(
        name: "coach",
        maximumDuration: 5 * 60,
        maximumCharacters: 4_000,
        prefersFastResults: false,
        autoStopStableInterval: nil,
        finalizationTimeout: 2.5,
        microphoneDeniedMessage: "Microphone access is off for Shudo — turn it on in Settings or type.",
        transcriptionPurpose: .coach
    )

    static let workout = VoiceProfile(
        name: "workout",
        maximumDuration: 5 * 60,
        maximumCharacters: 4_000,
        prefersFastResults: false,
        autoStopStableInterval: nil,
        finalizationTimeout: 2.5,
        microphoneDeniedMessage: "Microphone access is off for Shudo — turn it on in Settings or type.",
        transcriptionPurpose: .workout
    )

    func remainingTime(after elapsed: TimeInterval) -> TimeInterval {
        max(0, maximumDuration - max(0, elapsed))
    }
}

/// Committed recognizer text plus the volatile tail currently being heard.
struct LiveTranscript: Equatable, Sendable {
    private(set) var committed: String
    private(set) var volatile: String
    let characterLimit: Int

    init(characterLimit: Int = VoiceProfile.meal.maximumCharacters) {
        committed = ""
        volatile = ""
        self.characterLimit = max(0, characterLimit)
    }

    mutating func apply(_ event: SpeechEvent) {
        switch event {
        case .volatile(let text):
            volatile = text
        case .finalized(let text):
            committed = Self.bounded(Self.joined(committed, text), limit: characterLimit)
            volatile = ""
        }
    }

    /// Everything heard so far, for the live view and as the fallback take
    /// when the recognizer's final pass doesn't arrive in time.
    var displayText: String {
        Self.bounded(Self.joined(committed, volatile), limit: characterLimit)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only what the recognizer has committed.
    var finalText: String {
        committed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Committed text for live rendering, without leading whitespace.
    var displayCommitted: String {
        String(committed.drop(while: \.isWhitespace))
    }

    /// The volatile tail for live rendering, spaced against the committed text.
    var displayVolatile: String {
        let tail = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return "" }
        let head = displayCommitted
        guard !head.isEmpty else { return tail }
        return Self.joined(head, tail).dropFirst(head.count).description
    }

    var isEmpty: Bool { displayText.isEmpty }

    var isAtLimit: Bool {
        characterLimit > 0 && Self.joined(committed, volatile).utf16.count >= characterLimit
    }

    /// Joins recognizer segments with a single space unless the boundary
    /// already has whitespace or the new segment opens with punctuation.
    static func joined(_ head: String, _ tail: String) -> String {
        guard !head.isEmpty else { return tail }
        guard !tail.isEmpty else { return head }
        if head.last?.isWhitespace == true || tail.first?.isWhitespace == true {
            return head + tail
        }
        if let first = tail.first, ".,!?;:)’'%".contains(first) {
            return head + tail
        }
        return head + " " + tail
    }

    /// Cuts to `limit` UTF-16 units without splitting a grapheme cluster.
    static func bounded(_ text: String, limit: Int) -> String {
        guard limit > 0, text.utf16.count > limit else { return text }
        var result = ""
        var used = 0
        for character in text {
            let width = character.utf16.count
            guard used + width <= limit else { break }
            result.append(character)
            used += width
        }
        return result
    }
}

/// Appends a finished take to an editable note and supports undoing the most
/// recent take. Several takes append in order; the person can edit freely
/// between them.
enum DictationMergePolicy {
    struct AppendRecord: Equatable, Sendable {
        let noteBefore: String
        let noteAfter: String
        let appendedText: String
    }

    struct Result: Equatable, Sendable {
        let note: String
        /// Nil when nothing was appended (empty take or a full field).
        let record: AppendRecord?
        let wasTruncated: Bool
    }

    static func appending(_ take: String, to note: String, limit: Int) -> Result {
        let cleaned = take.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return Result(note: note, record: nil, wasTruncated: false)
        }
        let separator = separator(between: note)
        let available = limit - note.utf16.count - separator.utf16.count
        guard available > 0 else {
            return Result(note: note, record: nil, wasTruncated: true)
        }
        let fitted = LiveTranscript.bounded(cleaned, limit: available)
        guard !fitted.isEmpty else {
            return Result(note: note, record: nil, wasTruncated: true)
        }
        let appended = separator + fitted
        let updated = note + appended
        return Result(
            note: updated,
            record: AppendRecord(noteBefore: note, noteAfter: updated, appendedText: appended),
            wasTruncated: fitted.utf16.count < cleaned.utf16.count
        )
    }

    /// The note with the last take removed, or nil when the person has since
    /// edited the dictated text itself (undo would then guess wrong).
    static func undoing(_ record: AppendRecord, in note: String) -> String? {
        if note == record.noteAfter { return record.noteBefore }
        guard !record.appendedText.isEmpty, note.hasSuffix(record.appendedText) else {
            return nil
        }
        return String(note.dropLast(record.appendedText.count))
    }

    static func canUndo(_ record: AppendRecord?, in note: String) -> Bool {
        guard let record else { return false }
        return undoing(record, in: note) != nil
    }

    private static func separator(between note: String) -> String {
        guard let last = note.last, !last.isWhitespace else { return "" }
        return " "
    }
}

/// What the recognizer assets look like on this device right now.
struct SpeechAssetSnapshot: Equatable, Sendable {
    enum ModuleStatus: Equatable, Sendable {
        /// Not checked yet (cold launch); treated optimistically.
        case checking
        case unsupported
        case needsDownload
        case downloading(progress: Double?)
        case installed

        var diagnosticName: String {
            switch self {
            case .checking: return "checking"
            case .unsupported: return "unsupported"
            case .needsDownload: return "needs_download"
            case .downloading: return "downloading"
            case .installed: return "installed"
            }
        }
    }

    var transcriber: ModuleStatus
    var dictation: ModuleStatus
    /// `SFSpeechRecognizer.supportsOnDeviceRecognition` for the locale.
    var supportsOnDeviceRecognizer: Bool
    var transcriberLocale: Locale?
    var dictationLocale: Locale?

    static let checking = SpeechAssetSnapshot(
        transcriber: .checking,
        dictation: .checking,
        supportsOnDeviceRecognizer: false,
        transcriberLocale: nil,
        dictationLocale: nil
    )
}

enum SpeechAuthorizationState: Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
}

/// Chooses the recognizer for a take.
///
/// 1. `SpeechTranscriber` when its model is installed (best accuracy, live
///    volatile results; contextual strings are ignored by this module).
/// 2. `DictationTranscriber` when installed — takes the personal vocabulary.
/// 3. On-device `SFSpeechRecognizer` as a last resort (never server-side).
/// 4. While the one-time model download runs, voice waits ("Getting voice
///    ready… 42%") and typing keeps working.
/// 5. A still-unchecked cold launch tries `SpeechTranscriber` optimistically.
/// 6. Otherwise voice is unavailable on this device.
enum SpeechEnginePolicy {
    enum Selection: Equatable, Sendable {
        case engine(SpeechEngineID)
        case preparing(progress: Double?)
        case unavailable
    }

    /// The recognizer for a take on `profile`: meals, corrections,
    /// onboarding, the coach and workouts record and transcribe on the server
    /// (better accuracy; no model download, no speech permission); the
    /// weigh-in stays live on-device because it stops itself on a number.
    static func select(
        for profile: VoiceProfile,
        snapshot: SpeechAssetSnapshot,
        speechAuthorization: SpeechAuthorizationState
    ) -> Selection {
        if profile.transcribesOnServer { return .engine(.openAITranscribe) }
        return select(snapshot, speechAuthorization: speechAuthorization)
    }

    /// The idle mic control for `profile`: a server profile never waits on
    /// the on-device model download.
    static func idleAvailability(for profile: VoiceProfile, snapshot: SpeechAssetSnapshot) -> Selection {
        if profile.transcribesOnServer { return .engine(.openAITranscribe) }
        return idleAvailability(snapshot)
    }

    static func select(
        _ snapshot: SpeechAssetSnapshot,
        speechAuthorization: SpeechAuthorizationState
    ) -> Selection {
        let usable = candidates(snapshot, speechAuthorization: speechAuthorization)
        if let installed = usable.first, installed != .speechTranscriber || snapshot.transcriber == .installed {
            return .engine(installed)
        }
        if let progress = downloadProgress(snapshot.transcriber) {
            return .preparing(progress: progress)
        }
        if let progress = downloadProgress(snapshot.dictation) {
            return .preparing(progress: progress)
        }
        if let optimistic = usable.first { return .engine(optimistic) }
        return .unavailable
    }

    /// Every recognizer worth trying for a take, best first. A still
    /// unchecked transcriber (cold launch) is tried optimistically ahead of
    /// the fallbacks.
    static func candidates(
        _ snapshot: SpeechAssetSnapshot,
        speechAuthorization: SpeechAuthorizationState
    ) -> [SpeechEngineID] {
        var engines: [SpeechEngineID] = []
        if snapshot.transcriber == .installed || snapshot.transcriber == .checking {
            engines.append(.speechTranscriber)
        }
        if snapshot.dictation == .installed {
            engines.append(.dictationTranscriber)
        }
        // The legacy recognizer strictly requires speech authorization; the
        // analyzer modules' requirement is undocumented, so only this one is
        // gated on it.
        if snapshot.supportsOnDeviceRecognizer, speechAuthorization != .denied {
            engines.append(.sfSpeechOnDevice)
        }
        return engines
    }

    /// What the idle mic control should show before any tap: only a running
    /// first-time download disables it.
    static func idleAvailability(_ snapshot: SpeechAssetSnapshot) -> Selection {
        let selection = select(snapshot, speechAuthorization: .notDetermined)
        if case .preparing = selection { return selection }
        return .engine(.speechTranscriber)
    }

    /// Outer optional: whether the module is mid-download at all; inner: the
    /// fraction when known.
    private static func downloadProgress(_ status: SpeechAssetSnapshot.ModuleStatus) -> Double?? {
        switch status {
        case .needsDownload: return .some(nil)
        case .downloading(let progress): return .some(progress)
        default: return nil
        }
    }
}

/// Short phrases the fallback recognizers should favor (brands and meals
/// Luke actually logs). Used only by DictationTranscriber and the on-device
/// SFSpeechRecognizer; SpeechTranscriber ignores contextual strings.
enum PersonalVocabulary {
    static let maximumTerms = 100
    static let maximumTermLength = 48

    static let staples: [String] = [
        "Fairlife", "Chobani", "Oikos", "Siggi's", "Premier Protein",
        "Optimum Nutrition", "Gold Standard whey", "Core Power", "Muscle Milk",
        "Barebells", "Quest bar", "RXBAR", "Kirkland", "Trader Joe's",
        "Chipotle", "Sweetgreen", "CAVA", "Chick-fil-A", "Shake Shack",
        "Five Guys", "Panera", "Starbucks", "Dunkin'", "Huel", "Ghost whey",
        "overnight oats", "Greek yogurt", "cottage cheese", "whole milk",
        "two percent milk", "protein shake", "scoop of whey",
    ]

    static func terms(fromMealTitles titles: [String]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        func add(_ raw: String) {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= maximumTermLength else { return }
            let key = term.lowercased()
            guard seen.insert(key).inserted else { return }
            terms.append(term)
        }
        for title in titles {
            guard terms.count < maximumTerms else { break }
            add(title)
        }
        for staple in staples {
            guard terms.count < maximumTerms else { break }
            add(staple)
        }
        return terms
    }
}

/// Strings shown around voice capture, shared by every screen.
enum VoiceCopy {
    static let speechDenied =
        "Speech recognition is off for Shudo — turn it on in Settings or type."
    static let unsupported = "Voice isn’t available on this device — type it instead."
    static let keptWhatWasHeard = "Kept what I heard."
    static let didNotCatchThat = "Didn’t catch that — try again or type it."
    static let reachedTimeLimit = "Recording stopped at the time limit."
    static let reachedLengthLimit = "That’s the max length."
    static let microphoneFailed = "The microphone couldn’t start. Try again."
    static let microphoneSlow = "The microphone is taking too long to start. Try again."
    static let recognizerFailed = "Voice couldn’t start. Try again or type it."
    static let transcribing = "Transcribing…"
    static let transcriptionOffline =
        "Couldn’t reach Shudo to transcribe. Your recording is kept — retry when you’re online."
    static let transcriptionTimedOut =
        "Transcribing took too long. Your recording is kept — retry or discard it."
    static let transcriptionFailed = "Transcription failed. Your recording is kept — retry or discard it."
    static let transcriptionSignedOut = "Sign in again to transcribe. Your recording is kept."

    static func preparing(progress: Double?) -> String {
        guard let progress else { return "Getting voice ready…" }
        let percent = Int((min(1, max(0, progress)) * 100).rounded())
        return "Getting voice ready… \(percent)%"
    }

    static func clock(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
