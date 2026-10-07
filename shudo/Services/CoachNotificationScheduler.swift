import CryptoKit
import Foundation
import UIKit
import UserNotifications

// Local notifications for server-written coach messages (SPEC §5.4). The
// server is the source of truth; the app mirrors its future `scheduled`
// rows into pending `UNNotificationRequest`s with a diff reconcile, never a
// remove-all, so unchanged requests are left alone.

// MARK: - Identifiers

enum CoachNotificationIdentifiers {
    static let messagePrefix = "shudo.coach.msg."
    static let snoozePrefix = "shudo.coach.snooze."
    static let ownedPrefix = "shudo.coach."
    static let threadIdentifier = "shudo.coach"
    static let title = "Shudo"

    static let textCategory = "COACH_TEXT"
    static let snackCategory = "COACH_SNACK"

    static let replyAction = "coach.reply"
    static let ackAction = "coach.ack"
    static let snoozeAction = "coach.snooze"
    static let directionsAction = "coach.directions"

    static func message(_ id: UUID) -> String { messagePrefix + id.uuidString.lowercased() }
    static func snooze(_ id: UUID) -> String { snoozePrefix + id.uuidString.lowercased() }

    static func messageId(fromIdentifier identifier: String) -> UUID? {
        for prefix in [messagePrefix, snoozePrefix] where identifier.hasPrefix(prefix) {
            return UUID(uuidString: String(identifier.dropFirst(prefix.count)))
        }
        return nil
    }
}

// MARK: - Plan model

/// The minimal persisted view of a future coach row (kept by `CoachSync` so
/// a reconcile can see every upcoming message, not just the last delta).
struct CoachScheduledRow: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var kind: String
    var localDay: String
    var deliverAt: Date
    var status: CoachMessageStatus
    var notify: Bool
    var text: String
    var readAt: Date?
    var mapsQuery: String?

    init(
        id: UUID,
        kind: String,
        localDay: String,
        deliverAt: Date,
        status: CoachMessageStatus,
        notify: Bool,
        text: String,
        readAt: Date? = nil,
        mapsQuery: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.localDay = localDay
        self.deliverAt = deliverAt
        self.status = status
        self.notify = notify
        self.text = text
        self.readAt = readAt
        self.mapsQuery = mapsQuery
    }

    init(message: CoachMessage) {
        var mapsQuery: String?
        if case .snackRec(let card) = message.payload { mapsQuery = card.options.first?.mapsQuery }
        self.init(
            id: message.id,
            kind: message.kind,
            localDay: message.localDay,
            deliverAt: message.deliverAt,
            status: message.status,
            notify: message.notify,
            text: message.notificationText,
            readAt: message.readAt,
            mapsQuery: mapsQuery
        )
    }
}

struct PlannedCoachNotification: Equatable, Sendable {
    enum Interruption: String, Equatable, Sendable { case passive, active }

    let messageId: UUID
    let identifier: String
    /// `nil` delivers immediately (lock-screen replies).
    let fireAt: Date?
    let title: String
    let body: String
    let badge: Int?
    let categoryIdentifier: String
    let kind: String
    let localDay: String
    let mapsQuery: String?
    let interruption: Interruption
    let relevance: Double
    let contentHash: String

    var deepLink: URL { AppRouter.coachDeepLink(messageId: messageId, localDay: localDay) }
}

struct CoachPendingRequest: Equatable, Sendable {
    let identifier: String
    let contentHash: String?
}

struct CoachNotificationDiff: Equatable, Sendable {
    /// New or changed requests (an add with an existing identifier replaces it).
    var toAdd: [PlannedCoachNotification]
    /// Pending coach requests no longer in the plan.
    var toRemove: [String]

    var isEmpty: Bool { toAdd.isEmpty && toRemove.isEmpty }
}

/// What the notification payload carries in `userInfo["shudo"]`.
struct CoachNotificationPayload: Equatable, Sendable {
    var messageId: UUID?
    var kind: String?
    var localDay: String?
    var deepLink: URL?
    var contentHash: String?
    var mapsQuery: String?
    var body: String
    var categoryIdentifier: String

