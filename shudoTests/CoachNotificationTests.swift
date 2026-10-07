import Foundation
import Testing
@testable import shudo

/// Records what the scheduler asks of the notification center.
final class RecordingCoachNotificationCenter: CoachNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _pending: [String: PlannedCoachNotification] = [:]
    private var _delivered: [PlannedCoachNotification] = []
    private var _removedPending: [String] = []
    private var _removedDelivered: [String] = []
    private var _badge: Int?
    private var _addCount = 0
    private var _authorizationRequests = 0
    var status: CoachSyncRequest.NotificationStatus = .authorized
    /// What the next authorization prompt answers.
    var grantsAuthorization = true

    var pending: [String: PlannedCoachNotification] { lock.withLock { _pending } }
    var delivered: [PlannedCoachNotification] { lock.withLock { _delivered } }
    var removedPending: [String] { lock.withLock { _removedPending } }
    var removedDelivered: [String] { lock.withLock { _removedDelivered } }
    var badge: Int? { lock.withLock { _badge } }
    var addCount: Int { lock.withLock { _addCount } }
    var authorizationRequests: Int { lock.withLock { _authorizationRequests } }
    var snoozes: [PlannedCoachNotification] {
        pending.values
            .filter { $0.identifier.hasPrefix(CoachNotificationIdentifiers.snoozePrefix) }
            .sorted { $0.identifier < $1.identifier }
    }

    func seedPending(_ notifications: [PlannedCoachNotification]) {
        lock.withLock { for n in notifications { _pending[n.identifier] = n } }
    }

    func pendingCoachRequests() async -> [CoachPendingRequest] {
        lock.withLock {
            _pending.values.map {
                CoachPendingRequest(identifier: $0.identifier, contentHash: $0.contentHash, fireAt: $0.fireAt)
            }
        }
    }

    func add(_ notification: PlannedCoachNotification) async {
        lock.withLock {
            _addCount += 1
            if notification.fireAt == nil {
                _delivered.append(notification)
            } else {
                _pending[notification.identifier] = notification
            }
        }
    }

    func removePending(identifiers: [String]) async {
        lock.withLock {
            _removedPending += identifiers
            for identifier in identifiers { _pending[identifier] = nil }
        }
    }

    func removeDelivered(identifiers: [String]) async {
        lock.withLock { _removedDelivered += identifiers }
    }

    func setBadgeCount(_ count: Int) async {
        lock.withLock { _badge = count }
    }

    func authorizationStatus() async -> CoachSyncRequest.NotificationStatus { lock.withLock { status } }

    func requestAuthorization() async -> Bool {
        lock.withLock {
            _authorizationRequests += 1
            status = grantsAuthorization ? .authorized : .denied
            return grantsAuthorization
        }
    }
}

