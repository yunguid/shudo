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
    /// Bundled two-note text tone (`scripts/make-coach-chime.py`).
    static let soundName = "coach_text.caf"

    static let textCategory = "COACH_TEXT"
    /// Texts about eating (the day's plan, meal check-ins, the close-out):
    /// they lead with Log food.
    static let foodCategory = "COACH_FOOD"
    static let snackCategory = "COACH_SNACK"

    static let replyAction = "coach.reply"
    static let ackAction = "coach.ack"
    static let snoozeAction = "coach.snooze"
    static let directionsAction = "coach.directions"
    static let logFoodAction = "coach.log-food"

    static func message(_ id: UUID) -> String { messagePrefix + id.uuidString.lowercased() }
    static func snooze(_ id: UUID) -> String { snoozePrefix + id.uuidString.lowercased() }

    static func messageId(fromIdentifier identifier: String) -> UUID? {
        for prefix in [messagePrefix, snoozePrefix] where identifier.hasPrefix(prefix) {
            return UUID(uuidString: String(identifier.dropFirst(prefix.count)))
        }
        return nil
    }
}

// MARK: - Coach day

/// The coach's day turns over at 04:00, like the server's
/// (`COACH_DAY_BOUNDARY_MINUTES`): a 12:30 am close-out still belongs to the
/// evening it closes. Badges and Notification Center are scoped to it.
enum CoachDayBoundary {
    static let hour = 4

