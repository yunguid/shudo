import AVFoundation
import Combine
import Foundation
import Testing
@testable import shudo

// MARK: - Pure policies

struct LiveTranscriptTests {
    @Test func volatileResultsReplaceTheTailAndFinalsCommit() {
        var transcript = LiveTranscript(characterLimit: 1_000)
        transcript.apply(.volatile("two"))
        transcript.apply(.volatile("two scrambled"))
        #expect(transcript.displayText == "two scrambled")
        #expect(transcript.finalText.isEmpty)

        transcript.apply(.finalized("Two scrambled eggs."))
        #expect(transcript.finalText == "Two scrambled eggs.")
        #expect(transcript.displayText == "Two scrambled eggs.")
        #expect(transcript.volatile.isEmpty)

        transcript.apply(.volatile("and toast"))
        #expect(transcript.displayText == "Two scrambled eggs. and toast")
        #expect(transcript.displayCommitted == "Two scrambled eggs.")
        #expect(transcript.displayVolatile == " and toast")
        #expect(transcript.finalText == "Two scrambled eggs.")

        transcript.apply(.finalized(" And toast."))
        #expect(transcript.finalText == "Two scrambled eggs. And toast.")
    }

    @Test func segmentsJoinWithoutDoubledSpacesOrSpaceBeforePunctuation() {
        #expect(LiveTranscript.joined("", "eggs") == "eggs")
        #expect(LiveTranscript.joined("eggs", "") == "eggs")
        #expect(LiveTranscript.joined("eggs", "toast") == "eggs toast")
        #expect(LiveTranscript.joined("eggs ", "toast") == "eggs toast")
        #expect(LiveTranscript.joined("eggs", " toast") == "eggs toast")
        #expect(LiveTranscript.joined("two eggs", ", toast") == "two eggs, toast")
        #expect(LiveTranscript.joined("two eggs", ".") == "two eggs.")
    }

    @Test func characterCapNeverSplitsAGraphemeAndReportsTheLimit() {
        var transcript = LiveTranscript(characterLimit: 10)
        transcript.apply(.finalized("12345678🍕🍕"))
        #expect(transcript.finalText == "12345678🍕")
        #expect(transcript.finalText.utf16.count == 10)
        #expect(transcript.isAtLimit)
        #expect(!transcript.finalText.contains("�"))

        var roomy = LiveTranscript(characterLimit: 100)
        roomy.apply(.volatile("short"))
        #expect(!roomy.isAtLimit)
    }

    @Test func emptyAndWhitespaceTranscriptsAreEmpty() {
        var transcript = LiveTranscript(characterLimit: 100)
        #expect(transcript.isEmpty)
        transcript.apply(.volatile("   "))
        #expect(transcript.isEmpty)
        transcript.apply(.finalized("  "))
        #expect(transcript.isEmpty)
    }
}

struct DictationMergePolicyTests {
    @Test func takesAppendInOrderWithASingleSpace() {
        let first = DictationMergePolicy.appending("Two eggs.", to: "", limit: 100)
        #expect(first.note == "Two eggs.")
        let second = DictationMergePolicy.appending("  And toast.  ", to: first.note, limit: 100)
        #expect(second.note == "Two eggs. And toast.")
        #expect(second.record?.appendedText == " And toast.")
        #expect(!second.wasTruncated)

        let afterNewline = DictationMergePolicy.appending("Coffee", to: "Breakfast\n", limit: 100)
        #expect(afterNewline.note == "Breakfast\nCoffee")
    }

    @Test func emptyTakesAppendNothing() {
        let result = DictationMergePolicy.appending("   ", to: "Typed", limit: 100)
        #expect(result.note == "Typed")
        #expect(result.record == nil)
        #expect(!result.wasTruncated)
    }

    @Test func theFieldLimitTruncatesTheTakeNotTheNote() {
        let note = String(repeating: "a", count: 8)
        let result = DictationMergePolicy.appending("bcdefgh", to: note, limit: 12)
        #expect(result.note == "aaaaaaaa bcd")
        #expect(result.note.utf16.count == 12)
        #expect(result.wasTruncated)

        let full = DictationMergePolicy.appending("more", to: String(repeating: "x", count: 12), limit: 12)
        #expect(full.note == String(repeating: "x", count: 12))
        #expect(full.record == nil)
        #expect(full.wasTruncated)
    }

