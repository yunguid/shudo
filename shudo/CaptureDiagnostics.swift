import Foundation
import os

/// A non-sensitive identity for the exact source revision in an installed app.
/// The install script overrides `SHUDO_BUILD_REVISION` with the committed SHA;
/// ordinary Xcode builds intentionally identify themselves as local builds.
struct BuildIdentity: Equatable {
    static let revisionInfoKey = "ShudoBuildRevision"
    static let current = BuildIdentity(infoDictionary: Bundle.main.infoDictionary ?? [:])

    let version: String
    let build: String
    let revision: String

    init(infoDictionary: [String: Any]) {
        version = infoDictionary["CFBundleShortVersionString"] as? String ?? "unknown"
        build = infoDictionary["CFBundleVersion"] as? String ?? "unknown"
        let configuredRevision = infoDictionary[Self.revisionInfoKey] as? String
        revision = Self.normalizedRevision(configuredRevision)
    }

    var displayText: String {
        "Shudo \(version) (\(build)) · \(revision)"
    }

    var diagnosticText: String {
        "\(version)|\(build)|\(revision)"
    }

    static func normalizedRevision(_ value: String?) -> String {
        guard let value else { return "local" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return "local" }
        return String(trimmed.prefix(12))
    }
}

/// Privacy-safe, on-device capture diagnostics. Events contain only static
/// state names and the public source revision: never meal text, media names,
/// audio, image contents, permission identifiers, or audio-route names.
/// The bounded trace lives in Caches so device verification can read this one
/// file without inspecting the user's app data or photo library.
enum CaptureDiagnostics {
    enum Event: String {
        case appLaunched = "app.launched"
        case appBecameActive = "app.active"
        case appBecameInactive = "app.inactive"
        case appEnteredBackground = "app.background"
        case photoPickerPresented = "photo_picker.presented"
        case photoPickerDismissed = "photo_picker.dismissed"
        case photosPrepared = "photo_picker.photos_prepared"
        case composerPresented = "composer.presented"
        case composerDismissed = "composer.dismissed"
        case microphoneTapped = "mic.control.tapped"
        case microphoneTapAcceptedStart = "mic.control.accepted_start"
        case microphoneTapAcceptedStop = "mic.control.accepted_stop"
        case microphoneTapRejectedStarting = "mic.control.rejected_starting"
        case recorderStartAccepted = "recorder.start.accepted"
        case recorderStartRejected = "recorder.start.rejected"
        case microphonePermissionGranted = "recorder.permission.granted"
        case microphonePermissionDenied = "recorder.permission.denied"
        case recorderAttempt = "recorder.session.attempt"
        case recorderStarted = "recorder.started"
        case recorderStartFailed = "recorder.start.failed"
        case recorderStopped = "recorder.stopped"
        case recorderDiscarded = "recorder.discarded"
        case recorderWarmupAborted = "recorder.warmup.aborted"
        case audioInterrupted = "recorder.interrupted"
        case audioRouteChanged = "recorder.route_changed"
        case mediaServicesReset = "recorder.media_services_reset"
    }

    static let fileName = "shudo-capture-diagnostics.txt"

    private static let logger = Logger(subsystem: "luke.shudo", category: "capture")
    private static let queue = DispatchQueue(label: "shudo.capture-diagnostics", qos: .utility)
    private nonisolated(unsafe) static var lines: [String] = []

    static func beginSession() {
        queue.async {
            lines = []
            append(.appLaunched, state: "idle")
        }
    }

    static func record(_ event: Event, state: String) {
        logger.info("\(event.rawValue, privacy: .public) state=\(state, privacy: .public)")
        queue.async { append(event, state: state) }
    }

    static func flush() {
        queue.sync {}
    }

    static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName)
    }

    private static func append(_ event: Event, state: String) {
        let sequence = lines.count + 1
        lines.append(
            "\(sequence)|\(BuildIdentity.current.diagnosticText)|\(event.rawValue)|\(state)"
        )
        if lines.count > 200 {
            lines.removeFirst(lines.count - 200)
        }
        guard let fileURL else { return }
        let content = lines.joined(separator: "\n") + "\n"
        try? Data(content.utf8).write(to: fileURL, options: .atomic)
    }
}
