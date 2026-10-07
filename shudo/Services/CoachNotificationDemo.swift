#if DEBUG
import Foundation
import UIKit
import UserNotifications

/// `-shudoNotificationDemo` (DEBUG only): proves coach texts end to end on a
/// simulator with no backend. `CoachSync.shared` becomes a demo instance
/// whose server is a `FakeCoachService` (shared with the PolishPreview
/// thread), but whose scheduler is the REAL one, posting to the real
/// `UNUserNotificationCenter`.
///
/// On launch it asks for notification permission, runs a self-check against
/// the real pending requests (plan, badges, re-sync, relaunch, supersede,
/// unread renumbering, snooze, cancel-on-log, quiet hours), then schedules
/// four believable texts a few seconds out so the banner, the grouped stack
/// and the long-look with Reply can be screenshotted.
///
///     simctl launch <udid> luke.shudo -shudoPolishPreview main \
///       -shudoNotificationDemo [-shudoNotificationDemoDelay 15]
///
/// The report prints as `[notification-demo] …` lines and is written to
/// `Documents/notification-demo.txt` in the app container.
///
/// Clock: the PolishPreview day is pinned to 7:40 PM New York, so the fake
/// server, CoachSync and the thread all run on that clock, and the only
/// translation to wall time is at the notification center
/// (`PreviewClockNotificationCenter`): a text due at "7:41 PM" fires a minute
/// from now and lands at the bottom of the thread as it does.
enum CoachNotificationDemo {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-shudoNotificationDemo")
    }

    /// Seconds from the app going to the background to the first demo text
    /// (the texts are scheduled then, so they always arrive as banners).
    static var deliveryDelay: TimeInterval {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-shudoNotificationDemoDelay"),
              arguments.indices.contains(flag + 1),
              let seconds = TimeInterval(arguments[flag + 1]) else { return 8 }
        return max(3, seconds)
    }

    static let userId = ShellPreviewFixtures.userId

    static var timeZone: TimeZone {
        TimeZone(identifier: ShellPreviewFixtures.timezone) ?? .autoupdatingCurrent
    }

    /// The preview day's clock (7:40 PM, advancing in real time).
    static func clock() -> Date { ShellPreviewFixtures.now() }

    /// Coach on, quiet hours 1–3 AM: the evening demo texts ring, and the
    /// self-check still has a quiet window to test.
    static let settings: CoachSettings = {
        var settings = CoachSettings.defaults
        settings.enabled = true
        settings.quietHoursStart = CoachClockTime(hour: 1, minute: 0)
        settings.quietHoursEnd = CoachClockTime(hour: 3, minute: 0)
        return settings
    }()

    static let service = FakeCoachService(
        messages: ShellPreviewFixtures.messages(),
        memory: ShellPreviewFixtures.memory,
        settings: settings,
        stepDelayMilliseconds: 90,
        now: { CoachNotificationDemo.clock() },
        script: FakeCoachService.replyScript(
            reply: ["Good. ", "That shake puts you at 158g. ", "A yogurt before bed and you’re there."]
        )
    )

    static let store = InMemoryCoachSyncStateStore()
    static let mirror = CoachSettingsMirror(suiteName: "shudo.notification-demo")

    static let scheduler = CoachNotificationScheduler(center: PreviewClockNotificationCenter())

    static var environment: CoachSyncEnvironment {
        CoachSyncEnvironment(
            now: { CoachNotificationDemo.clock() },
            timeZone: { CoachNotificationDemo.timeZone },
            userId: { CoachNotificationDemo.userId },
            device: {
                CoachSyncRequest.Device(
                    deviceId: CoachDeviceIdentity.deviceId(),
                    appVersion: CoachDeviceIdentity.appVersion(),
                    osVersion: CoachDeviceIdentity.osVersion(),
                    notificationStatus: .notDetermined,
                    locationStatus: .notDetermined
                )
            },
            locationContext: { _ in nil },
            postThreadChange: CoachSyncEnvironment.live.postThreadChange
        )
    }

    static func makeSharedSync() -> CoachSync? {
        guard isEnabled else { return nil }
        mirror.save(settings, at: clock())
        return CoachSync(
            service: service,
            scheduler: scheduler,
            store: store,
            mirror: mirror,
            environment: environment
        )
    }

    static func startIfRequested() {
        guard isEnabled else { return }
        Task { await run() }
        // Each return to the app: what iOS still shows in Notification Center.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { await logDelivered() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            log("entered background")
        }
    }

    /// Timestamped trace (stdout + `Documents/notification-demo-log.txt`).
    static func log(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "\(formatter.string(from: Date())) \(text)"
        print("[notification-demo] \(line)")
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("notification-demo-log.txt") else { return }
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static func logDelivered() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
            .filter { $0.request.identifier.hasPrefix(CoachNotificationIdentifiers.ownedPrefix) }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let lines = delivered.map { "\($0.request.identifier.suffix(8)) \(formatter.string(from: $0.date))" }
        log("active; delivered: \(lines)")
    }

    // MARK: Run

    private static func run() async {
        if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: url.appendingPathComponent("notification-demo-log.txt"))
        }
        let report = Report()
        let status = await scheduler.requestAuthorizationIfNeeded()
        report.line("authorization: \(status.rawValue)")
        guard status == .authorized || status == .provisional else {
            report.line("FAIL notifications are not authorized; nothing to show")
            report.write()
            return
        }
        // A clean Notification Center for the screenshots.
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        await selfCheck(report)
        report.write()
        // The show waits for Home, so the texts land as banners.
        let backgroundTask = await Backgrounding.shared.wait()
        await scheduleShow(report)
        report.write()
        await Backgrounding.shared.end(backgroundTask)
    }

    /// Resolves once the app is in the background, holding a background
    /// task so scheduling finishes before suspension.
    @MainActor
    private final class Backgrounding {
        static let shared = Backgrounding()
        private var waiters: [CheckedContinuation<UIBackgroundTaskIdentifier, Never>] = []

        private init() {
            NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { Backgrounding.shared.resume() }
            }
        }

        func wait() async -> UIBackgroundTaskIdentifier {
            if UIApplication.shared.applicationState == .background {
                return UIApplication.shared.beginBackgroundTask(withName: "notification-demo")
            }
            return await withCheckedContinuation { waiters.append($0) }
        }

        func end(_ task: UIBackgroundTaskIdentifier) {
            guard task != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task)
        }

        private func resume() {
            let pending = waiters
            waiters = []
            for waiter in pending {
                waiter.resume(returning: UIApplication.shared.beginBackgroundTask(withName: "notification-demo"))
            }
        }
    }

    // MARK: Self-check

    private static func selfCheck(_ report: Report) async {
        let sync = CoachSync.shared
        let now = clock()
        let day = CoachLocalDay.string(for: now, timeZone: timeZone)
        let quietStart = nextOccurrence(of: settings.quietHoursStart, after: now)
            .addingTimeInterval(30 * 60)

        let lunch = row("checkpoint", "Lunch window. Make it 50g protein, not a salad.", day, now + 30 * 60)
        let snack = snackRow("7-Eleven is 4 min away. Chobani + Core Power = 67g protein.", day, now + 100 * 60)
        let banter = row("text", "Upper A at 6:15. Bench moved 185×5 last week. Go for 6.", day, now + 160 * 60)
        let recap = row("recap", "Day closed: 171g protein, 2,850 kcal.", day, now + 200 * 60)
        let quiet = row("checkpoint", "This one lands in quiet hours.", day, quietStart)
        let silent = row("checkpoint", "In the thread only.", day, now + 40 * 60, notify: false)
        for message in [lunch, snack, banter, recap, quiet, silent] { service.insert(message) }

        // 1. Plan
        await sync.sync(trigger: .foreground)
        var pending = await coachPending()
        let messageIds = Set(pending.keys.filter { $0.hasPrefix(CoachNotificationIdentifiers.messagePrefix) })
        let expected = Set([lunch, snack, banter, recap].map { CoachNotificationIdentifiers.message($0.id) })
        report.check("plan: future texts scheduled; quiet-hours and notify=false rows skipped",
                     messageIds == expected, "got \(messageIds.count) of \(expected.count)")

        // 2. Badges count up from unread, in delivery order.
        let unread = (try? await service.fetchUnreadCount()) ?? 0
        let badges = [lunch, snack, banter, recap].compactMap {
            pending[CoachNotificationIdentifiers.message($0.id)]?.content.badge?.intValue
        }
        report.check("badges: \(badges) count up from unread \(unread)",
                     badges == Array((unread + 1)...(unread + 4)))

        // 3. Content
        if let text = pending[CoachNotificationIdentifiers.message(lunch.id)]?.content,
           let card = pending[CoachNotificationIdentifiers.message(snack.id)]?.content,
           let quietOne = pending[CoachNotificationIdentifiers.message(recap.id)]?.content {
            let link = (text.userInfo["shudo"] as? [String: Any])?["deep_link"] as? String
            let destination = link.flatMap(URL.init(string:)).flatMap(AppRouter.coachDestination(for:))
            report.check("content: title Shudo, no subtitle, one thread, chime, active",
                         text.title == "Shudo" && text.subtitle.isEmpty
                            && text.threadIdentifier == CoachNotificationIdentifiers.threadIdentifier
                            && text.sound != nil && text.interruptionLevel == .active
                            && text.categoryIdentifier == CoachNotificationIdentifiers.textCategory)
            report.check("content: deep link opens the thread at that message",
                         destination == .thread(messageId: lunch.id, localDay: day), link ?? "nil")
            report.check("content: snack rec gets Directions category, top relevance",
                         card.categoryIdentifier == CoachNotificationIdentifiers.snackCategory
                            && abs(card.relevanceScore - 0.9) < 0.001,
                         "\(card.categoryIdentifier) \(card.relevanceScore)")
            report.check("content: recap is passive and silent",
                         quietOne.interruptionLevel == .passive && quietOne.sound == nil)
        } else {
            report.line("FAIL content: expected requests missing")
        }

        // 4. Re-sync and relaunch add nothing.
        let before = hashes(pending)
        await sync.sync(trigger: .foreground)
        pending = await coachPending()
        report.check("re-sync: same \(before.count) requests, same content (no duplicates)",
                     hashes(pending) == before)
        let relaunched = CoachSync(service: service, scheduler: scheduler, store: store, mirror: mirror, environment: environment)
        await relaunched.sync(trigger: .foreground)
        pending = await coachPending()
        report.check("relaunch: a fresh CoachSync re-plans to the identical set", hashes(pending) == before)

        // 5. Server supersedes a text.
        var superseded = recap
        superseded.status = .superseded
        superseded.updatedAt = clock()
        service.insert(superseded)
        await sync.sync(trigger: .foreground)
        pending = await coachPending()
        report.check("supersede: withdrawn text removed, the rest untouched",
                     pending[CoachNotificationIdentifiers.message(recap.id)] == nil
                        && pending[CoachNotificationIdentifiers.message(lunch.id)] != nil)

        // 6. Reading the thread renumbers pending badges.
        await sync.updateUnreadCount(0)
        pending = await coachPending()
        let renumbered = [lunch, snack, banter].compactMap {
            pending[CoachNotificationIdentifiers.message($0.id)]?.content.badge?.intValue
        }
        report.check("unread → 0: pending badges renumbered \(renumbered)", renumbered == [1, 2, 3])
        await sync.updateUnreadCount(unread)

        // 7. Snooze reposts an hour out.
        let payload = CoachNotificationPayload(
            messageId: banter.id, kind: banter.kind, localDay: day, deepLink: banter.deepLink,
            contentHash: nil, mapsQuery: nil, body: banter.notificationText,
            categoryIdentifier: CoachNotificationIdentifiers.textCategory
        )
        await scheduler.snooze(payload, messageId: banter.id, fireAt: clock() + 3600)
        pending = await coachPending()
        let snoozeFire = (pending[CoachNotificationIdentifiers.snooze(banter.id)]?.trigger as? UNCalendarNotificationTrigger)?
            .nextTriggerDate()
        report.check("snooze: reposted ~1 h out",
                     snoozeFire.map { abs($0.timeIntervalSinceNow - 3600) < 120 } ?? false)

        // 8. Logging a meal mutes texts due within 45 min, and soon snoozes.
        await sync.cancelUpcomingAfterLog()
        await sync.reconcileNotifications()
        pending = await coachPending()
        report.check("cancel-on-log: +30 min text and the snooze muted; +100 min kept",
                     pending[CoachNotificationIdentifiers.message(lunch.id)] == nil
                        && pending[CoachNotificationIdentifiers.snooze(banter.id)] == nil
                        && pending[CoachNotificationIdentifiers.message(snack.id)] != nil)

        // 9. Clean up for the show.
        for var message in [lunch, snack, banter, quiet, silent] {
            message.status = .superseded
            message.updatedAt = clock()
            service.insert(message)
        }
        await sync.sync(trigger: .foreground)
        pending = await coachPending()
        report.check("cleanup: every self-check request withdrawn", pending.isEmpty, "\(pending.count) left")
    }

    // MARK: Show

    private static func scheduleShow(_ report: Report) async {
        let start = clock().addingTimeInterval(deliveryDelay)
        let day = CoachLocalDay.string(for: start, timeZone: timeZone)
        let texts = [
            row("checkpoint", "62g of protein to go before 9. Greek yogurt and a shake closes it.", day, start),
            snackRow("7-Eleven is 4 min away. Chobani + Core Power = 67g protein. Walk over?", day, start + 10),
            row("text", "Upper A at 6:15. Bench moved 185×5 last week. Go for 6.", day, start + 20),
            row("recap", "Day closed: 171g protein, 2,850 kcal. Bed by 11 and we go again.", day, start + 30),
        ]
        for message in texts { service.insert(message) }
        await CoachSync.shared.sync(trigger: .foreground)
        let pending = await coachPending()
        let unread = await CoachSync.shared.snapshot.unreadCount
        report.line("show: unread \(unread) before the texts")
        for message in texts {
            let request = pending[CoachNotificationIdentifiers.message(message.id)]
            let badge = request?.content.badge.map { "badge \($0)" } ?? "-"
            report.line("\(request != nil ? "show" : "FAIL show") +\(Int(message.deliverAt.timeIntervalSince(clock())))s \(message.id.uuidString.lowercased().suffix(8)) \(badge) \(message.kind): \(message.notificationText)")
        }
    }

    // MARK: Fixtures

    private static func row(
        _ kind: String,
        _ text: String,
        _ day: String,
        _ deliverAt: Date,
        notify: Bool = true
    ) -> CoachMessage {
        CoachMessage(
            role: .coach,
            kind: kind,
            body: text,
            rawPayload: .object(["push_body": .string(text)]),
            localDay: day,
            deliverAt: deliverAt,
            status: .scheduled,
            notify: notify,
            createdAt: clock(),
            updatedAt: clock()
        )
    }

    private static func snackRow(_ text: String, _ day: String, _ deliverAt: Date) -> CoachMessage {
        let card = CoachFixtures.snackRec(localDay: day, at: deliverAt)
        var payload = card.rawPayload.objectValue ?? [:]
        payload["push_body"] = .string(text)
        return CoachMessage(
            role: .coach,
            kind: CoachMessageKind.snackRec.rawValue,
            body: card.body,
            rawPayload: .object(payload),
            localDay: day,
            deliverAt: deliverAt,
            status: .scheduled,
            notify: true,
            createdAt: clock(),
            updatedAt: clock()
        )
    }

    private static func nextOccurrence(of time: CoachClockTime, after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let candidate = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: date) ?? date
        return candidate > date ? candidate : candidate.addingTimeInterval(24 * 3600)
    }

    // MARK: Clock translation

    /// The real notification center, with fire dates translated between the
    /// preview clock and wall time. Everything else passes straight through.
    struct PreviewClockNotificationCenter: CoachNotificationCenter {
        private let base = LiveCoachNotificationCenter()
        /// preview time − wall time
        private var offset: TimeInterval { CoachNotificationDemo.clock().timeIntervalSince(Date()) }

        func pendingCoachRequests() async -> [CoachPendingRequest] {
            let offset = offset
            return await base.pendingCoachRequests().map {
                CoachPendingRequest(
                    identifier: $0.identifier,
                    contentHash: $0.contentHash,
                    fireAt: $0.fireAt.map { $0 + offset }
                )
            }
        }

        func add(_ notification: PlannedCoachNotification) async {
            let n = notification
            await base.add(PlannedCoachNotification(
                messageId: n.messageId, identifier: n.identifier,
                fireAt: n.fireAt.map { $0 - offset },
                title: n.title, body: n.body, badge: n.badge,
                categoryIdentifier: n.categoryIdentifier, kind: n.kind, localDay: n.localDay,
                mapsQuery: n.mapsQuery, interruption: n.interruption, relevance: n.relevance,
                contentHash: n.contentHash
            ))
        }

        func removePending(identifiers: [String]) async { await base.removePending(identifiers: identifiers) }
        func removeDelivered(identifiers: [String]) async { await base.removeDelivered(identifiers: identifiers) }
        func setBadgeCount(_ count: Int) async { await base.setBadgeCount(count) }
        func authorizationStatus() async -> CoachSyncRequest.NotificationStatus { await base.authorizationStatus() }
        func requestAuthorization() async -> Bool { await base.requestAuthorization() }
    }

    // MARK: Real-center inspection

    private static func coachPending() async -> [String: UNNotificationRequest] {
        // Removals are queued; give the center a beat before reading back.
        try? await Task.sleep(nanoseconds: 200_000_000)
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return Dictionary(
            requests
                .filter { $0.identifier.hasPrefix(CoachNotificationIdentifiers.ownedPrefix) }
                .map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func hashes(_ pending: [String: UNNotificationRequest]) -> [String: String] {
        pending.mapValues { CoachNotificationPayload(userInfo: $0.content.userInfo)?.contentHash ?? "" }
    }

    private final class Report: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func line(_ text: String) {
            CoachNotificationDemo.log(text)
            lock.withLock { lines.append(text) }
        }

        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            line("\(passed ? "PASS" : "FAIL") \(name)\(passed || detail.isEmpty ? "" : " — \(detail)")")
        }

        func write() {
            let text = lock.withLock { lines.joined(separator: "\n") } + "\n"
            guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("notification-demo.txt") else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
#endif