    @Test func undoRemovesTheLastTakeOnlyWhileItIsStillIntact() throws {
        let appended = DictationMergePolicy.appending("with honey", to: "Greek yogurt", limit: 100)
        let record = try #require(appended.record)
        #expect(DictationMergePolicy.undoing(record, in: appended.note) == "Greek yogurt")

        // Edits before the dictated text keep undo available.
        let editedPrefix = "Plain Greek yogurt with honey"
        #expect(DictationMergePolicy.undoing(record, in: editedPrefix) == "Plain Greek yogurt")

        // Editing the dictated words themselves disables undo.
        #expect(DictationMergePolicy.undoing(record, in: "Greek yogurt with maple") == nil)
        #expect(!DictationMergePolicy.canUndo(record, in: "Greek yogurt with maple"))
        #expect(!DictationMergePolicy.canUndo(nil, in: "anything"))
    }
}

struct SpeechEnginePolicyTests {
    private func snapshot(
        transcriber: SpeechAssetSnapshot.ModuleStatus,
        dictation: SpeechAssetSnapshot.ModuleStatus = .unsupported,
        legacy: Bool = false
    ) -> SpeechAssetSnapshot {
        SpeechAssetSnapshot(
            transcriber: transcriber,
            dictation: dictation,
            supportsOnDeviceRecognizer: legacy,
            transcriberLocale: Locale(identifier: "en_US"),
            dictationLocale: Locale(identifier: "en_US")
        )
    }

    @Test func installedTranscriberAlwaysWins() {
        #expect(SpeechEnginePolicy.select(
            snapshot(transcriber: .installed, dictation: .installed, legacy: true),
            speechAuthorization: .denied
        ) == .engine(.speechTranscriber))
    }

    @Test func dictationCoversTheTranscriberDownload() {
        #expect(SpeechEnginePolicy.select(
            snapshot(transcriber: .downloading(progress: 0.3), dictation: .installed),
            speechAuthorization: .authorized
        ) == .engine(.dictationTranscriber))
        #expect(SpeechEnginePolicy.select(
            snapshot(transcriber: .needsDownload, dictation: .installed),
            speechAuthorization: .notDetermined
        ) == .engine(.dictationTranscriber))
    }

    @Test func onDeviceRecognizerIsTheLastResortAndNeedsAuthorization() {
        #expect(SpeechEnginePolicy.select(
            snapshot(transcriber: .unsupported, legacy: true),
            speechAuthorization: .authorized
        ) == .engine(.sfSpeechOnDevice))
        #expect(SpeechEnginePolicy.select(
            snapshot(transcriber: .unsupported, legacy: true),
            speechAuthorization: .denied
        ) == .unavailable)
    }

    @Test func aRunningDownloadWaitsInsteadOfFailing() {
        #expect(SpeechEnginePolicy.select(
            snapshot(transcriber: .downloading(progress: 0.42)),
            speechAuthorization: .authorized
        ) == .preparing(progress: 0.42))
        #expect(SpeechEnginePolicy.select(
            snapshot(transcriber: .needsDownload),
            speechAuthorization: .authorized
        ) == .preparing(progress: nil))
        #expect(SpeechEnginePolicy.select(
            snapshot(transcriber: .unsupported, dictation: .downloading(progress: 0.1)),
            speechAuthorization: .authorized
        ) == .preparing(progress: 0.1))
    }

    @Test func anUncheckedColdLaunchTriesTheTranscriberOptimistically() {
        #expect(SpeechEnginePolicy.select(.checking, speechAuthorization: .notDetermined)
            == .engine(.speechTranscriber))
        #expect(SpeechEnginePolicy.candidates(
            snapshot(transcriber: .checking, dictation: .installed, legacy: true),
            speechAuthorization: .authorized
        ) == [.speechTranscriber, .dictationTranscriber, .sfSpeechOnDevice])
    }

    @Test func nothingUsableIsUnavailable() {
        #expect(SpeechEnginePolicy.select(
            snapshot(transcriber: .unsupported),
            speechAuthorization: .authorized
        ) == .unavailable)
    }

    @Test func onlyADownloadDisablesTheIdleMic() {
        #expect(SpeechEnginePolicy.idleAvailability(snapshot(transcriber: .downloading(progress: 0.5)))
            == .preparing(progress: 0.5))
        #expect(SpeechEnginePolicy.idleAvailability(.checking) == .engine(.speechTranscriber))
        #expect(SpeechEnginePolicy.idleAvailability(snapshot(transcriber: .unsupported))
            == .engine(.speechTranscriber))
    }

    @Test func engineIdentifiersMatchTheServerAllowlist() {
        #expect(SpeechEngineID.allCases.map(\.rawValue) == [
            "apple.speech_transcriber",
            "apple.dictation_transcriber",
            "apple.sf_speech_on_device",
        ])
    }
}

