import Foundation
import Testing
import UserNotifications
@testable import shudo

/// Presentation and lifecycle rules for coach texts: quiet hours, styling
/// by kind, snoozes, badge renumbering and when iOS is asked for permission.
struct CoachNotificationPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_791_302_400) // 12:00 New York
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func row(_ minutesFromNow: Double, kind: String = "checkpoint") -> CoachScheduledRow {
        CoachScheduledRow(
            id: UUID(),
            kind: kind,
            localDay: "2026-10-06",
            deliverAt: now.addingTimeInterval(minutesFromNow * 60),
            status: .scheduled,
            notify: true,
            text: "Protein check."
        )
    }

    @Test func rowsInsideQuietHoursAreNotNotified() {
        var settings = CoachSettings.defaults
        settings.quietHoursStart = CoachClockTime(hour: 22, minute: 30)
        settings.quietHoursEnd = CoachClockTime(hour: 7, minute: 0)
        let afternoon = row(180)          // 15:00
        let lateNight = row(11 * 60)      // 23:00
        let earlyMorning = row(18 * 60)   // 06:00 next day
        let morning = row(19 * 60 + 30)   // 07:30 next day
        let rows = [afternoon, lateNight, earlyMorning, morning]

        let plan = CoachNotificationPolicy.plan(
            rows: rows, now: now, unreadCount: 0, quietHours: settings, timeZone: newYork
        )
        #expect(plan.map(\.messageId) == [afternoon.id, morning.id])
        #expect(plan.map(\.badge) == [1, 2], "badges skip the muted rows")
        // Without settings (nothing mirrored yet) every row is planned.
        #expect(CoachNotificationPolicy.plan(rows: rows, now: now, unreadCount: 0).count == 4)
    }

    @Test func textsThatAskSomethingRingAndTheRestLandQuietly() {
        for kind in ["checkpoint", "plan", "snack_rec", "text", "training_plan", "goal_change"] {
            #expect(CoachNotificationPolicy.interruption(for: kind) == .active, "\(kind)")
        }
        for kind in ["meal_ack", "workout_ack", "weigh_in_ack", "recap", "photo_feedback", "profile_update"] {
            #expect(CoachNotificationPolicy.interruption(for: kind) == .passive, "\(kind)")
        }
        #expect(CoachNotificationPolicy.interruption(for: "something_new") == .active)
        let ordered = ["snack_rec", "checkpoint", "plan", "training_plan", "recap", "meal_ack"]
            .map(CoachNotificationPolicy.relevance(for:))
        #expect(ordered == ordered.sorted(by: >))
        #expect(ordered.allSatisfy { $0 > 0 && $0 <= 1 })
    }

    @Test func contentIsATextFromShudoInOneThread() {
        let active = CoachNotificationPolicy.planned(row: row(30), fireAt: now.addingTimeInterval(1800), badge: 3)
        let content = CoachNotificationContent.make(active)
        #expect(content.title == "Shudo")
        #expect(content.subtitle.isEmpty)
        #expect(content.body == "Protein check.")
        #expect(content.threadIdentifier == "shudo.coach")
        #expect(content.interruptionLevel == .active)
        #expect(content.sound != nil)
        #expect(content.badge?.intValue == 3)
        #expect(content.relevanceScore == 0.8)
        #expect(content.targetContentIdentifier == active.messageId.uuidString.lowercased())

        let recap = CoachNotificationPolicy.planned(row: row(30, kind: "recap"), fireAt: nil, badge: nil)
        let quiet = CoachNotificationContent.make(recap)
        #expect(quiet.interruptionLevel == .passive)
        #expect(quiet.sound == nil, "passive texts never chime")
        #expect(quiet.badge == nil)
    }

    @Test func theChimeIsBundled() {
        let name = (CoachNotificationIdentifiers.soundName as NSString).deletingPathExtension
        #expect(Bundle.main.url(forResource: name, withExtension: "caf") != nil)
    }

    @Test func snoozedTextsKeepTheirContentUnderTheSnoozeIdentifier() {
        let id = UUID()
        let payload = CoachNotificationPayload(
            messageId: id, kind: "snack_rec", localDay: "2026-10-06", deepLink: nil,
            contentHash: "old", mapsQuery: "7-Eleven 2nd Ave", body: " 7-Eleven, 4 min. ",
            categoryIdentifier: CoachNotificationIdentifiers.snackCategory
        )
        let fireAt = now.addingTimeInterval(3600)
        let snoozed = CoachNotificationPolicy.snoozed(payload, messageId: id, fireAt: fireAt)
        #expect(snoozed.identifier == CoachNotificationIdentifiers.snooze(id))
        #expect(snoozed.fireAt == fireAt)
        #expect(snoozed.body == "7-Eleven, 4 min.")
        #expect(snoozed.badge == nil)
        #expect(snoozed.categoryIdentifier == CoachNotificationIdentifiers.snackCategory)
        #expect(snoozed.mapsQuery == "7-Eleven 2nd Ave")
        #expect(snoozed.interruption == .active)
        #expect(snoozed.deepLink == AppRouter.coachDeepLink(messageId: id, localDay: "2026-10-06"))
    }

    @Test func aLogDropsSnoozesDueSoonButNotOnesParkedUntilMorning() {
        let soon = CoachPendingRequest(identifier: CoachNotificationIdentifiers.snooze(UUID()), contentHash: nil,
                                       fireAt: now.addingTimeInterval(55 * 60))
        let morning = CoachPendingRequest(identifier: CoachNotificationIdentifiers.snooze(UUID()), contentHash: nil,
                                          fireAt: now.addingTimeInterval(9 * 3600))
        let unknown = CoachPendingRequest(identifier: CoachNotificationIdentifiers.snooze(UUID()), contentHash: nil)
        let message = CoachPendingRequest(identifier: CoachNotificationIdentifiers.message(UUID()), contentHash: "x",
                                          fireAt: now.addingTimeInterval(10 * 60))
        let ids = CoachNotificationPolicy.snoozesToCancelOnLog(pending: [soon, morning, unknown, message], now: now)
        #expect(ids == [soon.identifier])
    }

    @Test func snoozingClearsTheDeliveredOriginal() async {
        let center = RecordingCoachNotificationCenter()
        let scheduler = CoachNotificationScheduler(center: center)
        let id = UUID()
        let payload = CoachNotificationPayload(
            messageId: id, kind: "checkpoint", localDay: "2026-10-06", deepLink: nil, contentHash: nil,
            mapsQuery: nil, body: "Lunch.", categoryIdentifier: ""
        )
        await scheduler.snooze(payload, messageId: id, fireAt: now.addingTimeInterval(3600))
        #expect(center.removedDelivered == [CoachNotificationIdentifiers.message(id)])
        #expect(center.snoozes.map(\.identifier) == [CoachNotificationIdentifiers.snooze(id)])
        #expect(center.snoozes.first?.categoryIdentifier == CoachNotificationIdentifiers.textCategory)
    }

    @Test func immediateRepliesCountUpOnlyForWhatTheyPost() async {
        let center = RecordingCoachNotificationCenter()
        let scheduler = CoachNotificationScheduler(center: center)
        func reply(_ body: String, role: CoachRole = .coach) -> CoachMessage {
            CoachMessage(role: role, kind: "text", body: body, localDay: "2026-10-06", deliverAt: now)
        }
        await scheduler.presentImmediately(
            [reply("Good."), reply("echo", role: .user), reply("   "), reply("Now water.")],
            firstBadge: 4
        )
        #expect(center.delivered.map(\.body) == ["Good.", "Now water."])
        #expect(center.delivered.map(\.badge) == [4, 5])
    }

    @Test func passiveTextsOnlyJoinTheListInTheForeground() {
        #expect(CoachNotificationRouting.presentationOptions(isCoach: true, threadVisible: false, isPassive: true) == [.list])
        #expect(CoachNotificationRouting.presentationOptions(isCoach: true, threadVisible: true, isPassive: true) == [])
        #expect(CoachNotificationRouting.presentationOptions(isCoach: false, threadVisible: false, isPassive: true)
            == [.banner, .list, .sound])
    }

    @Test func actionsReadLikeMessages() {
        let categories = CoachNotificationCategories.make()
        let text = categories.first { $0.identifier == CoachNotificationIdentifiers.textCategory }
        let snack = categories.first { $0.identifier == CoachNotificationIdentifiers.snackCategory }
        #expect(text?.actions.map(\.title) == ["Reply", "On it", "Snooze 1 hour"])
        #expect(snack?.actions.map(\.title) == ["Directions", "Reply"])
        #expect(text?.actions.allSatisfy { $0.icon != nil } == true)
        #expect(snack?.actions.allSatisfy { $0.icon != nil } == true)
        #expect(text?.hiddenPreviewsBodyPlaceholder == "Shudo texted you")
        #expect(text?.options.contains(.hiddenPreviewsShowTitle) == true)
        let reply = text?.actions.first as? UNTextInputNotificationAction
        #expect(reply?.textInputButtonTitle == "Send")
    }
}

