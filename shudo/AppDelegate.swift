import UIKit
import UserNotifications

/// UIKit entry points SwiftUI doesn't cover: the notification-center
/// delegate must be installed before launch finishes so lock-screen actions
/// that launch the app in the background are delivered (SPEC §5.4).
final class ShudoAppDelegate: NSObject, UIApplicationDelegate {
    private let notificationDelegate = CoachNotificationDelegate()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = notificationDelegate
        CoachNotificationCategories.register(on: center)
        return true
    }
}

// MARK: - Notification delegate

/// A notification response flattened into Sendable values.
struct CoachNotificationAction: Equatable, Sendable {
    var actionIdentifier: String
    var notificationIdentifier: String
    var payload: CoachNotificationPayload?
    var replyText: String?

    var messageId: UUID? {
        payload?.messageId ?? CoachNotificationIdentifiers.messageId(fromIdentifier: notificationIdentifier)
    }

    var isCoachNotification: Bool {
        notificationIdentifier.hasPrefix(CoachNotificationIdentifiers.ownedPrefix) || payload != nil
    }
}

/// Pure routing decisions for notification actions (unit-tested).
enum CoachNotificationRouting {
    enum Response: Equatable {
        case open(URL)
        case reply(text: String)
        case acknowledge(messageId: UUID)
        case snooze(messageId: UUID)
        case directions(query: String)
        case ignore
    }

    static func route(_ action: CoachNotificationAction) -> Response {
        guard action.isCoachNotification else { return .ignore }
        switch action.actionIdentifier {
        case UNNotificationDefaultActionIdentifier:
            if let link = action.payload?.deepLink { return .open(link) }
            if let id = action.messageId {
                return .open(AppRouter.coachDeepLink(messageId: id, localDay: action.payload?.localDay))
            }
            return .ignore
        case CoachNotificationIdentifiers.replyAction:
            let text = action.replyText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return .ignore }
            return .reply(text: String(text.prefix(CoachSendRequest.maximumTextLength)))
        case CoachNotificationIdentifiers.ackAction:
            return action.messageId.map(Response.acknowledge(messageId:)) ?? .ignore
        case CoachNotificationIdentifiers.snoozeAction:
            return action.messageId.map(Response.snooze(messageId:)) ?? .ignore
        case CoachNotificationIdentifiers.directionsAction:
            if let query = action.payload?.mapsQuery, !query.isEmpty { return .directions(query: query) }
            if let link = action.payload?.deepLink { return .open(link) }
            return .ignore
        default:
            return .ignore
        }
    }

    /// No banner while the thread is on screen; the message animates in.
    static func presentationOptions(isCoach: Bool, threadVisible: Bool) -> UNNotificationPresentationOptions {
        if isCoach && threadVisible { return [] }
        return [.banner, .list, .sound]
    }

    static func directionsURL(query: String) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "daddr", value: query),
            URLQueryItem(name: "dirflg", value: "w"),
        ]
        return components?.url
    }
}

final class CoachNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let identifier = notification.request.identifier
        let isCoach = identifier.hasPrefix(CoachNotificationIdentifiers.ownedPrefix)
        let localDay = CoachNotificationPayload(userInfo: notification.request.content.userInfo)?.localDay
        Task { @MainActor in
            let options = CoachNotificationRouting.presentationOptions(
                isCoach: isCoach,
                threadVisible: CoachPresence.shared.isThreadVisible
            )
            if isCoach {
                NotificationCenter.default.post(
                    name: .coachThreadDidChange,
                    object: nil,
                    userInfo: localDay.map { ["local_days": [$0]] }
                )
            }
            completionHandler(options)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let action = CoachNotificationAction(
            actionIdentifier: response.actionIdentifier,
            notificationIdentifier: response.notification.request.identifier,
            payload: CoachNotificationPayload(
                userInfo: content.userInfo,
                body: content.body,
                categoryIdentifier: content.categoryIdentifier
            ),
            replyText: (response as? UNTextInputNotificationResponse)?.userText
        )
        Task { @MainActor in
            await CoachNotificationResponder.shared.handle(action)
            completionHandler()
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        openSettingsFor notification: UNNotification?
    ) {
        Task { @MainActor in
            AppRouter.shared.handle(url: AppRouter.coachSettingsURL)
        }
    }
}

// MARK: - Responder

@MainActor
final class CoachNotificationResponder {
    static let shared = CoachNotificationResponder()

    private let sync: CoachSync
    private let scheduler: CoachNotificationScheduler

    init(sync: CoachSync = .shared, scheduler: CoachNotificationScheduler = .live) {
        self.sync = sync
        self.scheduler = scheduler
    }

    func handle(_ action: CoachNotificationAction) async {
        switch CoachNotificationRouting.route(action) {
        case .open(let url):
            AppRouter.shared.handle(url: url)
        case .reply(let text):
            await reply(text, to: action.messageId)
        case .acknowledge(let messageId):
            await sync.markRead([messageId])
        case .snooze(let messageId):
            guard let payload = action.payload else { return }
            let fireAt = CoachNotificationPolicy.snoozeFireDate(
                now: Date(),
                settings: CoachSettingsMirror().load(),
                timeZone: .autoupdatingCurrent
            )
            await scheduler.snooze(payload, messageId: messageId, fireAt: fireAt)
        case .directions(let query):
            if let url = CoachNotificationRouting.directionsURL(query: query) {
                await UIApplication.shared.open(url)
            }
        case .ignore:
            break
        }
    }

    /// Lock-screen reply: runs `coach_chat` (input_mode notification_reply)
    /// inside a background task and posts Shudo's answer as a notification
    /// if it arrives in time; otherwise it waits in the thread.
    private func reply(_ text: String, to messageId: UUID?) async {
        let background = UIKitCoachBackgroundTasks.shared
        let token = background.begin("coach-reply")
        defer { background.end(token) }
        let remaining = UIApplication.shared.backgroundTimeRemaining
        let budget = min(25, max(5, remaining - 4))
        let now = Date()
        let timeZone = TimeZone.autoupdatingCurrent
        let request = CoachSendRequest(
            text: text,
            inputMode: .notificationReply,
            localDay: CoachLocalDay.string(for: now, timeZone: timeZone),
            timezone: timeZone.identifier
        )
        await sync.sendNotificationReply(request, inReplyTo: messageId, timeout: budget)
    }
}

// MARK: - Background task wrapper

@MainActor
final class UIKitCoachBackgroundTasks: CoachBackgroundTasking {
    static let shared = UIKitCoachBackgroundTasks()

    private var active: [Int: UIBackgroundTaskIdentifier] = [:]
    private var nextToken = 0

    func begin(_ name: String) -> Int? {
        nextToken += 1
        let token = nextToken
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end(token) }
        }
        guard identifier != .invalid else { return nil }
        active[token] = identifier
        return token
    }

    func end(_ token: Int?) {
        guard let token, let identifier = active.removeValue(forKey: token) else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