struct VoiceProfileTests {
    @Test func profilesCarryTheirFieldLimitsAndDurations() {
        #expect(VoiceProfile.meal.maximumDuration == 15 * 60)
        #expect(VoiceProfile.meal.maximumCharacters == EntryComposerPolicy.maximumNoteLength)
        #expect(VoiceProfile.correction.maximumDuration == 5 * 60)
        #expect(VoiceProfile.correction.maximumCharacters == EntryCorrectionPolicy.maximumCharacters)
        #expect(VoiceProfile.onboarding.maximumDuration == 10 * 60)
        #expect(VoiceProfile.onboarding.maximumCharacters == OnboardingCapturePolicy.maximumTextCharacters)
        #expect(VoiceProfile.weighIn.maximumDuration == 60)
        #expect(VoiceProfile.weighIn.prefersFastResults)
        #expect(VoiceProfile.weighIn.autoStopStableInterval == 1.2)
        #expect(VoiceProfile.coach.maximumCharacters == 4_000)
        #expect(VoiceProfile.meal.microphoneDeniedMessage == "Microphone access is required to record a meal.")
    }

    @Test func remainingTimeIsClamped() {
        #expect(VoiceProfile.meal.remainingTime(after: -1) == 15 * 60)
        #expect(VoiceProfile.meal.remainingTime(after: 60) == 14 * 60)
        #expect(VoiceProfile.meal.remainingTime(after: 16 * 60) == 0)
    }

    @Test func meterKeepsTheRecorderCurveAndWindow() {
        #expect(VoiceMeterPolicy.amplitude(decibels: 0) == 1)
        #expect(VoiceMeterPolicy.amplitude(decibels: -160) == VoiceMeterPolicy.floorLevel)
        var levels = VoiceMeterPolicy.restingLevels
        for _ in 0..<40 { levels = VoiceMeterPolicy.appending(0.5, to: levels) }
        #expect(levels.count == VoiceMeterPolicy.barCount)
        #expect(levels.allSatisfy { $0 == 0.5 })
    }

    @Test func preparingCopyShowsTheDownloadPercent() {
        #expect(VoiceCopy.preparing(progress: 0.42) == "Getting voice ready… 42%")
        #expect(VoiceCopy.preparing(progress: nil) == "Getting voice ready…")
        #expect(VoiceCopy.clock(75) == "1:15")
    }
}

struct RecognizerSegmenterTests {
    @Test func cumulativePartialsStayVolatileUntilFinal() {
        let segmenter = RecognizerSegmenter()
        #expect(segmenter.events(for: "two", isFinal: false) == [.volatile("two")])
        #expect(segmenter.events(for: "two eggs", isFinal: false) == [.volatile("two eggs")])
        #expect(segmenter.events(for: "Two eggs.", isFinal: true) == [.finalized("Two eggs.")])
    }

    @Test func aSilentRestartAfterAPauseCommitsTheEarlierSegment() {
        let segmenter = RecognizerSegmenter()
        _ = segmenter.events(for: "two scrambled eggs and toast", isFinal: false)
        #expect(segmenter.events(for: "coffee", isFinal: false) == [
            .finalized("two scrambled eggs and toast"),
            .volatile("coffee"),
        ])
    }
}