struct CoachNotificationPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_791_302_400)

    private func row(
        _ minutesFromNow: Double,
        status: CoachMessageStatus = .scheduled,
        notify: Bool = true,
        kind: String = "checkpoint",
        text: String = "Protein check.",
        read: Bool = false,
        id: UUID = UUID()
    ) -> CoachScheduledRow {
        CoachScheduledRow(
            id: id,
            kind: kind,
            localDay: "2026-10-06",
            deliverAt: now.addingTimeInterval(minutesFromNow * 60),
            status: status,
            notify: notify,
            text: text,
            readAt: read ? now : nil
        )
    }

    // MARK: Plan

    @Test func plansOnlyFutureScheduledNotifyingUnreadRows() {
        let keep = row(30)
        let rows = [
            keep,
            row(-5),                              // past
            row(0.05),                            // due within the 5 s lead
            row(40, status: .delivered),
            row(45, status: .superseded),
            row(50, notify: false),
            row(55, read: true),
            row(60, text: "   "),
        ]
        let plan = CoachNotificationPolicy.plan(rows: rows, now: now, unreadCount: 0)
        #expect(plan.map(\.messageId) == [keep.id])
        let first = plan[0]
        #expect(first.identifier == "shudo.coach.msg.\(keep.id.uuidString.lowercased())")
        #expect(first.title == "Shudo")
        #expect(first.body == "Protein check.")
        #expect(first.categoryIdentifier == CoachNotificationIdentifiers.textCategory)
        #expect(first.fireAt == keep.deliverAt)
    }

    @Test func badgesCountUpFromTheUnreadTotalInDeliveryOrder() {
        let later = row(120)
        let sooner = row(10)
        let plan = CoachNotificationPolicy.plan(rows: [later, sooner], now: now, unreadCount: 3)
        #expect(plan.map(\.messageId) == [sooner.id, later.id])
        #expect(plan.map(\.badge) == [4, 5])
    }

    @Test func capsAtFortyKeepingTheSoonest() {
        let rows = (1...55).map { row(Double($0) * 10) }.shuffled()
        let plan = CoachNotificationPolicy.plan(rows: rows, now: now, unreadCount: 0)
        #expect(plan.count == CoachNotificationPolicy.maximumPendingMessages)
        #expect(plan.count == 40)
        let fireDates = plan.compactMap(\.fireAt)
        #expect(fireDates == fireDates.sorted())
        #expect(fireDates.last == now.addingTimeInterval(400 * 60))
    }

    @Test func suppressedRowsAreNotPlanned() {
        let suppressed = row(20)
        let other = row(30)
        let plan = CoachNotificationPolicy.plan(
            rows: [suppressed, other],
            now: now,
            unreadCount: 0,
            suppressed: [suppressed.id]
        )
        #expect(plan.map(\.messageId) == [other.id])
    }

    @Test func snackRecommendationsUseTheSnackCategoryAndCarryMapsQuery() {
        var snack = row(15, kind: "snack_rec")
        snack.mapsQuery = "7-Eleven 2nd Ave"
        let planned = CoachNotificationPolicy.plan(rows: [snack], now: now, unreadCount: 0)
        #expect(planned.first?.categoryIdentifier == CoachNotificationIdentifiers.snackCategory)
        #expect(planned.first?.relevance == 0.9)
        let info = CoachNotificationPayload.userInfo(for: planned[0])
        let payload = CoachNotificationPayload(userInfo: info)
        #expect(payload?.messageId == snack.id)
        #expect(payload?.mapsQuery == "7-Eleven 2nd Ave")
        #expect(payload?.localDay == "2026-10-06")
        #expect(payload?.contentHash == planned[0].contentHash)
        #expect(payload?.deepLink == AppRouter.coachDeepLink(messageId: snack.id, localDay: "2026-10-06"))
    }

    @Test func contentHashIsDeterministicAndSensitive() {
        let date = now.addingTimeInterval(600)
        let hash = CoachNotificationPolicy.contentHash(body: "A", fireAt: date, badge: 1, category: "COACH_TEXT")
        #expect(hash == CoachNotificationPolicy.contentHash(body: "A", fireAt: date, badge: 1, category: "COACH_TEXT"))
        #expect(hash.count == 16)
        #expect(hash != CoachNotificationPolicy.contentHash(body: "B", fireAt: date, badge: 1, category: "COACH_TEXT"))
        #expect(hash != CoachNotificationPolicy.contentHash(body: "A", fireAt: date.addingTimeInterval(60), badge: 1, category: "COACH_TEXT"))
        #expect(hash != CoachNotificationPolicy.contentHash(body: "A", fireAt: date, badge: 2, category: "COACH_TEXT"))
    }

    // MARK: Diff

    @Test func diffAddsMissingRemovesStaleAndReplacesChanged() {
        let unchanged = row(10)
        let changed = row(20)
        let added = row(30)
        let removedId = UUID()
        let oldPlan = CoachNotificationPolicy.plan(rows: [unchanged, changed], now: now, unreadCount: 0)
        var edited = changed
        edited.text = "New copy."
        let newPlan = CoachNotificationPolicy.plan(rows: [unchanged, edited, added], now: now, unreadCount: 0)

        var pending = oldPlan.map { CoachPendingRequest(identifier: $0.identifier, contentHash: $0.contentHash) }
        pending.append(CoachPendingRequest(identifier: CoachNotificationIdentifiers.message(removedId), contentHash: "x"))
        // Not ours to reconcile: snoozes, nudges, the weigh-in reminder.
        pending.append(CoachPendingRequest(identifier: CoachNotificationIdentifiers.snooze(UUID()), contentHash: nil))
        pending.append(CoachPendingRequest(identifier: "shudo.nudge.weighin", contentHash: nil))

        let diff = CoachNotificationPolicy.diff(plan: newPlan, pending: pending)
        #expect(Set(diff.toAdd.map(\.messageId)) == [edited.id, added.id])
        #expect(diff.toRemove == [CoachNotificationIdentifiers.message(removedId)])
        #expect(!diff.toRemove.contains(CoachNotificationIdentifiers.message(changed.id)),
                "a replaced request is re-added under the same identifier, never removed first")
        #expect(!diff.toAdd.contains { $0.messageId == unchanged.id })
    }

    @Test func diffAgainstItselfIsEmpty() {
        let plan = CoachNotificationPolicy.plan(rows: [row(10), row(20)], now: now, unreadCount: 2)
        let pending = plan.map { CoachPendingRequest(identifier: $0.identifier, contentHash: $0.contentHash) }
        #expect(CoachNotificationPolicy.diff(plan: plan, pending: pending).isEmpty)
    }

    @Test func schedulerReconcileAppliesTheDiffToTheCenter() async {
        let center = RecordingCoachNotificationCenter()
        let scheduler = CoachNotificationScheduler(center: center)
        let first = row(10)
        let second = row(20)
        await scheduler.reconcile(rows: [first, second], unreadCount: 0, suppressed: [], now: now)
        #expect(center.pending.count == 2)
        #expect(center.addCount == 2)

        // Same plan again: nothing re-added.
        await scheduler.reconcile(rows: [first, second], unreadCount: 0, suppressed: [], now: now)
        #expect(center.addCount == 2)

        // Second row superseded on the server: removed.
        await scheduler.reconcile(rows: [first], unreadCount: 0, suppressed: [], now: now)
        #expect(Set(center.pending.keys) == [CoachNotificationIdentifiers.message(first.id)])
        #expect(center.removedPending == [CoachNotificationIdentifiers.message(second.id)])
    }

    // MARK: Cancel-on-log

    @Test func cancelOnLogTakesOnlyTheServersPostLogWindow() {
        #expect(CoachNotificationPolicy.cancelOnLogWindow == 45 * 60)
        let atNow = row(0)
        let soon = row(1)
        let edge = row(45)
        let justOutside = row(46)
        let quiet = row(30, notify: false)
        let superseded = row(30, status: .superseded)
        let past = row(-10)
        let ids = CoachNotificationPolicy.idsToCancelOnLog(
            rows: [justOutside, edge, soon, atNow, quiet, superseded, past],
            now: now
        )
        #expect(ids == [soon.id, edge.id])
    }

    // MARK: Store merge

    @Test func mergeFoldsServerChangesIntoTheUpcomingSet() {
        let kept = row(90)
        let toSupersede = row(30)
        let existing = [kept, toSupersede]

        func message(_ row: CoachScheduledRow, status: CoachMessageStatus, notify: Bool = true, role: CoachRole = .coach) -> CoachMessage {
            CoachMessage(
                id: row.id,
                role: role,
                kind: row.kind,
                body: "Body",
                rawPayload: .object(["push_body": .string("Push")]),
                localDay: row.localDay,
                deliverAt: row.deliverAt,
                status: status,
                notify: notify
            )
        }
        let newRow = row(45)
        let changes = [
            message(toSupersede, status: .superseded),
            message(newRow, status: .scheduled),
            message(row(50), status: .scheduled, notify: false),
            message(row(-30), status: .scheduled),
            message(row(10), status: .delivered, role: .user),
        ]
        let merged = CoachNotificationPolicy.merge(rows: existing, changes: changes, now: now)
        #expect(merged.map(\.id) == [newRow.id, kept.id])
        #expect(merged.first?.text == "Push", "push_body is the lock-screen text")
    }

    // MARK: Snooze

    @Test func snoozeLandsAnHourOutOrAfterQuietHours() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        var settings = CoachSettings.defaults
        settings.quietHoursStart = CoachClockTime(hour: 23, minute: 0)
        settings.quietHoursEnd = CoachClockTime(hour: 7, minute: 0)

        let afternoon = try #require(CoachDateCoding.date(from: "2026-10-06T15:00:00Z"))
        #expect(CoachNotificationPolicy.snoozeFireDate(now: afternoon, settings: settings, timeZone: utc)
            == afternoon.addingTimeInterval(3600))

        let lateEvening = try #require(CoachDateCoding.date(from: "2026-10-06T22:30:00Z"))
        #expect(CoachNotificationPolicy.snoozeFireDate(now: lateEvening, settings: settings, timeZone: utc)
            == CoachDateCoding.date(from: "2026-10-07T07:00:00Z"))

        let earlyMorning = try #require(CoachDateCoding.date(from: "2026-10-07T02:00:00Z"))
        #expect(CoachNotificationPolicy.snoozeFireDate(now: earlyMorning, settings: settings, timeZone: utc)
            == CoachDateCoding.date(from: "2026-10-07T07:00:00Z"))

        #expect(CoachNotificationPolicy.snoozeFireDate(now: lateEvening, settings: nil, timeZone: utc)
            == lateEvening.addingTimeInterval(3600))
    }

    @Test func triggerComponentsAreAbsolute() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        let date = try #require(CoachDateCoding.date(from: "2026-10-06T16:30:15Z"))
        let components = CoachNotificationPolicy.triggerComponents(for: date, timeZone: newYork)
        #expect(components.year == 2026 && components.month == 10 && components.day == 6)
        #expect(components.hour == 12 && components.minute == 30 && components.second == 15)
        #expect(components.timeZone == newYork)
    }

    @Test func identifiersRoundTrip() {
        let id = UUID()
        #expect(CoachNotificationIdentifiers.messageId(fromIdentifier: CoachNotificationIdentifiers.message(id)) == id)
        #expect(CoachNotificationIdentifiers.messageId(fromIdentifier: CoachNotificationIdentifiers.snooze(id)) == id)
        #expect(CoachNotificationIdentifiers.messageId(fromIdentifier: "shudo.nudge.lunch") == nil)
    }

    // MARK: Fallback nudges

    @Test func dayNudgesOnlyScheduleWhileTheCoachIsDisabled() throws {
        let suite = "shudo.tests.coach-mirror.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mirror = CoachSettingsMirror(suiteName: suite)

        #expect(DayNotificationScheduler.shouldScheduleFallbackNudges(defaults: defaults))
        var settings = CoachSettings.defaults
        settings.enabled = true
        mirror.save(settings, at: Date())
        #expect(!DayNotificationScheduler.shouldScheduleFallbackNudges(defaults: defaults))
        settings.enabled = false
        mirror.save(settings, at: Date())
        #expect(DayNotificationScheduler.shouldScheduleFallbackNudges(defaults: defaults))
    }
}

