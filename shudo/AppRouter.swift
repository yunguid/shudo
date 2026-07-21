import Foundation

@MainActor
final class AppRouter: ObservableObject {
    struct CaptureRequest: Identifiable, Equatable {
        let id = UUID()
        let autoStartRecording: Bool
    }

    static let shared = AppRouter()
    @Published private(set) var captureRequest: CaptureRequest?

    private init() { }

    func handle(url: URL) {
        guard url.scheme?.lowercased() == "shudo" else { return }
        let destination = (url.host ?? url.pathComponents.dropFirst().first ?? "").lowercased()
        guard destination == "capture" else { return }
        captureRequest = CaptureRequest(autoStartRecording: true)
    }

    func consume(_ request: CaptureRequest) {
        guard captureRequest?.id == request.id else { return }
        captureRequest = nil
    }
}