struct PersonalVocabularyTests {
    @Test func titlesLeadThenStaplesDedupedAndCapped() {
        let terms = PersonalVocabulary.terms(fromMealTitles: [
            "Fairlife shake", "fairlife SHAKE", "  ", String(repeating: "x", count: 80),
        ])
        #expect(terms.first == "Fairlife shake")
        #expect(terms.filter { $0.lowercased() == "fairlife shake" }.count == 1)
        #expect(!terms.contains { $0.count > PersonalVocabulary.maximumTermLength })
        #expect(terms.contains("Chipotle"))

        let many = (0..<300).map { "Meal \($0)" }
        #expect(PersonalVocabulary.terms(fromMealTitles: many).count == PersonalVocabulary.maximumTerms)
    }
}

#if DEBUG
struct ScriptedVoiceConfigurationTests {
    @Test func launchArgumentsSelectTheScriptedEnvironment() {
        #expect(ScriptedVoiceConfiguration.parse(["app"]) == nil)
        #expect(ScriptedVoiceConfiguration.parse(["app", "-shudoScriptedSpeech", "oats"])
            == ScriptedVoiceConfiguration(text: "oats", mode: .normal))
        #expect(ScriptedVoiceConfiguration.parse(["app", "-shudoScriptedSpeechMode", "denied"])
            == ScriptedVoiceConfiguration(text: ScriptedVoiceConfiguration.defaultText, mode: .denied))
        #expect(ScriptedVoiceConfiguration.snapshot(for: .downloading).transcriber
            == .downloading(progress: 0.42))
    }
}
#endif

// MARK: - VoiceTranscriber

@MainActor
private final class FakeAudioCapture: AudioCapturing {
    var blocksStart = false
    var startError: Error?
    var currentPowerDecibels: Float = -20
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var onEvent: (@MainActor (AudioCaptureEvent) -> Void)?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    var isWaitingAtGate: Bool { gate != nil }

    func start(onEvent: @escaping @MainActor (AudioCaptureEvent) -> Void) async throws -> AudioCaptureRun {
        startCount += 1
        self.onEvent = onEvent
        if blocksStart {
            await withCheckedContinuation { gate = $0 }
        }
        if let startError { throw startError }
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream()
        self.continuation = continuation
        return AudioCaptureRun(
            format: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!,
            buffers: stream
        )
    }

    func releaseStart() {
        gate?.resume()
        gate = nil
    }

    func stop() {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func send(_ event: AudioCaptureEvent) {
        onEvent?(event)
    }
}

private final class FakeSpeechEngine: SpeechEngine, @unchecked Sendable {
    let id: SpeechEngineID
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation?
    private var _startError: Error?
    private var _finishHangs = false
    private var _finalText: String?
    private var _started = false
    private var _finished = false
    private var _canceled = false

    init(id: SpeechEngineID) {
        self.id = id
    }

    var startError: Error? {
        get { lock.withLock { _startError } }
        set { lock.withLock { _startError = newValue } }
    }
    var finishHangs: Bool {
        get { lock.withLock { _finishHangs } }
        set { lock.withLock { _finishHangs = newValue } }
    }
    var finalText: String? {
        get { lock.withLock { _finalText } }
        set { lock.withLock { _finalText = newValue } }
    }
    var started: Bool { lock.withLock { _started } }
    var finished: Bool { lock.withLock { _finished } }
    var canceled: Bool { lock.withLock { _canceled } }

    func start(locale: Locale, profile: VoiceProfile, vocabulary: [String]) async throws -> SpeechRun {
        if let error = startError { throw error }
        let (events, continuation) = AsyncThrowingStream<SpeechEvent, Error>.makeStream()
        lock.withLock {
            self.continuation = continuation
            _started = true
        }
        return SpeechRun(format: nil, events: events)
    }

    func emit(_ event: SpeechEvent) {
        _ = lock.withLock { continuation }?.yield(event)
    }

    func fail(_ error: Error) {
        lock.withLock { continuation }?.finish(throwing: error)
    }