// MARK: - CoachSync

struct CoachSyncTests {
    private let now = Date(timeIntervalSince1970: 1_791_302_400)
    private let userId = "11111111-2222-3333-4444-555555555555"

    private func scheduled(minutes: Double, notify: Bool = true) -> CoachMessage {
        CoachMessage(
            role: .coach,
            kind: "checkpoint",
            body: "Lunch check. Protein first.",
            rawPayload: .object(["push_body": .string("Lunch. Protein first.")]),
            localDay: "2026-10-06",
            deliverAt: now.addingTimeInterval(minutes * 60),
            status: .scheduled,
            notify: notify,
            slotKey: "lunch",
            createdAt: now.addingTimeInterval(-600),
            updatedAt: now.addingTimeInterval(-60)
        )
    }

    private func makeSync(
        service: FakeCoachService,
        enabled: Bool = true,
        center: RecordingCoachNotificationCenter,
        store: InMemoryCoachSyncStateStore = InMemoryCoachSyncStateStore(),
        changes: CoachChangeLog? = nil
    ) throws -> (CoachSync, CoachSettingsMirror) {
        let suite = "shudo.tests.coach-sync.\(UUID().uuidString)"
        let mirror = CoachSettingsMirror(suiteName: suite)
        var settings = CoachSettings.defaults
        settings.enabled = enabled
        mirror.save(settings, at: now)
        let fixedNow = now
        let user = userId
        let environment = CoachSyncEnvironment(
            now: { fixedNow },
            timeZone: { TimeZone(identifier: "America/New_York")! },
            userId: { user },
            device: {
                CoachSyncRequest.Device(
                    deviceId: UUID(),
                    appVersion: "2.0 (1)",
                    osVersion: "26.5",
                    notificationStatus: .notDetermined,
                    locationStatus: .notDetermined
                )
            },
            locationContext: { _ in nil },
            postThreadChange: { days in changes?.append(days) }
        )
        let sync = CoachSync(
            service: service,
            scheduler: CoachNotificationScheduler(center: center),
            store: store,
            mirror: mirror,
            environment: environment
        )
        return (sync, mirror)
    }

