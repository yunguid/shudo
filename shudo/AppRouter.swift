import Foundation

@MainActor
final class AppRouter: ObservableObject {
    struct CaptureRequest: Identifiable, Equatable {
        let id = UUID()
        let autoStartRecording: Bool
    }

    /// A consumable request to open the coach thread (or its settings) —
    /// from a notification tap or `shudo://coach?message=<uuid>&day=<YYYY-MM-DD>`.
    /// Published until the Today tab consumes it, so cold launches work.
    struct CoachRequest: Identifiable, Equatable {
        enum Destination: Equatable {
            /// Open the thread on `localDay` (today when nil), scrolled to
            /// `messageId` when given.
            case thread(messageId: UUID?, localDay: String?)
            /// Coach settings (iOS "Shudo Notification Settings" link).
            case settings
        }

        let id = UUID()
        let destination: Destination
    }

    static let shared = AppRouter()
    @Published private(set) var captureRequest: CaptureRequest?
    @Published private(set) var authCallbackURL: URL?
    @Published private(set) var coachRequest: CoachRequest?

    nonisolated static let coachSettingsURL = URL(string: "shudo://coach/settings")!

    private init() { }

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "shudo" else { return }
        let destination = (url.host ?? url.pathComponents.dropFirst().first ?? "").lowercased()
        if destination == "capture" {
            captureRequest = CaptureRequest(autoStartRecording: true)
        } else if destination == "auth" && url.path.lowercased() == "/callback" {
            authCallbackURL = url
        } else if let coach = Self.coachDestination(for: url) {
            coachRequest = CoachRequest(destination: coach)
        }
    }

    func consume(_ request: CaptureRequest) {
        guard captureRequest?.id == request.id else { return }
        captureRequest = nil
    }

    func consumeAuthCallback(_ url: URL) {
        guard authCallbackURL == url else { return }
        authCallbackURL = nil
    }

    func consume(_ request: CoachRequest) {
        guard coachRequest?.id == request.id else { return }
        coachRequest = nil
    }

    // MARK: Coach links

    /// `shudo://coach?message=<uuid>&day=<YYYY-MM-DD>`
    nonisolated static func coachDeepLink(messageId: UUID, localDay: String?) -> URL {
        var components = URLComponents()
        components.scheme = "shudo"
        components.host = "coach"
        var items = [URLQueryItem(name: "message", value: messageId.uuidString.lowercased())]
        if let localDay, CoachLocalDay.isValid(localDay) {
            items.append(URLQueryItem(name: "day", value: localDay))
        }
        components.queryItems = items
        return components.url ?? URL(string: "shudo://coach")!
    }

    /// Parses a coach link; nil when the URL isn't one. Invalid `message` or
    /// `day` values are dropped rather than failing the whole link.
    nonisolated static func coachDestination(for url: URL) -> CoachRequest.Destination? {
        guard url.scheme?.lowercased() == "shudo" else { return nil }
        var segments = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
        if let host = url.host?.lowercased(), !host.isEmpty {
            segments.insert(host, at: 0)
        }
        guard segments.first == "coach" else { return nil }
        if segments.dropFirst().first == "settings" { return .settings }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let messageId = value("message").flatMap(UUID.init(uuidString:))
        let localDay = value("day").flatMap { CoachLocalDay.isValid($0) ? $0 : nil }
        return .thread(messageId: messageId, localDay: localDay)
    }
}