    func append(_ buffer: AVAudioPCMBuffer) {}

    func finish() async throws {
        lock.withLock { _finished = true }
        if finishHangs {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return
        }
        let continuation = lock.withLock { self.continuation }
        if let finalText { continuation?.yield(.finalized(finalText)) }
        continuation?.finish()
    }

    func cancel() async {
        let continuation = lock.withLock { () -> AsyncThrowingStream<SpeechEvent, Error>.Continuation? in
            _canceled = true
            return self.continuation
        }
        continuation?.finish()
    }
}

@MainActor
private final class FakeVoicePermissions: VoicePermissionProviding {
    var microphone = true
    var speech: SpeechAuthorizationState = .authorized

    func requestMicrophone() async -> Bool { microphone }

    func speechAuthorization(requestIfNeeded: Bool) async -> SpeechAuthorizationState { speech }
}

@MainActor
private final class FakeSpeechAssets: SpeechAssetProviding {
    @Published var snapshot: SpeechAssetSnapshot

    init(_ snapshot: SpeechAssetSnapshot) {
        self.snapshot = snapshot
    }

    var snapshotUpdates: AnyPublisher<SpeechAssetSnapshot, Never> {
        $snapshot.removeDuplicates().eraseToAnyPublisher()
    }

    func prepare() {}

    func resolvedSnapshot() async -> SpeechAssetSnapshot { snapshot }
}

@MainActor
private struct VoiceHarness {
    let capture = FakeAudioCapture()
    let permissions = FakeVoicePermissions()
    let assets: FakeSpeechAssets
    let engines: [SpeechEngineID: FakeSpeechEngine] = Dictionary(
        uniqueKeysWithValues: SpeechEngineID.allCases.map { ($0, FakeSpeechEngine(id: $0)) }
    )

    init(snapshot: SpeechAssetSnapshot = VoiceHarness.installed) {
        assets = FakeSpeechAssets(snapshot)
    }

    nonisolated static let installed = SpeechAssetSnapshot(
        transcriber: .installed,
        dictation: .installed,
        supportsOnDeviceRecognizer: true,
        transcriberLocale: Locale(identifier: "en_US"),
        dictationLocale: Locale(identifier: "en_US")
    )

    var transcriberEngine: FakeSpeechEngine { engines[.speechTranscriber]! }

    func makeTranscriber(profile: VoiceProfile = .meal) -> VoiceTranscriber {
        let capture = self.capture
        let engines = self.engines
        return VoiceTranscriber(
            profile: profile,
            environment: VoiceEnvironment(
                permissions: permissions,
                assets: assets,
                makeCapture: { capture },
                makeEngine: { engines[$0]! },
                vocabulary: { ["Fairlife"] }
            )
        )
    }
}

@MainActor
private func eventually(
    timeout: TimeInterval = 3,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return true
}

private func profile(
    maximumDuration: TimeInterval = 60,
    maximumCharacters: Int = 1_000,
    autoStop: TimeInterval? = nil,
    finalizationTimeout: TimeInterval = 2
) -> VoiceProfile {
    VoiceProfile(
        name: "test",
        maximumDuration: maximumDuration,
        maximumCharacters: maximumCharacters,
        prefersFastResults: false,
        autoStopStableInterval: autoStop,
        finalizationTimeout: finalizationTimeout,
        microphoneDeniedMessage: "Mic off."
    )
}

@MainActor
struct VoiceTranscriberTests {
    @Test func startListensAndStopReturnsTheFinalizedTake() async {
        let harness = VoiceHarness()
        let voice = harness.makeTranscriber()
        #expect(voice.phase == .idle)
        #expect(voice.controlState == "idle")

        let started = await voice.start()
        #expect(started)
        #expect(voice.phase == .listening)
        #expect(voice.controlState == "recording")
        #expect(voice.activeEngine == .speechTranscriber)

        harness.transcriberEngine.emit(.volatile("two scrambled"))
        #expect(await eventually { voice.transcript.displayText == "two scrambled" })

        harness.transcriberEngine.finalText = "Two scrambled eggs and toast."
        let take = await voice.stop()
        #expect(take?.text == "Two scrambled eggs and toast.")
        #expect(take?.engine == .speechTranscriber)
        #expect(harness.transcriberEngine.finished)
        #expect(harness.capture.stopCount >= 1)
        #expect(voice.phase == .idle)
        #expect(voice.notice == nil)
        // Handed out once.
        #expect(await voice.stop() == nil)
        #expect(voice.collectReadyTake() == nil)
    }