    static func day(for date: Date, timeZone: TimeZone) -> String {
        CoachLocalDay.string(for: date.addingTimeInterval(-Double(hour) * 3600), timeZone: timeZone)
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
    /// `payload.topic` of a planned slot (`lunch`, `closeout`, …); picks the
    /// actions. Optional so state saved by older builds still decodes.
    var topic: String?

    init(
        id: UUID,
        kind: String,
        localDay: String,
        deliverAt: Date,
        status: CoachMessageStatus,
        notify: Bool,
        text: String,
        readAt: Date? = nil,
        mapsQuery: String? = nil,
        topic: String? = nil
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
        self.topic = topic
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
            mapsQuery: mapsQuery,
            topic: message.rawPayload["topic"]?.stringValue
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
    /// When the request will fire (nil when unknown).
    var fireAt: Date? = nil
}

/// A coach text still sitting in Notification Center.
struct CoachDeliveredNotification: Equatable, Sendable {
    let identifier: String
    /// The text's coach day (`payload.local_day`), when it carried one.
    let localDay: String?
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
    /// Texts written before a log go stale for this long after it. Mirrors
    /// the server's post-log quiet (`POST_LOG_QUIET_MINUTES` in
    /// `_shared/coach_policy.ts`), so the client never mutes a text the
    /// server deliberately kept.
    static let cancelOnLogWindow: TimeInterval = 45 * 60
    static let snoozeInterval: TimeInterval = 60 * 60
    /// A log also drops snoozed texts due within this window (a snooze is an
    /// hour out; one pushed past quiet hours to the morning survives).
    static let snoozeCancelOnLogWindow: TimeInterval = 90 * 60

    /// - Parameters:
    ///   - unreadCount: today's unread texts (the badge counts the coach day
    ///     only, so yesterday's unread nudges never inflate it).
    ///   - quietHours: when given, rows due inside quiet hours are not
    ///     notified (the server already marks them `notify=false`; this is
    ///     the client-side safety net). They still appear in the thread.
    static func plan(
        rows: [CoachScheduledRow],
        now: Date,
        unreadCount: Int,
        suppressed: Set<UUID> = [],
        quietHours settings: CoachSettings? = nil,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> [PlannedCoachNotification] {
        // Badges are absolute: today's texts count up from today's unread
        // (one about to fire still takes its number); tomorrow's morning
        // plan starts a fresh count at 1.
        let today = CoachDayBoundary.day(for: now, timeZone: timeZone)
        var counts: [String: Int] = [:]
        var plan: [PlannedCoachNotification] = []
        for row in upcoming(rows, now: now, suppressed: suppressed, quietHours: settings, timeZone: timeZone) {
            let day = row.localDay > today ? row.localDay : today
            counts[day, default: day == today ? max(0, unreadCount) : 0] += 1
            guard row.deliverAt > now.addingTimeInterval(minimumLeadTime) else { continue }
            plan.append(planned(row: row, fireAt: row.deliverAt, badge: counts[day]))
            if plan.count == maximumPendingMessages { break }
        }
        return plan
    }

    /// Requests due within the lead time: too close to (re)add, but a
    /// reconcile must leave them pending or the text never rings. (A lock-
    /// screen reply or a foreground sync seconds before a text was due used
    /// to drop it.)
    static func imminentIdentifiers(
        rows: [CoachScheduledRow],
        now: Date,
        suppressed: Set<UUID> = [],
        quietHours settings: CoachSettings? = nil,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Set<String> {
        Set(
            upcoming(rows, now: now, suppressed: suppressed, quietHours: settings, timeZone: timeZone)
                .filter { $0.deliverAt <= now.addingTimeInterval(minimumLeadTime) }
                .map { CoachNotificationIdentifiers.message($0.id) }
        )
    }

    /// Rows that should ring, soonest first.
    private static func upcoming(
        _ rows: [CoachScheduledRow],
        now: Date,
        suppressed: Set<UUID>,
        quietHours settings: CoachSettings?,
        timeZone: TimeZone
    ) -> [CoachScheduledRow] {
        rows
            .filter { row in
                row.status == .scheduled
                    && row.notify
                    && row.readAt == nil
                    && row.deliverAt > now
                    && !suppressed.contains(row.id)
                    && !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !(settings?.isQuietHour(row.deliverAt, timeZone: timeZone) ?? false)
            }
            .sorted { ($0.deliverAt, $0.id.uuidString) < ($1.deliverAt, $1.id.uuidString) }
    }

    static func planned(row: CoachScheduledRow, fireAt: Date?, badge: Int?) -> PlannedCoachNotification {
        let category = category(kind: row.kind, topic: row.topic)
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
            interruption: interruption(for: row.kind, body: body),
            relevance: relevance(for: row.kind),
            contentHash: contentHash(body: body, fireAt: fireAt, badge: badge, category: category)
        )
    }

    /// Slot topics about eating: their texts offer Log food first.
    static let foodTopics: Set<String> = [
        "morning_plan", "breakfast", "snack", "lunch", "protein_gap", "dinner", "closeout",
    ]

    /// The actions a text offers: snack recs lead with Directions, texts
    /// about eating with Log food, everything else (a reply, the pre-lift
    /// push, a check-in on him) with Reply.
    static func category(kind: String, topic: String?) -> String {
        if kind == CoachMessageKind.snackRec.rawValue { return CoachNotificationIdentifiers.snackCategory }
        if let topic, foodTopics.contains(topic) { return CoachNotificationIdentifiers.foodCategory }
        return CoachNotificationIdentifiers.textCategory
    }

    /// Texts that ask something of Luke ring (`.active`); confirmations and
    /// read-later messages land quietly in the list (`.passive`), unless
    /// they ask a question: a close-out asking whether dinner happened
    /// needs an answer tonight, so it rings.
    static func interruption(for kind: String, body: String = "") -> PlannedCoachNotification.Interruption {
        switch CoachMessageKind(rawValue: kind) {
        case .mealAck?, .workoutAck?, .weighInAck?, .recap?, .photoFeedback?, .profileUpdate?:
            return body.contains("?") ? .active : .passive
        default:
            return .active
        }
    }

    /// Which text iOS features when it summarizes Shudo's stack.
    static func relevance(for kind: String) -> Double {
        switch CoachMessageKind(rawValue: kind) {
        case .snackRec?: return 0.9
        case .checkpoint?: return 0.8
        case .plan?, .text?: return 0.7
        case .trainingPlan?, .goalChange?: return 0.6
        case .recap?, .photoFeedback?, .profileUpdate?: return 0.4
        default: return 0.2
        }
    }

    /// The same text re-posted an hour later under `shudo.coach.snooze.<id>`.
    static func snoozed(
        _ payload: CoachNotificationPayload,
        messageId: UUID,
        fireAt: Date
    ) -> PlannedCoachNotification {
        let kind = payload.kind ?? CoachMessageKind.text.rawValue
        let category = payload.categoryIdentifier.isEmpty
            ? CoachNotificationIdentifiers.textCategory : payload.categoryIdentifier
        let body = payload.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return PlannedCoachNotification(
            messageId: messageId,
            identifier: CoachNotificationIdentifiers.snooze(messageId),
            fireAt: fireAt,
            title: CoachNotificationIdentifiers.title,
            body: body,
            badge: nil,
            categoryIdentifier: category,
            kind: kind,
            localDay: payload.localDay ?? "",
            mapsQuery: payload.mapsQuery,
            interruption: .active,
            relevance: relevance(for: kind),
            contentHash: contentHash(body: body, fireAt: fireAt, badge: nil, category: category)
        )
    }

    /// Pending snoozes a fresh log makes stale.
    static func snoozesToCancelOnLog(
        pending: [CoachPendingRequest],
        now: Date,
        window: TimeInterval = snoozeCancelOnLogWindow
    ) -> [String] {
        pending
            .filter { request in
                guard request.identifier.hasPrefix(CoachNotificationIdentifiers.snoozePrefix),
                      let fireAt = request.fireAt else { return false }
                return fireAt <= now.addingTimeInterval(window)
            }
            .map(\.identifier)
            .sorted()
    }

    /// Delivered texts from an earlier coach day. Yesterday's lunch nudge is
    /// noise by morning; every text stays in the thread.
    static func staleDelivered(_ delivered: [CoachDeliveredNotification], today: String) -> [String] {
        delivered
            .filter { notification in
                guard let day = notification.localDay, CoachLocalDay.isValid(day) else { return false }
                return day < today
            }
            .map(\.identifier)
            .sorted()
    }

    /// Lock-screen line for Shudo's answer to a lock-screen reply: one text
    /// however many bubbles it runs to, so an answer never lands as a burst.
    static let maximumAnswerLength = 400

    /// Shudo's answer as one notification under the first bubble's id. A
    /// card that rode along (a snack rec) lends its Directions; the badge
    /// counts every message the answer added to the thread.
    static func answer(_ messages: [CoachMessage], firstBadge: Int?) -> PlannedCoachNotification? {
        let replies = messages.filter { $0.role == .coach && !$0.notificationText.isEmpty }
        let texts = replies.filter { $0.kind == CoachMessageKind.text.rawValue }
        guard let lead = texts.first ?? replies.first else { return nil }
        let joined = (texts.isEmpty ? [lead.notificationText] : texts.map(\.body))
            .flatMap { $0.components(separatedBy: "\n") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let body = joined.count > maximumAnswerLength
            ? String(joined.prefix(maximumAnswerLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
            : joined
        let snack = replies.lazy.map(CoachScheduledRow.init(message:)).first { $0.mapsQuery != nil }
        var row = CoachScheduledRow(message: lead)
        row.text = body
        if let snack {
            row.kind = snack.kind
            row.mapsQuery = snack.mapsQuery
        }
        return planned(row: row, fireAt: nil, badge: firstBadge.map { $0 + replies.count - 1 })
    }

    /// Deterministic across launches (unlike `hashValue`). The version
    /// prefix changes whenever the content builder does, so a new build
    /// re-posts pending requests with the new styling exactly once.
    static func contentHash(body: String, fireAt: Date?, badge: Int?, category: String) -> String {
        let fire = fireAt.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "now"
        let input = "v3|\(category)|\(fire)|\(badge.map(String.init) ?? "-")|\(body)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// - Parameter imminent: pending requests about to fire; never removed.
    static func diff(
        plan: [PlannedCoachNotification],
        pending: [CoachPendingRequest],
        keeping imminent: Set<String> = []
    ) -> CoachNotificationDiff {
        let owned = pending.filter { $0.identifier.hasPrefix(CoachNotificationIdentifiers.messagePrefix) }
        let pendingHashes = Dictionary(
            owned.map { ($0.identifier, $0.contentHash ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        let plannedIds = Set(plan.map(\.identifier))
        let toRemove = pendingHashes.keys
            .filter { !plannedIds.contains($0) && !imminent.contains($0) }
            .sorted()
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

// MARK: - Background refresh timing

/// When to ask iOS for the next background refresh. Without push, a text
/// only rings if the phone heard about it first, and the server writes the
/// whole day in its early-morning run (09:17 UTC: 5:17 am in New York, 4:17
/// in winter). The refresh that matters most is the one right after it, so
/// nights ask for 5:30 am; daytime asks again within the hour to pick up
/// re-plans. iOS treats the date as a floor and still decides.
enum CoachRefreshPolicy {
    static let morningHour = 5
    static let morningMinute = 30
    static let daytimeInterval: TimeInterval = 60 * 60
    /// From here until morning nothing new is written unless Luke acts.
    static let eveningCutoffHour = 21

    static func earliestBeginDate(after now: Date, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        guard let morning = calendar.date(
            bySettingHour: morningHour, minute: morningMinute, second: 0, of: now
        ) else { return now.addingTimeInterval(daytimeInterval) }
        if (hour, minute) < (morningHour, morningMinute) { return morning }
        if hour >= eveningCutoffHour {
            return calendar.date(byAdding: .day, value: 1, to: morning) ?? now.addingTimeInterval(daytimeInterval)
        }
        return now.addingTimeInterval(daytimeInterval)
    }
}

// MARK: - Notification center seam

protocol CoachNotificationCenter: Sendable {
    func pendingCoachRequests() async -> [CoachPendingRequest]
    /// Adds (or, for an existing identifier, replaces) a request. A nil
    /// `fireAt` delivers immediately.
    func add(_ notification: PlannedCoachNotification) async
    func removePending(identifiers: [String]) async
    func removeDelivered(identifiers: [String]) async
    func setBadgeCount(_ count: Int) async
    func authorizationStatus() async -> CoachSyncRequest.NotificationStatus
    /// Shows the system prompt (only ever once per install); true if granted.
    func requestAuthorization() async -> Bool
    /// Coach texts still showing in Notification Center.
    func deliveredCoachNotifications() async -> [CoachDeliveredNotification]
}

extension CoachNotificationCenter {
    func deliveredCoachNotifications() async -> [CoachDeliveredNotification] { [] }
}

/// How a coach text looks on the lock screen: one sender ("Shudo"), no
/// subtitle, the text itself, one conversation thread, the soft two-note
/// tone for texts that ask something of Luke and silence for the rest.
enum CoachNotificationContent {
    static func make(_ notification: PlannedCoachNotification) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.threadIdentifier = CoachNotificationIdentifiers.threadIdentifier
        content.categoryIdentifier = notification.categoryIdentifier
        content.userInfo = CoachNotificationPayload.userInfo(for: notification)
        content.targetContentIdentifier = notification.messageId.uuidString.lowercased()
        content.relevanceScore = notification.relevance
        switch notification.interruption {
        case .active:
            content.interruptionLevel = .active
            content.sound = UNNotificationSound(
                named: UNNotificationSoundName(CoachNotificationIdentifiers.soundName)
            )
        case .passive:
            content.interruptionLevel = .passive
        }
        if let badge = notification.badge { content.badge = NSNumber(value: badge) }
        return content
    }
}

struct LiveCoachNotificationCenter: CoachNotificationCenter {
    func pendingCoachRequests() async -> [CoachPendingRequest] {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.compactMap { request in
            guard request.identifier.hasPrefix(CoachNotificationIdentifiers.ownedPrefix) else { return nil }
            let payload = CoachNotificationPayload(userInfo: request.content.userInfo)
            let fireAt = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
                ?? (request.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
            return CoachPendingRequest(
                identifier: request.identifier,
                contentHash: payload?.contentHash,
                fireAt: fireAt
            )
        }
    }

    func add(_ notification: PlannedCoachNotification) async {
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
            content: CoachNotificationContent.make(notification),
            trigger: trigger
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

    func deliveredCoachNotifications() async -> [CoachDeliveredNotification] {
        await UNUserNotificationCenter.current().deliveredNotifications().compactMap { notification in
            let request = notification.request
            guard request.identifier.hasPrefix(CoachNotificationIdentifiers.ownedPrefix) else { return nil }
            return CoachDeliveredNotification(
                identifier: request.identifier,
                localDay: CoachNotificationPayload(userInfo: request.content.userInfo)?.localDay
            )
        }
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

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let options: UNAuthorizationOptions = [.alert, .sound, .badge, .providesAppNotificationSettings]
        let granted = (try? await center.requestAuthorization(options: options)) ?? false
        if granted { CoachNotificationCategories.register(on: center) }
        return granted
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
        now: Date,
        quietHours settings: CoachSettings? = nil,
        timeZone: TimeZone = .autoupdatingCurrent
    ) async -> CoachNotificationDiff {
        let plan = CoachNotificationPolicy.plan(
            rows: rows,
            now: now,
            unreadCount: unreadCount,
            suppressed: suppressed,
            quietHours: settings,
            timeZone: timeZone
        )
        let imminent = CoachNotificationPolicy.imminentIdentifiers(
            rows: rows,
            now: now,
            suppressed: suppressed,
            quietHours: settings,
            timeZone: timeZone
        )
        let pending = await center.pendingCoachRequests()
        let diff = CoachNotificationPolicy.diff(plan: plan, pending: pending, keeping: imminent)
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

    /// Drops snoozed texts that a fresh log made stale; returns their ids.
    @discardableResult
    func cancelSnoozesAfterLog(now: Date) async -> [String] {
        let pending = await center.pendingCoachRequests()
        let identifiers = CoachNotificationPolicy.snoozesToCancelOnLog(pending: pending, now: now)
        await center.removePending(identifiers: identifiers)
        return identifiers
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

    /// Clears texts from earlier coach days out of Notification Center;
    /// returns their identifiers.
    @discardableResult
    func clearEarlierDays(today: String) async -> [String] {
        let stale = CoachNotificationPolicy.staleDelivered(
            await center.deliveredCoachNotifications(),
            today: today
        )
        await center.removeDelivered(identifiers: stale)
        return stale
    }

    /// Posts Shudo's answer right now (nil trigger), as one text.
    func presentImmediately(_ messages: [CoachMessage], firstBadge: Int?) async {
        guard let answer = CoachNotificationPolicy.answer(messages, firstBadge: firstBadge) else { return }
        await center.add(answer)
    }

    /// Re-posts the text an hour out and clears the original from
    /// Notification Center so the stack never shows it twice.
    func snooze(_ payload: CoachNotificationPayload, messageId: UUID, fireAt: Date) async {
        await center.removeDelivered(identifiers: [CoachNotificationIdentifiers.message(messageId)])
        await center.add(CoachNotificationPolicy.snoozed(payload, messageId: messageId, fireAt: fireAt))
    }

    func setBadge(_ count: Int) async {
        await center.setBadgeCount(count)
    }

    func authorizationStatus() async -> CoachSyncRequest.NotificationStatus {
        await center.authorizationStatus()
    }

    /// Prompts only while the answer is still undetermined.
    func requestAuthorizationIfNeeded() async -> CoachSyncRequest.NotificationStatus {
        let status = await center.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await center.requestAuthorization() ? .authorized : .denied
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
            icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Text Shudo"
        )
        let ack = UNNotificationAction(
            identifier: CoachNotificationIdentifiers.ackAction,
            title: "On it",
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "hand.thumbsup")
        )
        let snooze = UNNotificationAction(
            identifier: CoachNotificationIdentifiers.snoozeAction,
            title: "Snooze 1 hour",
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "clock")
        )
        let directions = UNNotificationAction(
            identifier: CoachNotificationIdentifiers.directionsAction,
            title: "Directions",
            options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "map")
        )
        // Straight into the food sheet: camera, photos or a barcode.
        let logFood = UNNotificationAction(
            identifier: CoachNotificationIdentifiers.logFoodAction,
            title: "Log food",
            options: [.foreground],
            icon: UNNotificationActionIcon(systemImageName: "fork.knife")
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
                identifier: CoachNotificationIdentifiers.foodCategory,
                actions: [logFood, reply, snooze],
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
        await LiveCoachNotificationCenter().requestAuthorization()
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
/// Unread changes go through `CoachSync` so the badges baked into pending
/// requests are renumbered too — otherwise the next text would show the
/// stale, higher count after Luke read the thread.
@MainActor
final class LiveCoachThreadNotifier: CoachThreadNotifying {
    static let shared = LiveCoachThreadNotifier()
    private let scheduler: CoachNotificationScheduler
    private let sync: CoachSync

    init(scheduler: CoachNotificationScheduler = .live, sync: CoachSync = .shared) {
        self.scheduler = scheduler
        self.sync = sync
    }

    var isAppActive: Bool { UIApplication.shared.applicationState == .active }

    func removeDelivered(messageIds: [UUID]) {
        #if DEBUG
        if CoachNotificationDemo.isEnabled {
            CoachNotificationDemo.log("thread read → clear delivered \(messageIds.map { $0.uuidString.lowercased().suffix(8) })")
        }
        #endif
        let scheduler = scheduler
        Task { await scheduler.removeDelivered(messageIds: messageIds) }
    }

    func setBadge(_ count: Int) {
        let sync = sync
        Task { await sync.updateUnreadCount(count) }
    }

    func presentReplies(_ messages: [CoachMessage], unreadCount: Int) {
        let sync = sync
        Task { await sync.presentReplies(messages, unreadCount: unreadCount) }
    }
}
