import AVFoundation
import Combine
import Foundation
import Speech

/// One finished dictation: the words to put in the note, which on-device
/// recognizer heard them, and how long the person spoke.
struct VoiceTake: Equatable, Identifiable, Sendable {
    let id: UUID
    let text: String
    let engine: SpeechEngineID
    let duration: TimeInterval

    init(id: UUID = UUID(), text: String, engine: SpeechEngineID, duration: TimeInterval) {
        self.id = id
        self.text = text
        self.engine = engine
        self.duration = duration
    }
}

enum VoiceUnavailableReason: Equatable, Sendable {
    case microphoneDenied
    case speechDenied
    case unsupported
}

@MainActor
protocol VoicePermissionProviding: AnyObject {
    func requestMicrophone() async -> Bool
    func speechAuthorization(requestIfNeeded: Bool) async -> SpeechAuthorizationState
}

/// Everything a `VoiceTranscriber` needs from the outside world, injectable
/// so tests and the DEBUG scripted harness never touch the real microphone.
@MainActor
struct VoiceEnvironment {
    var permissions: any VoicePermissionProviding
    var assets: any SpeechAssetProviding
    var makeCapture: @MainActor () -> any AudioCapturing
    var makeEngine: @MainActor (SpeechEngineID) -> any SpeechEngine
    var vocabulary: @MainActor () -> [String]

    static var live: VoiceEnvironment {
        VoiceEnvironment(
            permissions: LiveVoicePermissions.shared,
            assets: SpeechAssetPreparer.shared,
            makeCapture: { MicrophoneCapture() },
            makeEngine: { id in
                switch id {
                case .speechTranscriber: return AnalyzerSpeechEngine(module: .transcriber)
                case .dictationTranscriber: return AnalyzerSpeechEngine(module: .dictation)
                case .sfSpeechOnDevice: return OnDeviceRecognizerEngine()
                }
            },
            vocabulary: { VoiceVocabularyStore.shared.terms }
        )
    }

    /// The live environment, or — in DEBUG builds launched with
    /// `-shudoScriptedSpeech "<text>"` / `-shudoScriptedSpeechMode …` — the
    /// deterministic scripted one used by PolishPreview and UI tests.
    static var current: VoiceEnvironment {
        #if DEBUG
        if let scripted = ScriptedVoiceConfiguration.launchValue {
            return scripted.environment
        }
        #endif
        return .live
    }
}