// MARK: - CoachSync lifecycle

struct CoachSyncNotificationLifecycleTests {
    private let now = Date(timeIntervalSince1970: 1_791_302_400)

    private func scheduled(minutes: Double, kind: String = "checkpoint") -> CoachMessage {
        CoachMessage(
            role: .coach,
            kind: kind,
            body: "Lunch check. Protein first.",
            rawPayload: .object(["push_body": .string("Lunch. Protein first.")]),
            localDay: "2026-10-06",
            deliverAt: now.addingTimeInterval(minutes * 60),
            status: .scheduled,
            notify: true,
            createdAt: now.addingTimeInterval(-600),
            updatedAt: now.addingTimeInterval(-60)
        )
    }

    private func delivered(minutesAgo: Double) -> CoachMessage {
        CoachMessage(
            role: .coach, kind: "text", body: "Morning.", localDay: "2026-10-06",
            deliverAt: now.addingTimeInterval(-minutesAgo * 60), updatedAt: now.addingTimeInterval(-30)
        )
    }

    private func makeSync(
        service: FakeCoachService,
        center: RecordingCoachNotificationCenter,
        enabled: Bool = true
    ) -> CoachSync {
        let mirror = CoachSettingsMirror(suiteName: "shudo.tests.coach-lifecycle.\(UUID().uuidString)")
        var settings = CoachSettings.defaults
        settings.enabled = enabled
        mirror.save(settings, at: now)
        let fixedNow = now
        return CoachSync(
            service: service,
            scheduler: CoachNotificationScheduler(center: center),
            store: InMemoryCoachSyncStateStore(),
            mirror: mirror,
            environment: CoachSyncEnvironment(
                now: { fixedNow },
                timeZone: { TimeZone(identifier: "America/New_York")! },
                userId: { "11111111-2222-3333-4444-555555555555" },
                device: {
                    CoachSyncRequest.Device(
                        deviceId: UUID(), appVersion: "2.0 (1)", osVersion: "26.5",
                        notificationStatus: .notDetermined, locationStatus: .notDetermined
                    )
                },
                locationContext: { _ in nil },
                postThreadChange: { _ in }
            )
        )
    }