    @Test func syncSchedulesUpcomingRowsAndPersistsTheCursor() async throws {
        let upcoming = scheduled(minutes: 90)
        let quiet = scheduled(minutes: 120, notify: false)
        let delivered = CoachMessage(
            role: .coach, kind: "text", body: "Morning.", localDay: "2026-10-06",
            deliverAt: now.addingTimeInterval(-3600), updatedAt: now.addingTimeInterval(-30)
        )
        let service = FakeCoachService(messages: [upcoming, quiet, delivered], now: { [now] in now })
        let center = RecordingCoachNotificationCenter()
        let store = InMemoryCoachSyncStateStore()
        let changes = CoachChangeLog()
        let (sync, _) = try makeSync(service: service, center: center, store: store, changes: changes)

        let outcome = await sync.sync(trigger: .foreground)
        #expect(outcome == .synced(changed: 3, generated: false))
        #expect(service.syncRequests.count == 1)
        #expect(service.syncRequests.first?.trigger == .foreground)
        #expect(service.syncRequests.first?.localDay == "2026-10-06")
        #expect(service.syncRequests.first?.device.notificationStatus == .authorized)
        #expect(Set(center.pending.keys) == [CoachNotificationIdentifiers.message(upcoming.id)])
        #expect(center.pending.values.first?.body == "Lunch. Protein first.")
        #expect(center.pending.values.first?.badge == 2, "one unread delivered message, then this one")
        #expect(center.badge == 1)
        let state = try #require(store.load())
        #expect(state.cursor == now.addingTimeInterval(-30))
        #expect(state.rows.map(\.id) == [upcoming.id])
        #expect(state.userId == userId)
        #expect(changes.days == [["2026-10-06"]])
    }

