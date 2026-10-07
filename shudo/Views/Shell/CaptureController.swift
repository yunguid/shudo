import Combine
import Foundation

/// What a capture-bar message is about. Sent to coach_chat as
/// `context_hint` so the coach knows to treat it as a workout log, a
/// weight/check-in note, or a bio update.
enum CaptureContext: String, CaseIterable, Equatable, Sendable {
    /// The coach chat (default).
    case today
    /// Workout logging (Train tab).
    case train
    /// Weight and check-in notes (Body tab).
    case body
    /// Updating what Shudo knows about Luke (from the Bio screen).
    case bio

    /// `context_hint` on coach_chat (nil for the plain chat).
    var contextHint: CoachContextHint? {
        switch self {
        case .today: return nil
        case .train: return .train
        case .body: return .body
        case .bio: return .bio
        }
    }

    /// The `purpose` sent with the recording to the transcribe function.
    var transcriptionPurpose: TranscriptionPurpose {
        self == .train ? .workout : .coach
    }

    /// Where the bar lives while this context is active.
    var tab: AppTab {
        switch self {
        case .today, .bio: return .today
        case .train: return .train
        case .body: return .body
        }
    }

    /// The context a tab gives the bar by default.
    static func forTab(_ tab: AppTab) -> CaptureContext {
        switch tab {
        case .today: return .today
        case .train: return .train
        case .body: return .body
        }
    }

    /// The idle field's hint.
    var placeholder: String {
        switch self {
        case .today: return "Tell Shudo anything…"
        case .train: return "Log a workout…"
        case .body: return "Weight, check-in notes…"
        case .bio: return "Update what Shudo knows…"
        }
    }

    /// The hint when the bar is minimized inline with the tab bar.
    var compactPlaceholder: String {
        switch self {
        case .today: return "Tell Shudo…"
        case .train: return "Log a workout…"
        case .body: return "Weight, notes…"
        case .bio: return "Update bio…"
        }
    }
}

/// The one way into voice and text capture. Every screen that wants Luke to
/// talk or type to Shudo calls this instead of owning its own mic UI; the
/// shell's capture bar (bottom-left mic) does the recording and sending.
///
///     CaptureController.shared.startRecording(context: .bio)
///     CaptureController.shared.focusText(context: .train)
///
/// The shell dismisses whatever sheet is up (Settings for `.bio`), switches
/// to the context's tab, then starts the bar recording or opens its
/// keyboard composer. Sends carry `context.contextHint`.
@MainActor
final class CaptureController: ObservableObject {
    struct Request: Identifiable, Equatable {
        enum Action: Equatable {
            case record
            case type
        }

        let id = UUID()
        let action: Action
        let context: CaptureContext
    }

    static let shared = CaptureController()

    /// The selected tab's context (kept current by the shell).
    @Published private(set) var tabContext: CaptureContext = .today
    /// A context a screen asked for that its tab doesn't imply (`.bio`);
    /// cleared after the next send or discard, or on a tab change.
    @Published private(set) var contextOverride: CaptureContext?
    /// The shell's next job; consumed once handled.
    @Published private(set) var request: Request?

    /// What the bar is capturing for right now.
    var context: CaptureContext { contextOverride ?? tabContext }

    init() {}

    /// Start the bar recording for `context` (stop/send is the same
    /// bottom-left button). Dismisses sheets and switches tabs as needed.
    func startRecording(context: CaptureContext) {
        route(.record, context: context)
    }

    /// Open the bar's keyboard composer for `context`.
    func focusText(context: CaptureContext) {
        route(.type, context: context)
    }

    // MARK: Shell side

    func setTab(_ tab: AppTab) {
        tabContext = CaptureContext.forTab(tab)
        if let contextOverride, contextOverride.tab != tab {
            self.contextOverride = nil
        }
    }

    func consume(_ request: Request) {
        guard self.request?.id == request.id else { return }
        self.request = nil
    }

    /// A send went out or a recording was discarded: back to the tab's
    /// context.
    func captureEnded() {
        contextOverride = nil
    }

    private func route(_ action: Request.Action, context: CaptureContext) {
        contextOverride = context == CaptureContext.forTab(context.tab) ? nil : context
        tabContext = CaptureContext.forTab(context.tab)
        request = Request(action: action, context: context)
    }
}