    @Test func aSlowFinalPassKeepsCommittedAndVolatileText() async {
        let harness = VoiceHarness()
        let voice = harness.makeTranscriber()
        harness.transcriberEngine.finishHangs = true
        #expect(await voice.start())

        harness.transcriberEngine.emit(.finalized("Greek yogurt"))
        harness.transcriberEngine.emit(.volatile("with honey"))
        #expect(await eventually { voice.transcript.displayText == "Greek yogurt with honey" })

        let clock = ContinuousClock()
        let began = clock.now
        let take = await voice.stop(finalizationTimeout: 0.2)
        #expect(clock.now - began < .seconds(2))
        #expect(take?.text == "Greek yogurt with honey")
        #expect(voice.phase == .idle)
    }

    @Test func anInterruptionEndsTheTakeAndKeepsWhatWasHeard() async {
        let harness = VoiceHarness()
        let voice = harness.makeTranscriber()
        #expect(await voice.start())
        harness.transcriberEngine.emit(.finalized("Chicken bowl"))
        #expect(await eventually { voice.transcript.finalText == "Chicken bowl" })

        harness.capture.send(.interrupted)
        #expect(harness.capture.stopCount >= 1)
        #expect(await eventually { voice.phase == .ready })
        #expect(voice.notice == .keptWhatWasHeard)
        let take = voice.collectReadyTake()
        #expect(take?.text == "Chicken bowl")
        #expect(voice.phase == .idle)
        #expect(voice.collectReadyTake() == nil)
    }

    @Test func finishInBackgroundFreesTheMicNowAndParksTheTake() async {
        let harness = VoiceHarness()
        let voice = harness.makeTranscriber()
        #expect(await voice.start())
        harness.transcriberEngine.emit(.volatile("oatmeal"))
        #expect(await eventually { !voice.transcript.isEmpty })

        voice.finishInBackground()
        #expect(harness.capture.stopCount == 1)
        #expect(voice.phase == .finishing)
        #expect(await eventually { voice.phase == .ready })
        #expect(await voice.stop()?.text == "oatmeal")
    }

    @Test func aDeniedMicrophoneIsUnavailableWithTheProfileMessage() async {
        let harness = VoiceHarness()
        harness.permissions.microphone = false
        let voice = harness.makeTranscriber()

        #expect(await voice.start() == false)
        #expect(voice.phase == .unavailable(.microphoneDenied))
        #expect(voice.errorMessage == "Microphone access is required to record a meal.")
        #expect(voice.needsSettings)
        #expect(harness.capture.startCount == 0)
    }

    @Test func deniedSpeechWithOnlyTheLegacyRecognizerExplainsIt() async {
        let harness = VoiceHarness(snapshot: SpeechAssetSnapshot(
            transcriber: .unsupported,
            dictation: .unsupported,
            supportsOnDeviceRecognizer: true,
            transcriberLocale: nil,
            dictationLocale: nil
        ))
        harness.permissions.speech = .denied
        let voice = harness.makeTranscriber()

        #expect(await voice.start() == false)
        #expect(voice.phase == .unavailable(.speechDenied))
        #expect(voice.errorMessage == VoiceCopy.speechDenied)
    }

    @Test func noRecognizerAtAllIsUnsupported() async {
        let harness = VoiceHarness(snapshot: SpeechAssetSnapshot(
            transcriber: .unsupported,
            dictation: .unsupported,
            supportsOnDeviceRecognizer: false,
            transcriberLocale: nil,
            dictationLocale: nil
        ))
        let voice = harness.makeTranscriber()
        #expect(await voice.start() == false)
        #expect(voice.phase == .unavailable(.unsupported))
        #expect(voice.errorMessage == VoiceCopy.unsupported)
        #expect(!voice.needsSettings)
    }