    init(
        messageId: UUID?,
        kind: String?,
        localDay: String?,
        deepLink: URL?,
        contentHash: String?,
        mapsQuery: String?,
        body: String,
        categoryIdentifier: String
    ) {
        self.messageId = messageId
        self.kind = kind
        self.localDay = localDay
        self.deepLink = deepLink
        self.contentHash = contentHash
        self.mapsQuery = mapsQuery
        self.body = body
        self.categoryIdentifier = categoryIdentifier
    }

    init?(userInfo: [AnyHashable: Any], body: String = "", categoryIdentifier: String = "") {
        guard let info = userInfo["shudo"] as? [String: Any] else { return nil }
        messageId = (info["message_id"] as? String).flatMap(UUID.init(uuidString:))
        kind = info["kind"] as? String
        localDay = info["local_day"] as? String
        deepLink = (info["deep_link"] as? String).flatMap(URL.init(string:))
        contentHash = info["content_hash"] as? String
        mapsQuery = info["maps_query"] as? String
        self.body = body
        self.categoryIdentifier = categoryIdentifier
    }

    static func userInfo(for planned: PlannedCoachNotification) -> [String: Any] {
        var info: [String: Any] = [
            "v": 1,
            "message_id": planned.messageId.uuidString.lowercased(),
            "kind": planned.kind,
            "thread": "coach",
            "local_day": planned.localDay,
            "deep_link": planned.deepLink.absoluteString,
            "content_hash": planned.contentHash,
        ]
        if let mapsQuery = planned.mapsQuery { info["maps_query"] = mapsQuery }
        return ["shudo": info]
    }
}

// MARK: - Pure policy

enum CoachNotificationPolicy {
    /// Apple allows 64 pending requests per app; the coach takes at most 40
    /// (the rest: weigh-in repeat, snoozes, headroom).
    static let maximumPendingMessages = 40
    /// Rows due sooner than this are treated as past: a calendar trigger in
    /// the past never fires, and the thread shows them anyway.
    static let minimumLeadTime: TimeInterval = 5
    static let cancelOnLogWindow: TimeInterval = 60 * 60

