import Combine
import Foundation
import Speech

/// Where the recognizer assets stand, plus a way to wait for the first check.
@MainActor
protocol SpeechAssetProviding: AnyObject {
    var snapshot: SpeechAssetSnapshot { get }
    var snapshotUpdates: AnyPublisher<SpeechAssetSnapshot, Never> { get }
    /// Starts the one-time check (and model download if needed). Idempotent.
    func prepare()
    /// The snapshot after the launch check, waiting for it briefly if it is
    /// still running; never blocks a take for long.
    func resolvedSnapshot() async -> SpeechAssetSnapshot
}

/// Reserves the speech locale and makes sure the on-device model is
/// installed before Luke first taps the mic. Runs when the first voice
/// surface is created (Today, at launch) and on demand afterwards. Models
/// persist, are shared across apps, and update themselves.
@MainActor
final class SpeechAssetPreparer: ObservableObject, SpeechAssetProviding {
    static let shared = SpeechAssetPreparer()

    @Published private(set) var snapshot: SpeechAssetSnapshot = .checking

    var snapshotUpdates: AnyPublisher<SpeechAssetSnapshot, Never> {
        $snapshot.removeDuplicates().eraseToAnyPublisher()
    }

    static let fallbackLocale = Locale(identifier: "en_US")
    static let resolutionWait: TimeInterval = 2

    private var checkTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var progressObservation: NSKeyValueObservation?

    func prepare() {
        if checkTask == nil {
            checkTask = Task { [weak self] in await self?.check() }
            return
        }
        // A failed download (offline at launch) retries on the next prepare.
        if snapshot.transcriber == .needsDownload, downloadTask == nil,
           let locale = snapshot.transcriberLocale {
            startDownload(locale: locale)
        }
    }

    func resolvedSnapshot() async -> SpeechAssetSnapshot {
        prepare()
        guard snapshot.transcriber == .checking, let checkTask else { return snapshot }
        _ = await VoiceTiming.race(timeout: Self.resolutionWait) { await checkTask.value }
        return snapshot
    }

    private func check() async {
        var updated = SpeechAssetSnapshot.checking
        updated.supportsOnDeviceRecognizer =
            (SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer())?
                .supportsOnDeviceRecognition ?? false

        if SpeechTranscriber.isAvailable {
            let locale = await Self.transcriberLocale()
            updated.transcriberLocale = locale
            if let locale {
                await Self.reserve(locale)
                let module = SpeechTranscriber(locale: locale, preset: .transcription)
                updated.transcriber = Self.moduleStatus(
                    await AssetInventory.status(forModules: [module])
                )
            } else {
                updated.transcriber = .unsupported
            }
        } else {
            updated.transcriber = .unsupported
        }

        if let dictationLocale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) {
            updated.dictationLocale = dictationLocale
            let module = DictationTranscriber(locale: dictationLocale, preset: .longDictation)
            updated.dictation = Self.moduleStatus(
                await AssetInventory.status(forModules: [module])
            )
        } else {
            updated.dictation = .unsupported
        }

        snapshot = updated
        CaptureDiagnostics.record(.speechAssetStatus, state: updated.transcriber.diagnosticName)
        if updated.transcriber == .needsDownload, let locale = updated.transcriberLocale {
            startDownload(locale: locale)
        }
    }

    private func startDownload(locale: Locale) {
        guard downloadTask == nil else { return }
        snapshot.transcriber = .downloading(progress: nil)
        CaptureDiagnostics.record(.speechAssetStatus, state: "download_started")
        downloadTask = Task { [weak self] in
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    self?.observeProgress(request.progress)
                    try await request.downloadAndInstall()
                }
                guard let self else { return }
                self.progressObservation = nil
                self.snapshot.transcriber = Self.moduleStatus(
                    await AssetInventory.status(forModules: [module])
                )
                CaptureDiagnostics.record(
                    .speechAssetStatus,
                    state: self.snapshot.transcriber.diagnosticName
                )
            } catch {
                guard let self else { return }
                self.progressObservation = nil
                self.snapshot.transcriber = .needsDownload
                CaptureDiagnostics.record(.speechAssetStatus, state: "download_failed")
            }
            self?.downloadTask = nil
        }
    }

    private func observeProgress(_ progress: Progress) {
        progressObservation = progress.observe(\.fractionCompleted, options: [.initial, .new]) {
            [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor [weak self] in
                guard let self, case .downloading = self.snapshot.transcriber else { return }
                self.snapshot.transcriber = .downloading(progress: fraction)
            }
        }
    }

    private static func transcriberLocale() async -> Locale? {
        if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return equivalent
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: fallbackLocale)
    }

    /// Using a locale that isn't reserved logs "Cannot use modules with
    /// unallocated locales"; reserve once, within the system's cap.
    private static func reserve(_ locale: Locale) async {
        let reserved = await AssetInventory.reservedLocales
        guard !reserved.contains(where: { $0.identifier == locale.identifier }) else { return }
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    private static func moduleStatus(_ status: AssetInventory.Status) -> SpeechAssetSnapshot.ModuleStatus {
        switch status {
        case .installed: return .installed
        case .downloading: return .downloading(progress: nil)
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }
}

enum VoiceTiming {
    /// Runs `work` and returns true when it finishes within `timeout`, false
    /// when the timeout wins. Unstructured on purpose: a task group would
    /// wait for an uncancellable `work` before returning.
    @MainActor
    static func race(
        timeout: TimeInterval,
        _ work: @escaping @MainActor () async -> Void
    ) async -> Bool {
        let once = OnceFlag()
        return await withCheckedContinuation { continuation in
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                if once.claim() { continuation.resume(returning: false) }
            }
            Task { @MainActor in
                await work()
                if once.claim() {
                    timer.cancel()
                    continuation.resume(returning: true)
                }
            }
        }
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