/// Live, on-device dictation for one screen (meal composer, correction
/// sheet, onboarding, weigh-in, coach). Shows words while Luke speaks and
/// hands back a `VoiceTake` of plain text — audio never leaves the phone and
/// is never written to disk.
///
/// Lifecycle: `start()` → `.listening` as soon as the mic is live (the
/// recognizer warms up in parallel; the unbounded capture stream keeps the
/// first words) → `stop()` returns the take. When a take ends by itself
/// (interruption, time or length limit, auto-stop, `finishInBackground()`),
/// it is parked and `phase` becomes `.ready`; collect it with `stop()` or
/// `collectReadyTake()`. Each take is handed out exactly once.
@MainActor
final class VoiceTranscriber: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// The one-time on-device model download is running; typing works.
        case preparingModel(progress: Double?)
        case starting
        case listening
        case finishing
        /// A take ended by itself and is waiting to be collected.
        case ready
        case unavailable(VoiceUnavailableReason)
        case failed(String)
    }

    enum Notice: Equatable {
        case keptWhatWasHeard
        case didNotCatchThat
        case reachedTimeLimit
        case reachedLengthLimit

        var message: String {
            switch self {
            case .keptWhatWasHeard: return VoiceCopy.keptWhatWasHeard
            case .didNotCatchThat: return VoiceCopy.didNotCatchThat
            case .reachedTimeLimit: return VoiceCopy.reachedTimeLimit
            case .reachedLengthLimit: return VoiceCopy.reachedLengthLimit
            }
        }
    }

    private enum FinishReason {
        case user
        case background
        case interrupted
        case timeLimit
        case lengthLimit
        case autoStop
        case engineEnded

        var notice: Notice? {
            switch self {
            case .interrupted, .engineEnded: return .keptWhatWasHeard
            case .timeLimit: return .reachedTimeLimit
            case .lengthLimit: return .reachedLengthLimit
            case .user, .background, .autoStop: return nil
            }
        }
    }

    /// The recognizer side of a take once it is attached to the microphone.
    private struct Pipeline {
        let engine: any SpeechEngine
        let pump: Task<Void, Never>
        let events: Task<Void, Never>
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript: LiveTranscript
    @Published private(set) var meterLevels: [CGFloat] = VoiceMeterPolicy.restingLevels
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var notice: Notice?
    @Published private(set) var activeEngine: SpeechEngineID?

    let profile: VoiceProfile
    /// Weigh-in style auto-stop: when this holds for
    /// `profile.autoStopStableInterval` with no new recognizer output, the
    /// take ends by itself.
    var autoStopCondition: ((LiveTranscript) -> Bool)?

    private let environment: VoiceEnvironment
    private var generation = 0
    private var capture: (any AudioCapturing)?
    private var engines: [any SpeechEngine] = []
    private var pipelineTask: Task<Pipeline?, Never>?
    private var pipeline: Pipeline?
    private var meterTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var parkedTake: VoiceTake?
    private var startedAt: Date?
    private var sawFirstResult = false
    private var assetSubscription: AnyCancellable?

    init(profile: VoiceProfile, environment: VoiceEnvironment? = nil) {
        self.profile = profile
        self.environment = environment ?? .current
        transcript = LiveTranscript(characterLimit: profile.maximumCharacters)
        self.environment.assets.prepare()
        phase = Self.idlePhase(for: self.environment.assets.snapshot)
        // Asset providers publish from the main actor.
        assetSubscription = self.environment.assets.snapshotUpdates
            .sink { [weak self] snapshot in
                MainActor.assumeIsolated { self?.assetsChanged(snapshot) }
            }
    }

    // MARK: Derived state

    var isStarting: Bool { phase == .starting }
    var isListening: Bool { phase == .listening }
    var isFinishing: Bool { phase == .finishing }
    /// Starting, listening, or finishing — a take is in flight.
    var isBusy: Bool {
        switch phase {
        case .starting, .listening, .finishing: return true
        default: return false
        }
    }
    var isPreparingModel: Bool {
        if case .preparingModel = phase { return true }
        return false
    }
    var remainingTime: TimeInterval { profile.remainingTime(after: elapsedTime) }

    var errorMessage: String? {
        switch phase {
        case .unavailable(.microphoneDenied): return profile.microphoneDeniedMessage
        case .unavailable(.speechDenied): return VoiceCopy.speechDenied
        case .unavailable(.unsupported): return VoiceCopy.unsupported
        case .failed(let message): return message
        default: return nil
        }
    }

    /// Whether the fix lives in Settings (permission denied).
    var needsSettings: Bool {
        phase == .unavailable(.microphoneDenied) || phase == .unavailable(.speechDenied)
    }

    /// Static, privacy-safe state name for CaptureDiagnostics.
    var controlState: String {
        switch phase {
        case .idle: return "idle"
        case .preparingModel: return "preparing"
        case .starting: return "starting"
        case .listening: return "recording"
        case .finishing: return "finishing"
        case .ready: return "ready"
        case .unavailable, .failed: return "error"
        }
    }

    // MARK: Start

    /// Starts a take. Returns false when it couldn't (permission, no
    /// recognizer, model still downloading, aborted, already running).
    @discardableResult
    func start() async -> Bool {
        guard !Task.isCancelled, !isBusy else {
            CaptureDiagnostics.record(.recorderStartRejected, state: controlState)
            return false
        }
        Perf.mark("mic.start.begin")
        generation += 1
        let token = generation
        resetTakeState()
        phase = .starting
        CaptureDiagnostics.record(.recorderStartAccepted, state: controlState)

        guard await environment.permissions.requestMicrophone() else {
            guard isCurrent(token) else { return false }
            phase = .unavailable(.microphoneDenied)
            CaptureDiagnostics.record(.microphonePermissionDenied, state: controlState)
            return false
        }
        guard isCurrent(token) else { return false }
        Perf.mark("mic.permission.ok")
        CaptureDiagnostics.record(.microphonePermissionGranted, state: controlState)

        let authorization = await environment.permissions.speechAuthorization(requestIfNeeded: true)
        guard isCurrent(token) else { return false }
        let snapshot = await environment.assets.resolvedSnapshot()
        guard isCurrent(token) else { return false }

        let engineID: SpeechEngineID
        switch SpeechEnginePolicy.select(snapshot, speechAuthorization: authorization) {
        case .engine(let id):
            engineID = id
        case .preparing(let progress):
            phase = .preparingModel(progress: progress)
            CaptureDiagnostics.record(.speechAssetStatus, state: "preparing")
            return false
        case .unavailable:
            phase = .unavailable(authorization == .denied ? .speechDenied : .unsupported)
            CaptureDiagnostics.record(.speechEngineUnavailable, state: controlState)
            return false
        }
        Perf.mark("speech.engine.selected")
        CaptureDiagnostics.record(.speechEngineSelected, state: engineID.diagnosticName)

        // The recognizer warms up while the microphone activates.
        let primary = environment.makeEngine(engineID)
        engines = [primary]
        let profile = self.profile
        let locale = Self.locale(for: engineID, in: snapshot)
        let vocabulary = engineID == .speechTranscriber ? [] : environment.vocabulary()
        let primaryStart = Task {
            try await primary.start(locale: locale, profile: profile, vocabulary: vocabulary)
        }

        let capture = environment.makeCapture()
        self.capture = capture
        let captureRun: AudioCaptureRun
        do {
            captureRun = try await capture.start { [weak self] event in
                self?.handleCaptureEvent(event, token: token)
            }
        } catch {
            capture.stop()
            primaryStart.cancel()
            guard isCurrent(token) else { return false }
            tearDownInFlight()
            Perf.mark("mic.start.fail")
            phase = .failed(Self.message(for: error))
            CaptureDiagnostics.record(.recorderStartFailed, state: controlState)
            return false
        }
        guard isCurrent(token) else {
            // Aborted or canceled while the microphone warmed up.
            capture.stop()
            primaryStart.cancel()
            Task { await primary.cancel() }
            return false
        }

        startedAt = Date()
        activeEngine = engineID
        phase = .listening
        startMeter(capture: capture, token: token)
        Perf.mark("mic.record.live")
        CaptureDiagnostics.record(.recorderStarted, state: controlState)

        let attach = Task { [weak self] () -> Pipeline? in
            await self?.attachRecognizer(
                primary: primary,
                primaryID: engineID,
                primaryStart: primaryStart,
                buffers: captureRun.buffers,
                snapshot: snapshot,
                authorization: authorization,
                token: token
            )
        }
        pipelineTask = attach
        // True once the recognizer is attached — even if the take is already
        // finishing because Luke tapped stop during the warm-up.
        return await attach.value != nil
    }

    /// Starts the recognizer (falling through to the next usable one when
    /// the chosen one won't start — a stale asset check, an unallocatable
    /// locale) and connects it to the microphone stream. Audio heard
    /// meanwhile is still waiting in that stream, even if the take is
    /// already finishing.
    private func attachRecognizer(
        primary: any SpeechEngine,
        primaryID: SpeechEngineID,
        primaryStart: Task<SpeechRun, Error>,
        buffers: AsyncStream<AVAudioPCMBuffer>,
        snapshot: SpeechAssetSnapshot,
        authorization: SpeechAuthorizationState,
        token: Int
    ) async -> Pipeline? {
        var engine = primary
        var run: SpeechRun?
        do {
            run = try await primaryStart.value
        } catch {
            CaptureDiagnostics.record(.speechEngineFailed, state: primaryID.diagnosticName)
            let fallbacks = SpeechEnginePolicy.candidates(snapshot, speechAuthorization: authorization)
                .filter { $0 != primaryID }
            for fallbackID in fallbacks where generation == token {
                engine = environment.makeEngine(fallbackID)
                engines.append(engine)
                do {
                    run = try await engine.start(
                        locale: Self.locale(for: fallbackID, in: snapshot),
                        profile: profile,
                        vocabulary: environment.vocabulary()
                    )
                    activeEngine = fallbackID
                    CaptureDiagnostics.record(.speechEngineSelected, state: fallbackID.diagnosticName)
                    break
                } catch {
                    CaptureDiagnostics.record(.speechEngineFailed, state: fallbackID.diagnosticName)
                }
            }
        }
        guard generation == token else {
            if run != nil { Task { [engine] in await engine.cancel() } }
            return nil
        }
        guard let run else {
            failAfterEngineError(authorization: authorization)
            return nil
        }

        let pump = Task.detached(priority: .userInitiated) { [engine] in
            for await buffer in buffers {
                engine.append(buffer)
            }
        }
        let events = Task { [weak self] in
            do {
                for try await event in run.events {
                    guard let self, self.generation == token else { return }
                    self.apply(event, token: token)
                }
            } catch {
                guard let self, self.generation == token, self.phase == .listening else { return }
                CaptureDiagnostics.record(.speechEngineFailed, state: self.controlState)
                if self.transcript.isEmpty {
                    // Nothing heard before the recognizer broke: say it
                    // failed rather than blaming the speaker.
                    self.failAfterEngineError(authorization: authorization)
                } else {
                    self.beginFinishing(reason: .engineEnded)
                }
                return
            }
            // The recognizer ended on its own while still listening (for
            // example a legacy recognizer's silence timeout).
            guard let self, self.generation == token, self.phase == .listening else { return }
            self.beginFinishing(reason: .engineEnded)
        }
        let attached = Pipeline(engine: engine, pump: pump, events: events)
        pipeline = attached
        return attached
    }

    // MARK: Stop / collect

    /// Ends the take and returns its text, waiting up to
    /// `finalizationTimeout` (default: the profile's) for the recognizer's
    /// final pass before keeping what it already heard. Also collects a
    /// parked `.ready` take. Returns nil for an empty take (with a
    /// "Didn't catch that" notice) or when another caller already collected
    /// it.
    @discardableResult
    func stop(finalizationTimeout: TimeInterval? = nil) async -> VoiceTake? {
        switch phase {
        case .starting:
            abortStarting()
            return nil
        case .listening:
            beginFinishing(reason: .user, timeout: finalizationTimeout)
        case .finishing, .ready:
            break
        default:
            return nil
        }
        if let finishTask { await finishTask.value }
        return collectReadyTake()
    }

    /// Ends the take without waiting: the microphone is released before this
    /// returns (so the camera or a picker can take the hardware) and the
    /// final text arrives as a parked take (`phase == .ready`).
    func finishInBackground() {
        switch phase {
        case .starting: abortStarting()
        case .listening: beginFinishing(reason: .background)
        default: break
        }
    }

    /// Hands out a parked take exactly once.
    func collectReadyTake() -> VoiceTake? {
        guard let take = parkedTake else { return nil }
        parkedTake = nil
        if phase == .ready { phase = idlePhase() }
        return take
    }

    /// Drops the take in flight (and any parked text) and releases the mic.
    func cancel() {
        let wasActive = phase != idlePhase()
        generation += 1
        tearDownInFlight()
        finishTask = nil
        resetTakeState()
        phase = idlePhase()
        if wasActive {
            CaptureDiagnostics.record(.recorderDiscarded, state: controlState)
        }
    }

    /// Cancels an in-flight microphone warm-up without touching a finished
    /// take, so a warm-up can't complete into live capture underneath the
    /// camera or a picker.
    func abortStarting() {
        guard phase == .starting else { return }
        CaptureDiagnostics.record(.recorderWarmupAborted, state: controlState)
        generation += 1
        tearDownInFlight()
        phase = idlePhase()
    }

    // MARK: Internals

    private func isCurrent(_ token: Int) -> Bool {
        generation == token && !Task.isCancelled
    }

    private func resetTakeState() {
        transcript = LiveTranscript(characterLimit: profile.maximumCharacters)
        meterLevels = VoiceMeterPolicy.restingLevels
        elapsedTime = 0
        notice = nil
        parkedTake = nil
        activeEngine = nil
        startedAt = nil
        sawFirstResult = false
    }

    private func apply(_ event: SpeechEvent, token: Int) {
        guard phase == .listening || phase == .finishing else { return }
        if !sawFirstResult {
            sawFirstResult = true
            Perf.mark("speech.first_volatile")
        }
        transcript.apply(event)
        guard phase == .listening else { return }
        if transcript.isAtLimit {
            beginFinishing(reason: .lengthLimit)
            return
        }
        scheduleAutoStopIfNeeded(token: token)
    }

    private func scheduleAutoStopIfNeeded(token: Int) {
        autoStopTask?.cancel()
        autoStopTask = nil
        guard let interval = profile.autoStopStableInterval,
              let autoStopCondition,
              autoStopCondition(transcript) else { return }
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard let self, !Task.isCancelled, self.generation == token,
                  self.phase == .listening,
                  self.autoStopCondition?(self.transcript) == true else { return }
            self.beginFinishing(reason: .autoStop)
        }
    }

    private func handleCaptureEvent(_ event: AudioCaptureEvent, token: Int) {
        guard generation == token else { return }
        switch phase {
        case .starting:
            abortStarting()
        case .listening:
            CaptureDiagnostics.record(.audioInterrupted, state: controlState)
            // After a media-server crash the recognizer is likely dead too;
            // don't wait long for a final pass that won't come.
            beginFinishing(
                reason: .interrupted,
                timeout: event == .mediaServicesReset ? 0.4 : nil
            )
        default:
            break
        }
    }

    private func beginFinishing(reason: FinishReason, timeout: TimeInterval? = nil) {
        guard phase == .listening, finishTask == nil else { return }
        let token = generation
        Perf.mark("speech.stop")
        phase = .finishing
        autoStopTask?.cancel()
        autoStopTask = nil
        stopMeter()
        let duration = startedAt
            .map { min(profile.maximumDuration, Date().timeIntervalSince($0)) } ?? elapsedTime
        elapsedTime = duration
        // Free the microphone right away; the recognizer finalizes from the
        // audio it already has (the capture stream ends after its backlog).
        capture?.stop()
        capture = nil
        CaptureDiagnostics.record(.recorderStopped, state: controlState)

        let attach = pipelineTask
        let limit = timeout ?? profile.finalizationTimeout
        finishTask = Task { [weak self] in
            let finalized = await VoiceTiming.race(timeout: limit) {
                guard let pipeline = await attach?.value else { return }
                await pipeline.pump.value
                do {
                    try await pipeline.engine.finish()
                    await pipeline.events.value
                } catch {
                    // A recognizer that can't finalize keeps what it heard.
                }
            }
            guard let self, self.generation == token else { return }
            if !finalized {
                CaptureDiagnostics.record(.speechFinalizationTimedOut, state: self.controlState)
            }
            // After a clean final pass the volatile tail is empty; after a
            // timeout, committed + volatile is the best text available.
            self.completeTake(reason: reason, text: self.transcript.displayText, duration: duration)
        }
    }

    private func completeTake(reason: FinishReason, text: String, duration: TimeInterval) {
        Perf.mark("speech.final")
        let engineID = activeEngine
        // Late recognizer events from this take must not touch the next one.
        generation += 1
        tearDownInFlight()
        finishTask = nil
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let engineID else {
            notice = .didNotCatchThat
            phase = idlePhase()
            CaptureDiagnostics.record(.speechTakeEmpty, state: controlState)
            return
        }
        notice = reason.notice
        parkedTake = VoiceTake(text: cleaned, engine: engineID, duration: duration)
        phase = .ready
    }

    private func failAfterEngineError(authorization: SpeechAuthorizationState) {
        CaptureDiagnostics.record(.speechEngineFailed, state: controlState)
        generation += 1
        tearDownInFlight()
        finishTask = nil
        resetTakeState()
        phase = authorization == .denied
            ? .unavailable(.speechDenied)
            : .failed(VoiceCopy.recognizerFailed)
    }

    /// Releases the microphone and every recognizer from the current take.
    private func tearDownInFlight() {
        stopMeter()
        autoStopTask?.cancel()
        autoStopTask = nil
        capture?.stop()
        capture = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        pipeline?.pump.cancel()
        pipeline?.events.cancel()
        pipeline = nil
        let engines = self.engines
        self.engines = []
        if !engines.isEmpty {
            Task {
                for engine in engines { await engine.cancel() }
            }
        }
    }

    private func startMeter(capture: any AudioCapturing, token: Int) {
        stopMeter()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: UInt64(VoiceMeterPolicy.tickInterval * 1_000_000_000)
                )
                guard let self, !Task.isCancelled, self.generation == token,
                      self.phase == .listening else { return }
                self.meterLevels = VoiceMeterPolicy.appending(
                    VoiceMeterPolicy.amplitude(decibels: capture.currentPowerDecibels),
                    to: self.meterLevels
                )
                if let startedAt = self.startedAt {
                    self.elapsedTime = min(
                        self.profile.maximumDuration,
                        Date().timeIntervalSince(startedAt)
                    )
                }
                if self.remainingTime <= 0 {
                    self.beginFinishing(reason: .timeLimit)
                    return
                }
            }
        }
    }

    private func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
    }

    private func assetsChanged(_ snapshot: SpeechAssetSnapshot) {
        switch phase {
        case .idle, .preparingModel:
            phase = Self.idlePhase(for: snapshot)
        default:
            break
        }
    }

    private func idlePhase() -> Phase {
        Self.idlePhase(for: environment.assets.snapshot)
    }

    private static func idlePhase(for snapshot: SpeechAssetSnapshot) -> Phase {
        if case .preparing(let progress) = SpeechEnginePolicy.idleAvailability(snapshot) {
            return .preparingModel(progress: progress)
        }
        return .idle
    }

    private static func locale(for engine: SpeechEngineID, in snapshot: SpeechAssetSnapshot) -> Locale {
        switch engine {
        case .speechTranscriber:
            return snapshot.transcriberLocale ?? SpeechAssetPreparer.fallbackLocale
        case .dictationTranscriber:
            return snapshot.dictationLocale ?? snapshot.transcriberLocale
                ?? SpeechAssetPreparer.fallbackLocale
        case .sfSpeechOnDevice:
            return Locale.current
        }
    }

    /// Only Shudo's own copy reaches the screen; raw OSStatus text never does.
    private static func message(for error: Error) -> String {
        error is AudioSessionController.StartTimedOut
            ? VoiceCopy.microphoneSlow
            : VoiceCopy.microphoneFailed
    }
}