    @Test func loggingCancelsTextsDueWithinTheWindowAndKeepsThemSuppressed() async throws {
        let soon = scheduled(minutes: 25)
        let later = scheduled(minutes: 180)
        let service = FakeCoachService(messages: [soon, later], now: { [now] in now })
        let center = RecordingCoachNotificationCenter()
        let (sync, _) = try makeSync(service: service, center: center)
        await sync.sync(trigger: .foreground)
        #expect(center.pending.count == 2)

        let cancelled = await sync.cancelUpcomingAfterLog()
        #expect(cancelled == [soon.id])
        #expect(center.pending[CoachNotificationIdentifiers.message(soon.id)] == nil)
        #expect(center.pending[CoachNotificationIdentifiers.message(later.id)] != nil)

        // A later reconcile must not resurrect it.
        await sync.reconcileNotifications()
        #expect(center.pending[CoachNotificationIdentifiers.message(soon.id)] == nil)
        let suppressed = await sync.snapshot.suppressed
        #expect(suppressed[soon.id] != nil)
    }

    @Test func recordingAMealCancelsThenSyncs() async throws {
        let soon = scheduled(minutes: 25)
        let service = FakeCoachService(messages: [soon], now: { [now] in now })
        let center = RecordingCoachNotificationCenter()
        let (sync, _) = try makeSync(service: service, center: center)
        await sync.sync(trigger: .foreground)
        await sync.record(.mealLogged)
        #expect(center.pending.isEmpty)
        #expect(service.syncRequests.count == 2)
        #expect(service.syncRequests.last?.wait == false)

        let entryId = UUID()
        await sync.record(.mealCompleted(entryId: entryId))
        #expect(service.syncRequests.last?.trigger == .mealComplete)
        #expect(service.syncRequests.last?.entryId == entryId)
    }