    static func plan(
        rows: [CoachScheduledRow],
        now: Date,
        unreadCount: Int,
        suppressed: Set<UUID> = []
    ) -> [PlannedCoachNotification] {
        let candidates = rows
            .filter { row in
                row.status == .scheduled
                    && row.notify
                    && row.readAt == nil
                    && row.deliverAt > now.addingTimeInterval(minimumLeadTime)
                    && !suppressed.contains(row.id)
                    && !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { ($0.deliverAt, $0.id.uuidString) < ($1.deliverAt, $1.id.uuidString) }
            .prefix(maximumPendingMessages)
        return candidates.enumerated().map { index, row in
            planned(row: row, fireAt: row.deliverAt, badge: max(0, unreadCount) + index + 1)
        }
    }

    static func planned(row: CoachScheduledRow, fireAt: Date?, badge: Int?) -> PlannedCoachNotification {
        let category = row.kind == CoachMessageKind.snackRec.rawValue
            ? CoachNotificationIdentifiers.snackCategory
            : CoachNotificationIdentifiers.textCategory
        let body = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlannedCoachNotification(
            messageId: row.id,
            identifier: CoachNotificationIdentifiers.message(row.id),
            fireAt: fireAt,
            title: CoachNotificationIdentifiers.title,
            body: body,
            badge: badge,
            categoryIdentifier: category,
            kind: row.kind,
            localDay: row.localDay,
            mapsQuery: row.mapsQuery,
            interruption: interruption(for: row.kind),
            relevance: relevance(for: row.kind),
            contentHash: contentHash(body: body, fireAt: fireAt, badge: badge, category: category)
        )
    }

    static func interruption(for kind: String) -> PlannedCoachNotification.Interruption {
        switch CoachMessageKind(rawValue: kind) {
        case .mealAck?, .workoutAck?, .weighInAck?: return .passive
        default: return .active
        }
    }

    static func relevance(for kind: String) -> Double {
        switch CoachMessageKind(rawValue: kind) {
        case .snackRec?: return 0.9
        case .plan?, .checkpoint?, .goalChange?, .trainingPlan?: return 0.7
        case .recap?, .photoFeedback?: return 0.5
        default: return 0.3
        }
    }

    /// Deterministic across launches (unlike `hashValue`).
    static func contentHash(body: String, fireAt: Date?, badge: Int?, category: String) -> String {
        let fire = fireAt.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "now"
        let input = "v1|\(category)|\(fire)|\(badge.map(String.init) ?? "-")|\(body)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func diff(
        plan: [PlannedCoachNotification],
        pending: [CoachPendingRequest]
    ) -> CoachNotificationDiff {
        let owned = pending.filter { $0.identifier.hasPrefix(CoachNotificationIdentifiers.messagePrefix) }
        let pendingHashes = Dictionary(
            owned.map { ($0.identifier, $0.contentHash ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        let plannedIds = Set(plan.map(\.identifier))
        let toRemove = pendingHashes.keys.filter { !plannedIds.contains($0) }.sorted()
        let toAdd = plan.filter { pendingHashes[$0.identifier] != $0.contentHash }
        return CoachNotificationDiff(toAdd: toAdd, toRemove: toRemove)
    }

    /// Future rows that become stale the moment Luke logs something.
    static func idsToCancelOnLog(
        rows: [CoachScheduledRow],
        now: Date,
        window: TimeInterval = cancelOnLogWindow
    ) -> [UUID] {
        rows
            .filter { $0.status == .scheduled && $0.notify && $0.deliverAt > now
                && $0.deliverAt <= now.addingTimeInterval(window) }
            .sorted { $0.deliverAt < $1.deliverAt }
            .map(\.id)
    }

    /// Folds a batch of changed server rows into the persisted upcoming set.
    static func merge(
        rows: [CoachScheduledRow],
        changes: [CoachMessage],
        now: Date
    ) -> [CoachScheduledRow] {
        var byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for change in changes {
            if change.role == .coach, change.status == .scheduled, change.notify,
               change.readAt == nil, change.deliverAt > now {
                byId[change.id] = CoachScheduledRow(message: change)
            } else {
                byId[change.id] = nil
            }
        }
        return byId.values
            .filter { $0.deliverAt > now }
            .sorted { ($0.deliverAt, $0.id.uuidString) < ($1.deliverAt, $1.id.uuidString) }
    }

    /// Snooze lands one hour out, pushed past quiet hours if it would fall
    /// inside them.
    static func snoozeFireDate(
        now: Date,
        interval: TimeInterval = 3600,
        settings: CoachSettings?,
        timeZone: TimeZone
    ) -> Date {
        let candidate = now.addingTimeInterval(interval)
        guard let settings, settings.isQuietHour(candidate, timeZone: timeZone) else { return candidate }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard var end = calendar.date(
            bySettingHour: settings.quietHoursEnd.hour,
            minute: settings.quietHoursEnd.minute,
            second: 0,
            of: candidate
        ) else { return candidate }
        if end <= candidate, let next = calendar.date(byAdding: .day, value: 1, to: end) { end = next }
        return end
    }

    /// Absolute calendar components (with zone) for a fire date.
    static func triggerComponents(for date: Date, timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        components.timeZone = timeZone
        return components
    }
}

// MARK: - Notification center seam

protocol CoachNotificationCenter: Sendable {
    func pendingCoachRequests() async -> [CoachPendingRequest]
    func add(_ notification: PlannedCoachNotification) async
    func addSnooze(of payload: CoachNotificationPayload, messageId: UUID, fireAt: Date) async
    func removePending(identifiers: [String]) async
    func removeDelivered(identifiers: [String]) async
    func setBadgeCount(_ count: Int) async
    func authorizationStatus() async -> CoachSyncRequest.NotificationStatus
}

struct LiveCoachNotificationCenter: CoachNotificationCenter {
    func pendingCoachRequests() async -> [CoachPendingRequest] {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.compactMap { request in
            guard request.identifier.hasPrefix(CoachNotificationIdentifiers.ownedPrefix) else { return nil }
            let payload = CoachNotificationPayload(userInfo: request.content.userInfo)
            return CoachPendingRequest(identifier: request.identifier, contentHash: payload?.contentHash)
        }
    }

    func add(_ notification: PlannedCoachNotification) async {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = CoachNotificationIdentifiers.threadIdentifier
        content.categoryIdentifier = notification.categoryIdentifier
        content.userInfo = CoachNotificationPayload.userInfo(for: notification)
        content.interruptionLevel = notification.interruption == .passive ? .passive : .active
        content.relevanceScore = notification.relevance
        if let badge = notification.badge { content.badge = NSNumber(value: badge) }
        content.targetContentIdentifier = notification.messageId.uuidString.lowercased()

        let trigger: UNNotificationTrigger? = notification.fireAt.map {
            UNCalendarNotificationTrigger(
                dateMatching: CoachNotificationPolicy.triggerComponents(
                    for: $0,
                    timeZone: .autoupdatingCurrent
                ),
                repeats: false
            )
        }
        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: trigger
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func addSnooze(of payload: CoachNotificationPayload, messageId: UUID, fireAt: Date) async {
        let content = UNMutableNotificationContent()
        content.title = CoachNotificationIdentifiers.title
        content.body = payload.body
        content.sound = .default
        content.threadIdentifier = CoachNotificationIdentifiers.threadIdentifier
        content.categoryIdentifier = payload.categoryIdentifier.isEmpty
            ? CoachNotificationIdentifiers.textCategory : payload.categoryIdentifier
        var info: [String: Any] = [
            "v": 1,
            "message_id": messageId.uuidString.lowercased(),
            "thread": "coach",
        ]
        if let kind = payload.kind { info["kind"] = kind }
        if let localDay = payload.localDay { info["local_day"] = localDay }
        if let link = payload.deepLink { info["deep_link"] = link.absoluteString }
        if let mapsQuery = payload.mapsQuery { info["maps_query"] = mapsQuery }
        content.userInfo = ["shudo": info]
        let interval = max(1, fireAt.timeIntervalSinceNow)
        let request = UNNotificationRequest(
            identifier: CoachNotificationIdentifiers.snooze(messageId),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    func removePending(identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func setBadgeCount(_ count: Int) async {
        try? await UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }

    func authorizationStatus() async -> CoachSyncRequest.NotificationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .ephemeral: return .authorized
        case .provisional: return .provisional
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}

// MARK: - Scheduler

struct CoachNotificationScheduler: Sendable {
    let center: any CoachNotificationCenter

    static let live = CoachNotificationScheduler(center: LiveCoachNotificationCenter())

    /// Diff-reconciles pending `shudo.coach.msg.*` requests against `rows`.
    @discardableResult
    func reconcile(
        rows: [CoachScheduledRow],
        unreadCount: Int,
        suppressed: Set<UUID>,
        now: Date
    ) async -> CoachNotificationDiff {
        let plan = CoachNotificationPolicy.plan(
            rows: rows,
            now: now,
            unreadCount: unreadCount,
            suppressed: suppressed
        )
        let pending = await center.pendingCoachRequests()
        let diff = CoachNotificationPolicy.diff(plan: plan, pending: pending)
        await center.removePending(identifiers: diff.toRemove)
        for notification in diff.toAdd {
            await center.add(notification)
        }
        return diff
    }

    func cancel(messageIds: [UUID]) async {
        await center.removePending(identifiers: messageIds.flatMap {
            [CoachNotificationIdentifiers.message($0), CoachNotificationIdentifiers.snooze($0)]
        })
    }

    /// Removes every pending coach request (coach disabled / signed out).
    func removeAllPending() async {
        let pending = await center.pendingCoachRequests()
        await center.removePending(identifiers: pending.map(\.identifier))
    }

    func removeDelivered(messageIds: [UUID]) async {
        await center.removeDelivered(identifiers: messageIds.flatMap {
            [CoachNotificationIdentifiers.message($0), CoachNotificationIdentifiers.snooze($0)]
        })
    }

    /// Posts coach replies right now (nil trigger), as if texted.
    func presentImmediately(_ messages: [CoachMessage], firstBadge: Int?) async {
        for (index, message) in messages.enumerated() where message.role == .coach {
            let text = message.notificationText
            guard !text.isEmpty else { continue }
            var row = CoachScheduledRow(message: message)
            row.text = text
            let planned = CoachNotificationPolicy.planned(
                row: row,
                fireAt: nil,
                badge: firstBadge.map { $0 + index }
            )
            await center.add(planned)
        }
    }

    func snooze(_ payload: CoachNotificationPayload, messageId: UUID, fireAt: Date) async {
        await center.addSnooze(of: payload, messageId: messageId, fireAt: fireAt)
    }

    func setBadge(_ count: Int) async {
        await center.setBadgeCount(count)
    }

    func authorizationStatus() async -> CoachSyncRequest.NotificationStatus {
        await center.authorizationStatus()
    }
}

// MARK: - Categories and authorization

enum CoachNotificationCategories {
    static let hiddenPreviewPlaceholder = "Shudo texted you"

    static func make() -> Set<UNNotificationCategory> {
        let reply = UNTextInputNotificationAction(
            identifier: CoachNotificationIdentifiers.replyAction,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Text Shudo…"
        )
        let ack = UNNotificationAction(
            identifier: CoachNotificationIdentifiers.ackAction,
            title: "👊 On it",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: CoachNotificationIdentifiers.snoozeAction,
            title: "Snooze 1h",
            options: []
        )
        let directions = UNNotificationAction(
            identifier: CoachNotificationIdentifiers.directionsAction,
            title: "Directions",
            options: [.foreground]
        )
        let options: UNNotificationCategoryOptions = [.customDismissAction, .hiddenPreviewsShowTitle]
        return [
            UNNotificationCategory(
                identifier: CoachNotificationIdentifiers.textCategory,
                actions: [reply, ack, snooze],
                intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: hiddenPreviewPlaceholder,
                options: options
            ),
            UNNotificationCategory(
                identifier: CoachNotificationIdentifiers.snackCategory,
                actions: [directions, reply],
                intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: hiddenPreviewPlaceholder,
                options: options
            ),
        ]
    }

    static func register(on center: UNUserNotificationCenter = .current()) {
        center.setNotificationCategories(make())
    }
}

enum CoachNotificationAuthorization {
    /// Asks for alerts, sounds and badges (+ in-app notification settings).
    /// Returns whether coach texts can be delivered.
    static func request() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let options: UNAuthorizationOptions = [.alert, .sound, .badge, .providesAppNotificationSettings]
        let granted = (try? await center.requestAuthorization(options: options)) ?? false
        if granted { CoachNotificationCategories.register(on: center) }
        return granted
    }
}

// MARK: - Thread presence and the VM's notifier

/// Whether the coach thread is on screen (the Today tab sets this). While it
/// is, incoming coach notifications are not bannered; the thread refreshes.
@MainActor
final class CoachPresence {
    static let shared = CoachPresence()
    var isThreadVisible = false
    private init() {}
}

extension Notification.Name {
    /// Posted on the main thread when coach rows changed (sync, foreground
    /// notification). `userInfo["local_days"]` is `[String]` when known.
    static let coachThreadDidChange = Notification.Name("shudo.coachThreadDidChange")
}

/// Bridges `CoachViewModel` to the notification center and app state.
@MainActor
final class LiveCoachThreadNotifier: CoachThreadNotifying {
    static let shared = LiveCoachThreadNotifier()
    private let scheduler: CoachNotificationScheduler

    init(scheduler: CoachNotificationScheduler = .live) {
        self.scheduler = scheduler
    }

    var isAppActive: Bool { UIApplication.shared.applicationState == .active }

    func removeDelivered(messageIds: [UUID]) {
        let scheduler = scheduler
        Task { await scheduler.removeDelivered(messageIds: messageIds) }
    }

    func setBadge(_ count: Int) {
        let scheduler = scheduler
        Task { await scheduler.setBadge(count) }
    }

    func presentReplies(_ messages: [CoachMessage], unreadCount: Int) {
        let scheduler = scheduler
        Task { await scheduler.presentImmediately(messages, firstBadge: unreadCount + 1) }
    }
}