/// Microphone first, then speech recognition (asked once; whether
/// SpeechAnalyzer strictly needs it is undocumented, so only the legacy
/// recognizer is gated on it).
@MainActor
final class LiveVoicePermissions: VoicePermissionProviding {
    static let shared = LiveVoicePermissions()

    func requestMicrophone() async -> Bool {
        await AudioSessionController.requestRecordPermission()
    }

    func speechAuthorization(requestIfNeeded: Bool) async -> SpeechAuthorizationState {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .notDetermined, requestIfNeeded {
            let resolved = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            return Self.map(resolved)
        }
        return Self.map(current)
    }

    private static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> SpeechAuthorizationState {
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }
}

/// Recent meal titles for the fallback recognizers' contextual strings.
@MainActor
final class VoiceVocabularyStore {
    static let shared = VoiceVocabularyStore()
    private(set) var recentTitles: [String] = []

    func learn(fromMealTitles titles: [String]) {
        let staples = Set(PersonalVocabulary.staples.map { $0.lowercased() })
        recentTitles = Array(
            PersonalVocabulary.terms(fromMealTitles: titles + recentTitles)
                .filter { !staples.contains($0.lowercased()) }
                .prefix(PersonalVocabulary.maximumTerms / 2)
        )
    }

    var terms: [String] {
        PersonalVocabulary.terms(fromMealTitles: recentTitles)
    }
}