    @Test func theModelDownloadDisablesTheMicAndProgressFollowsTheAssets() async {
        let downloading = SpeechAssetSnapshot(
            transcriber: .downloading(progress: 0.42),
            dictation: .unsupported,
            supportsOnDeviceRecognizer: false,
            transcriberLocale: Locale(identifier: "en_US"),
            dictationLocale: nil
        )
        let harness = VoiceHarness(snapshot: downloading)
        let voice = harness.makeTranscriber()
        #expect(voice.phase == .preparingModel(progress: 0.42))
        #expect(voice.isPreparingModel)

        #expect(await voice.start() == false)
        #expect(voice.phase == .preparingModel(progress: 0.42))
        #expect(harness.capture.startCount == 0)

        var progressed = downloading
        progressed.transcriber = .downloading(progress: 0.9)
        harness.assets.snapshot = progressed
        #expect(voice.phase == .preparingModel(progress: 0.9))

        var installed = downloading
        installed.transcriber = .installed
        harness.assets.snapshot = installed
        #expect(voice.phase == .idle)
        #expect(await voice.start())
        voice.cancel()
    }

    @Test func abortingAWarmUpReleasesTheMicAndStartsNothing() async {
        let harness = VoiceHarness()
        harness.capture.blocksStart = true
        let voice = harness.makeTranscriber()

        let starting = Task { await voice.start() }
        #expect(await eventually { harness.capture.isWaitingAtGate })
        #expect(voice.phase == .starting)

        voice.abortStarting()
        #expect(voice.phase == .idle)
        harness.capture.releaseStart()
        #expect(await starting.value == false)
        #expect(voice.phase == .idle)
        #expect(harness.capture.stopCount >= 1)
        #expect(await eventually { harness.transcriberEngine.canceled })

        // Aborting with nothing in flight changes nothing.
        voice.abortStarting()
        #expect(voice.phase == .idle)
    }