    @Test func disabledCoachClearsItsNotificationsAndSkipsTheServer() async throws {
        let service = FakeCoachService(messages: [scheduled(minutes: 30)], now: { [now] in now })
        let center = RecordingCoachNotificationCenter()
        let stale = CoachNotificationPolicy.plan(
            rows: [CoachScheduledRow(message: scheduled(minutes: 40))],
            now: now,
            unreadCount: 0
        )
        center.seedPending(stale)
        let (sync, _) = try makeSync(service: service, enabled: false, center: center)
        let outcome = await sync.sync(trigger: .foreground)
        #expect(outcome == .disabled)
        #expect(center.pending.isEmpty)
        #expect(service.syncRequests.isEmpty)
    }

    @Test func notificationRepliesAreSentAndPostedImmediately() async throws {
        let service = FakeCoachService(now: { [now] in now })
        service.script = FakeCoachService.replyScript(reply: ["Good. ", "Now drink water."])
        let center = RecordingCoachNotificationCenter()
        let (sync, _) = try makeSync(service: service, center: center)
        let original = UUID()
        let request = CoachSendRequest(
            text: "Done with lunch",
            inputMode: .notificationReply,
            localDay: "2026-10-06",
            timezone: "America/New_York"
        )
        let replies = await sync.sendNotificationReply(request, inReplyTo: original, timeout: 5)
        #expect(replies.map(\.body) == ["Good. Now drink water."])
        #expect(service.sentRequests.map(\.inputMode) == [.notificationReply])
        #expect(service.markedReadIds == [original])
        #expect(center.delivered.count == 1)
        #expect(center.delivered.first?.fireAt == nil)
        #expect(center.delivered.first?.body == "Good. Now drink water.")
        #expect(await sync.snapshot.outbox.isEmpty)
    }

    @Test func failedRepliesStayInTheOutboxUntilAccepted() async throws {
        let service = FakeCoachService(now: { [now] in now })
        service.enqueueOverride([.fail(.server(statusCode: 503, code: nil, message: "Down"))])
        let center = RecordingCoachNotificationCenter()
        let (sync, _) = try makeSync(service: service, center: center)
        let request = CoachSendRequest(text: "On it", inputMode: .notificationReply, localDay: "2026-10-06", timezone: "UTC")
        let replies = await sync.sendNotificationReply(request, inReplyTo: nil, timeout: 5)
        #expect(replies.isEmpty)
        #expect(await sync.snapshot.outbox.map(\.request.clientRequestId) == [request.clientRequestId])

        await sync.flushOutbox()
        #expect(await sync.snapshot.outbox.isEmpty)
        #expect(service.sentRequests.map(\.clientRequestId) == [request.clientRequestId, request.clientRequestId])
    }

    @Test func streamCollectorStopsAtTheTimeoutButKeepsAcceptance() async {
        let service = FakeCoachService(now: { [now] in now })
        let request = CoachSendRequest(text: "Hey", localDay: "2026-10-06", timezone: "UTC")
        let user = CoachMessage(role: .user, kind: "text", body: "Hey", localDay: "2026-10-06", deliverAt: now, clientRequestId: request.clientRequestId)
        service.enqueueOverride([
            .event(.accepted(runId: UUID(), userMessage: user, duplicate: false)),
            .pause(milliseconds: 5_000),
            .event(.done(runId: nil, messageIds: [])),
        ])
        let started = Date()
        let result = await CoachStreamCollector.collect(service.send(request), localDay: "2026-10-06", timeout: 0.3)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(result.accepted)
        #expect(result.timedOut)
        #expect(!result.done)
        #expect(result.replies.isEmpty)
    }
}

final class CoachChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _days: [[String]] = []
    var days: [[String]] { lock.withLock { _days } }
    func append(_ days: [String]) { lock.withLock { _days.append(days) } }
}