    private func badges(_ center: RecordingCoachNotificationCenter) -> [Int?] {
        center.pending.values
            .filter { $0.identifier.hasPrefix(CoachNotificationIdentifiers.messagePrefix) }
            .sorted { ($0.fireAt ?? .distantPast) < ($1.fireAt ?? .distantPast) }
            .map(\.badge)
    }

    @Test func readingTheThreadRenumbersPendingBadges() async {
        let service = FakeCoachService(
            messages: [delivered(minutesAgo: 30), delivered(minutesAgo: 20), scheduled(minutes: 60), scheduled(minutes: 120)],
            now: { [now] in now }
        )
        let center = RecordingCoachNotificationCenter()
        let sync = makeSync(service: service, center: center)
        await sync.sync(trigger: .foreground)
        #expect(badges(center) == [3, 4])

        // Luke reads both delivered texts in the app.
        await sync.updateUnreadCount(0)
        #expect(badges(center) == [1, 2], "the next text must not show a stale 3")
        #expect(center.badge == 0)
        #expect(await sync.snapshot.unreadCount == 0)
    }

    @Test func onItMarksReadAndRenumbers() async {
        let first = delivered(minutesAgo: 30)
        let service = FakeCoachService(messages: [first, scheduled(minutes: 60)], now: { [now] in now })
        let center = RecordingCoachNotificationCenter()
        let sync = makeSync(service: service, center: center)
        await sync.sync(trigger: .foreground)
        #expect(badges(center) == [2])

        await sync.markRead([first.id])
        #expect(service.markedReadIds == [first.id])
        #expect(center.removedDelivered.contains(CoachNotificationIdentifiers.message(first.id)))
        #expect(badges(center) == [1])
        #expect(center.badge == 0)
    }

    @Test func aLockScreenReplyCountsTowardLaterBadges() async {
        let service = FakeCoachService(messages: [scheduled(minutes: 60)], now: { [now] in now })
        service.script = FakeCoachService.replyScript(reply: ["Good. ", "Water next."])
        let center = RecordingCoachNotificationCenter()
        let sync = makeSync(service: service, center: center)
        await sync.sync(trigger: .foreground)
        #expect(badges(center) == [1])

        let request = CoachSendRequest(
            text: "Had a shake", inputMode: .notificationReply, localDay: "2026-10-06", timezone: "America/New_York"
        )
        await sync.sendNotificationReply(request, inReplyTo: nil, timeout: 5)
        #expect(center.delivered.map(\.badge) == [1])
        #expect(badges(center) == [2], "the pending text now sits behind the reply")
        #expect(center.badge == 1)
    }