    @Test func eventsArrivingAfterCancelAreIgnored() async {
        let harness = VoiceHarness()
        let voice = harness.makeTranscriber()
        #expect(await voice.start())
        harness.transcriberEngine.emit(.volatile("first"))
        #expect(await eventually { voice.transcript.displayText == "first" })

        voice.cancel()
        #expect(voice.phase == .idle)
        #expect(voice.transcript.isEmpty)
        harness.transcriberEngine.emit(.finalized("late words"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(voice.transcript.isEmpty)
        #expect(voice.collectReadyTake() == nil)
        #expect(await eventually { harness.transcriberEngine.canceled })
    }

    @Test func anEmptyTakeReturnsNothingAndSaysSo() async {
        let harness = VoiceHarness()
        let voice = harness.makeTranscriber()
        #expect(await voice.start())
        #expect(await voice.stop() == nil)
        #expect(voice.notice == .didNotCatchThat)
        #expect(voice.phase == .idle)
    }

    @Test func aRecognizerThatWontStartFallsThroughToTheNextOne() async {
        let harness = VoiceHarness()
        harness.transcriberEngine.startError = SpeechEngineError.noCompatibleAudioFormat
        let voice = harness.makeTranscriber()
        #expect(await voice.start())
        #expect(voice.activeEngine == .dictationTranscriber)

        let dictation = harness.engines[.dictationTranscriber]!
        dictation.finalText = "Fairlife shake"
        let take = await voice.stop()
        #expect(take?.engine == .dictationTranscriber)
        #expect(take?.text == "Fairlife shake")
    }

    @Test func whenEveryRecognizerFailsTheTakeFailsHonestly() async {
        let harness = VoiceHarness()
        for engine in harness.engines.values {
            engine.startError = SpeechEngineError.noCompatibleAudioFormat
        }
        let voice = harness.makeTranscriber()
        #expect(await voice.start() == false)
        #expect(voice.phase == .failed(VoiceCopy.recognizerFailed))
        #expect(harness.capture.stopCount >= 1)
    }

    @Test func aMicrophoneThatWontStartShowsTheRecorderMessage() async {
        struct Broken: Error {}
        let harness = VoiceHarness()
        harness.capture.startError = Broken()
        let voice = harness.makeTranscriber()
        #expect(await voice.start() == false)
        #expect(voice.phase == .failed(VoiceCopy.microphoneFailed))
        #expect(await eventually { harness.transcriberEngine.canceled })
    }

    @Test func theTimeLimitEndsTheTakeAndKeepsTheText() async {
        let harness = VoiceHarness()
        let voice = harness.makeTranscriber(profile: profile(maximumDuration: 0.25))
        #expect(await voice.start())
        harness.transcriberEngine.emit(.finalized("A long meal"))
        #expect(await eventually { voice.phase == .ready })
        #expect(voice.notice == .reachedTimeLimit)
        #expect(voice.collectReadyTake()?.text == "A long meal")
    }

    @Test func theLengthLimitEndsTheTake() async {
        let harness = VoiceHarness()
        let voice = harness.makeTranscriber(profile: profile(maximumCharacters: 12))
        #expect(await voice.start())
        harness.transcriberEngine.emit(.finalized("one two three four five"))
        #expect(await eventually { voice.phase == .ready })
        #expect(voice.notice == .reachedLengthLimit)
        #expect(voice.collectReadyTake()?.text == "one two thre")
    }

    @Test func autoStopFiresOnceTheConditionHoldsSteady() async {
        let harness = VoiceHarness()
        let voice = harness.makeTranscriber(profile: profile(autoStop: 0.1))
        voice.autoStopCondition = { $0.displayText.contains("172") }
        #expect(await voice.start())
        harness.transcriberEngine.emit(.volatile("one seventy"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(voice.phase == .listening)
        harness.transcriberEngine.emit(.volatile("172 pounds"))
        #expect(await eventually { voice.phase == .ready })
        #expect(voice.collectReadyTake()?.text == "172 pounds")
    }

    @Test func aRecognizerErrorBeforeAnyWordsIsAFailureNotSilence() async {
        struct RecognizerBroke: Error {}
        let harness = VoiceHarness()
        let voice = harness.makeTranscriber()
        #expect(await voice.start())
        harness.transcriberEngine.fail(RecognizerBroke())
        #expect(await eventually { voice.phase == .failed(VoiceCopy.recognizerFailed) })
        #expect(harness.capture.stopCount >= 1)
        #expect(voice.collectReadyTake() == nil)
    }

    @Test func aRecognizerErrorAfterWordsKeepsThem() async {
        struct RecognizerBroke: Error {}
        let harness = VoiceHarness()
        let voice = harness.makeTranscriber()
        #expect(await voice.start())
        harness.transcriberEngine.emit(.volatile("protein shake"))
        #expect(await eventually { !voice.transcript.isEmpty })
        harness.transcriberEngine.fail(RecognizerBroke())
        #expect(await eventually { voice.phase == .ready })
        #expect(voice.notice == .keptWhatWasHeard)
        #expect(voice.collectReadyTake()?.text == "protein shake")
    }

    @Test func aSecondStartWhileBusyIsRejected() async {
        let harness = VoiceHarness()
        let voice = harness.makeTranscriber()
        #expect(await voice.start())
        #expect(await voice.start() == false)
        #expect(harness.capture.startCount == 1)
        voice.cancel()
    }

    @Test func routeChangesDoNotDisturbAnIdleTranscriber() {
        let harness = VoiceHarness()
        let voice = harness.makeTranscriber()
        _ = AudioSessionController.shared
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
            ]
        )
        #expect(voice.phase == .idle)
    }

    @Test func sessionOwnershipPreemptsThePreviousOwner() {
        let controller = AudioSessionController.shared
        var firstEvents: [AudioSessionEvent] = []
        let first = controller.claim { firstEvents.append($0) }
        let second = controller.claim { _ in }
        #expect(firstEvents == [.preempted])
        #expect(!controller.isOwner(first))
        #expect(controller.isOwner(second))
        controller.release(first)
        #expect(controller.isOwner(second))
        controller.release(second)
        #expect(!controller.isOwner(second))
    }
}
