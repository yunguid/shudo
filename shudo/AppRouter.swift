import Foundation

@MainActor
final class AppRouter: ObservableObject {
    struct CaptureRequest: Identifiable, Equatable {
        let id = UUID()
        let autoStartRecording: Bool
    }

    static let shared = AppRouter()
    @Published private(set) var captureRequest: CaptureRequest?
    @Published private(set) var authCallbackURL: URL?

    private init() { }

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "shudo" else { return }
        let destination = (url.host ?? url.pathComponents.dropFirst().first ?? "").lowercased()
        if destination == "capture" {
            captureRequest = CaptureRequest(autoStartRecording: true)
        } else if destination == "auth" && url.path.lowercased() == "/callback" {
            authCallbackURL = url
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
}