    @Test func aLogAlsoDropsASnoozeDueSoon() async {
        let soon = scheduled(minutes: 20)
        let service = FakeCoachService(messages: [soon], now: { [now] in now })
        let center = RecordingCoachNotificationCenter()
        let sync = makeSync(service: service, center: center)
        await sync.sync(trigger: .foreground)
        let payload = CoachNotificationPayload(
            messageId: UUID(), kind: "checkpoint", localDay: "2026-10-06", deepLink: nil, contentHash: nil,
            mapsQuery: nil, body: "Earlier text.", categoryIdentifier: ""
        )
        let snoozedId = payload.messageId!
        await CoachNotificationScheduler(center: center)
            .snooze(payload, messageId: snoozedId, fireAt: now.addingTimeInterval(3600))
        #expect(center.snoozes.count == 1)

        await sync.cancelUpcomingAfterLog()
        #expect(center.snoozes.isEmpty)
        #expect(center.pending[CoachNotificationIdentifiers.message(soon.id)] == nil)
    }

    /// Postgres stamps `updated_at` with the transaction start: a plan run
    /// can commit rows stamped *before* a row the client already read.
    @Test func aLateCommittedPlanBehindTheCursorIsStillScheduled() async {
        let chat = delivered(minutesAgo: 1)  // updated_at now-30s
        let service = FakeCoachService(messages: [chat], now: { [now] in now })
        let center = RecordingCoachNotificationCenter()
        let sync = makeSync(service: service, center: center)
        #expect(await sync.sync(trigger: .foreground) == .synced(changed: 1, generated: false))

        var late = scheduled(minutes: 90)
        late.updatedAt = now.addingTimeInterval(-45) // committed late, stamped early
        service.insert(late)
        let outcome = await sync.sync(trigger: .foreground)
        #expect(outcome == .synced(changed: 1, generated: false), "the re-read chat row isn't a change")
        #expect(center.pending[CoachNotificationIdentifiers.message(late.id)] != nil)

        // Nothing new: nothing reported.
        #expect(await sync.sync(trigger: .foreground) == .synced(changed: 0, generated: false))
    }

    @Test func quietHoursFromTheMirrorApplyOnReconcile() async {
        // 12:00 New York; default quiet hours are 23:00–07:00.
        let evening = scheduled(minutes: 8 * 60)        // 20:00
        let midnight = scheduled(minutes: 12 * 60 + 30) // 00:30
        let service = FakeCoachService(messages: [evening, midnight], now: { [now] in now })
        let center = RecordingCoachNotificationCenter()
        let sync = makeSync(service: service, center: center)
        await sync.sync(trigger: .foreground)
        #expect(Set(center.pending.keys) == [CoachNotificationIdentifiers.message(evening.id)])
    }

    @Test func appOpenAsksForPermissionOnceWhenTheCoachIsOn() async {
        let service = FakeCoachService(messages: [scheduled(minutes: 60)], now: { [now] in now })
        let center = RecordingCoachNotificationCenter()
        center.status = .notDetermined
        let sync = makeSync(service: service, center: center)

        // Syncs after a log never interrupt with a prompt.
        await sync.sync(trigger: .foreground)
        #expect(center.authorizationRequests == 0)
        #expect(center.pending.isEmpty)

        await sync.handleForeground()
        #expect(center.authorizationRequests == 1)
        #expect(service.syncRequests.last?.device.notificationStatus == .authorized)
        #expect(center.pending.count == 1)

        // Already answered: never asked again.
        await sync.sync(trigger: .foreground, promptsForNotifications: true)
        #expect(center.authorizationRequests == 1)
    }

    @Test func aDeclinedPromptIsReportedAndNothingIsScheduled() async {
        let service = FakeCoachService(messages: [scheduled(minutes: 60)], now: { [now] in now })
        let center = RecordingCoachNotificationCenter()
        center.status = .notDetermined
        center.grantsAuthorization = false
        let sync = makeSync(service: service, center: center)
        await sync.handleForeground()
        #expect(service.syncRequests.last?.device.notificationStatus == .denied)
        #expect(center.pending.isEmpty)
    }

    @Test func aDisabledCoachNeverPrompts() async {
        let service = FakeCoachService(now: { [now] in now })
        let center = RecordingCoachNotificationCenter()
        center.status = .notDetermined
        let sync = makeSync(service: service, center: center, enabled: false)
        #expect(await sync.handleForeground() == .disabled)
        #expect(center.authorizationRequests == 0)
    }
}
