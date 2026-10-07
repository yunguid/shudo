import BackgroundTasks
import Foundation

// Keeps local notifications in step with the server's coach queue
// (SPEC §3.2, §5.4): `coach_sync` on foreground, after logs and on
// background refresh; then `coach_messages` changed since the cursor are
// folded into a persisted upcoming set and diff-reconciled.

// MARK: - Settings mirror

/// Offline mirror of the coach settings (profiles columns). Other code reads
/// it synchronously — e.g. DayNotifications only schedules its fallback
/// nudges while the coach is disabled.
struct CoachSettingsMirror: Sendable {
    static let settingsKey = "shudo.coach.settings.v1"
    static let fetchedAtKey = "shudo.coach.settings.fetchedAt"

    let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func load() -> CoachSettings? {
        guard let data = defaults.data(forKey: Self.settingsKey) else { return nil }
        return try? JSONDecoder().decode(CoachSettings.self, from: data)
    }

    func fetchedAt() -> Date? {
        defaults.object(forKey: Self.fetchedAtKey) as? Date
    }

    func save(_ settings: CoachSettings, at date: Date) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
        defaults.set(date, forKey: Self.fetchedAtKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.settingsKey)
        defaults.removeObject(forKey: Self.fetchedAtKey)
    }

    static func isCoachEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(CoachSettings.self, from: data) else {
            return false
        }
        return settings.enabled
    }
}

// MARK: - Persisted state

struct CoachSyncState: Codable, Equatable, Sendable {
    var userId: String?
    var cursor: Date?
    /// Future `scheduled` + `notify` coach rows the server has told us about.
    var rows: [CoachScheduledRow] = []
    /// Rows locally cancelled by a log, until their delivery time passes.
    var suppressed: [UUID: Date] = [:]
    var unreadCount = 0
    var lastSyncAt: Date?
    var lastForegroundSyncAt: Date?
    /// Lock-screen replies not yet accepted by the server.
    var outbox: [CoachOutboxItem] = []

    static let empty = CoachSyncState()
}

struct CoachOutboxItem: Codable, Equatable, Sendable {
    var request: CoachSendRequest
    var enqueuedAt: Date
    var attempts: Int
}

protocol CoachSyncStateStore: Sendable {
    func load() -> CoachSyncState?
    func save(_ state: CoachSyncState)
}

/// JSON file in Application Support, protected until first unlock (so a
/// background refresh or lock-screen reply can still read it).
struct FileCoachSyncStateStore: CoachSyncStateStore {
    let fileName: String

    init(fileName: String = "coach-sync.json") {
        self.fileName = fileName
    }

    private var url: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Coach", isDirectory: true).appendingPathComponent(fileName)
    }

    func load() -> CoachSyncState? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CoachSyncState.self, from: data)
    }

    func save(_ state: CoachSyncState) {
        guard let url, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

final class InMemoryCoachSyncStateStore: CoachSyncStateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: CoachSyncState?

    init(_ state: CoachSyncState? = nil) {
        self.state = state
    }

    func load() -> CoachSyncState? { lock.withLock { state } }
    func save(_ state: CoachSyncState) { lock.withLock { self.state = state } }
}

// MARK: - Environment

struct CoachSyncEnvironment: Sendable {
    var now: @Sendable () -> Date
    var timeZone: @Sendable () -> TimeZone
    var userId: @Sendable () -> String?
    var device: @Sendable () async -> CoachSyncRequest.Device
    /// Nearby-store context when the user enabled it (nil otherwise).
    var locationContext: @Sendable (_ maxAge: TimeInterval) async -> LocationContext?
    var postThreadChange: @Sendable (_ localDays: [String]) -> Void

    static let live = CoachSyncEnvironment(
        now: { Date() },
        timeZone: { .autoupdatingCurrent },
        userId: { AuthSessionManager.shared.userId },
        device: {
            let locationStatus = await MainActor.run { LocationFixProvider.shared.authorization.syncStatus }
            return CoachSyncRequest.Device(
                deviceId: CoachDeviceIdentity.deviceId(),
                appVersion: CoachDeviceIdentity.appVersion(),
                osVersion: CoachDeviceIdentity.osVersion(),
                notificationStatus: .notDetermined,
                locationStatus: locationStatus
            )
        },
        locationContext: { maxAge in
            await NearbyStoreScout.shared.contextIfEnabled(maxAge: maxAge, refreshIfStale: true)
        },
        postThreadChange: { days in
            Task { @MainActor in
                NotificationCenter.default.post(
                    name: .coachThreadDidChange,
                    object: nil,
                    userInfo: ["local_days": days]
                )
            }
        }
    )
}

enum CoachDeviceIdentity {
    static let deviceIdKey = "shudo.coach.deviceId"

    static func deviceId(defaults: UserDefaults = .standard) -> UUID {
        if let raw = defaults.string(forKey: deviceIdKey), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: deviceIdKey)
        return id
    }

    static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return String("\(version) (\(build))".prefix(32))
    }

    static func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion)"
    }
}

// MARK: - Stream collection (lock-screen replies)

enum CoachStreamCollector {
    struct Result: Equatable, Sendable {
        var accepted = false
        var done = false
        var userMessage: CoachMessage?
        /// Finished coach messages, in arrival order.
        var replies: [CoachMessage] = []
        var failure: CoachStreamFailure?
        var transportFailed = false
        var transportRetryable = true
        var timedOut = false
    }

    private actor Accumulator {
        var result = Result()
        var partial: [UUID: String] = [:]
        var order: [UUID] = []

        func apply(_ event: CoachStreamEvent, localDay: String, now: Date) {
            switch event {
            case .accepted(_, let user, _):
                result.accepted = true
                result.userMessage = user
            case .delta(let id, let text):
                if partial[id] == nil { order.append(id) }
                partial[id, default: ""] += text
            case .message(let message):
                guard message.role == .coach else { return }
                result.replies.removeAll { $0.id == message.id }
                result.replies.append(message)
            case .done(_, let ids):
                result.done = true
                // A streamed bubble whose final row never arrived.
                for id in order + ids where !result.replies.contains(where: { $0.id == id }) {
                    guard let text = partial[id], !text.isEmpty else { continue }
                    result.replies.append(CoachMessage(
                        id: id,
                        role: .coach,
                        kind: CoachMessageKind.text.rawValue,
                        body: text,
                        localDay: localDay,
                        deliverAt: now
                    ))
                }
            case .error(let failure):
                result.failure = failure
            case .status:
                break
            }
        }

        func markTransport(retryable: Bool) {
            result.transportFailed = true
            result.transportRetryable = retryable
        }

        func markTimedOut() { result.timedOut = true }
        func snapshot() -> Result { result }
    }

    /// Drains a send stream until `done`, an error, or `timeout`.
    static func collect(
        _ stream: AsyncThrowingStream<CoachStreamEvent, Error>,
        localDay: String,
        timeout: TimeInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> Result {
        let accumulator = Accumulator()
        let consumer = Task {
            do {
                for try await event in stream {
                    await accumulator.apply(event, localDay: localDay, now: now())
                    if case .done = event { break }
                }
            } catch {
                await accumulator.markTransport(retryable: CoachServiceError.isRetryable(error))
            }
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            if !Task.isCancelled {
                await accumulator.markTimedOut()
                consumer.cancel()
            }
        }
        await consumer.value
        timer.cancel()
        return await accumulator.snapshot()
    }
}

// MARK: - Sync actor

enum CoachSyncOutcome: Equatable, Sendable {
    case signedOut
    case disabled
    case throttled
    case synced(changed: Int, generated: Bool)
    case failed(String)
}

actor CoachSync {
    static let backgroundRefreshIdentifier = "luke.shudo.coach.refresh"
    static let foregroundThrottle: TimeInterval = 90
    static let settingsMaxAge: TimeInterval = 6 * 3600
    static let locationMaxAge: TimeInterval = 20 * 60
    static let outboxMaxAge: TimeInterval = 24 * 3600

    static let shared = CoachSync(
        service: CoachService.live,
        scheduler: .live,
        store: FileCoachSyncStateStore(),
        mirror: CoachSettingsMirror(),
        environment: .live
    )

    /// Things Luke did in the app that make near-term coach texts stale.
    enum LocalEvent: Equatable, Sendable {
        /// A meal was submitted (analysis still running).
        case mealLogged
        /// A meal finished analysis.
        case mealCompleted(entryId: UUID)
        case activityLogged
        case activityCompleted(activityId: UUID)
        case checkInLogged
        case settingsChanged
    }

    private let service: any CoachServing
    private let scheduler: CoachNotificationScheduler
    private let store: any CoachSyncStateStore
    private let mirror: CoachSettingsMirror
    private let environment: CoachSyncEnvironment
    private var state: CoachSyncState
    private var tail: Task<Void, Never>?
    private var queuedForegroundSync = false

    init(
        service: any CoachServing,
        scheduler: CoachNotificationScheduler,
        store: any CoachSyncStateStore,
        mirror: CoachSettingsMirror,
        environment: CoachSyncEnvironment
    ) {
        self.service = service
        self.scheduler = scheduler
        self.store = store
        self.mirror = mirror
        self.environment = environment
        self.state = store.load() ?? .empty
    }

    var snapshot: CoachSyncState { state }

    // MARK: Entry points

    /// App became active. Throttled so tab hops don't hammer the server.
    @discardableResult
    func handleForeground() async -> CoachSyncOutcome {
        await flushOutbox()
        let now = environment.now()
        if let last = state.lastForegroundSyncAt, now.timeIntervalSince(last) < Self.foregroundThrottle {
            await reconcileNotifications()
            return .throttled
        }
        guard !queuedForegroundSync else { return .throttled }
        queuedForegroundSync = true
        defer { queuedForegroundSync = false }
        state.lastForegroundSyncAt = now
        return await sync(trigger: .foreground, wait: true)
    }

    @discardableResult
    func handleBackgroundRefresh() async -> CoachSyncOutcome {
        Self.scheduleAppRefresh()
        await flushOutbox()
        return await sync(trigger: .bgRefresh, wait: true)
    }

    /// Call right after a log lands locally (SPEC §5.4 cancel-on-log), and
    /// again when analysis completes.
    func record(_ event: LocalEvent) async {
        switch event {
        case .mealLogged, .activityLogged, .checkInLogged:
            await cancelUpcomingAfterLog()
        default:
            break
        }
        switch event {
        case .mealLogged, .activityLogged:
            await sync(trigger: .foreground, wait: false)
        case .mealCompleted(let entryId):
            await sync(trigger: .mealComplete, entryId: entryId, wait: true)
        case .activityCompleted(let activityId):
            await sync(trigger: .activityComplete, activityId: activityId, wait: true)
        case .checkInLogged:
            await sync(trigger: .checkin, wait: true)
        case .settingsChanged:
            await sync(trigger: .settings, wait: true, refreshSettings: true)
        }
    }

    /// Settings were saved in the app: mirror them, then re-plan.
    func apply(settings: CoachSettings) async {
        mirror.save(settings, at: environment.now())
        if !settings.enabled {
            state.rows = []
            persist()
            await scheduler.removeAllPending()
        }
        await sync(trigger: .settings, wait: true)
    }

    /// Sign-out / account switch: forget the queue and every coach request.
    func reset() async {
        state = CoachSyncState(userId: nil)
        persist()
        mirror.clear()
        await scheduler.removeAllPending()
        await scheduler.setBadge(0)
    }

    /// Marks messages read outside the thread (notification "On it").
    func markRead(_ ids: [UUID]) async {
        guard !ids.isEmpty else { return }
        try? await service.markRead(ids)
        await scheduler.removeDelivered(messageIds: ids)
        if let unread = try? await service.fetchUnreadCount() {
            state.unreadCount = unread
            persist()
            await scheduler.setBadge(unread)
        }
    }

    // MARK: Sync

    @discardableResult
    func sync(
        trigger: CoachSyncRequest.Trigger,
        entryId: UUID? = nil,
        activityId: UUID? = nil,
        wait: Bool = true,
        refreshSettings: Bool = false
    ) async -> CoachSyncOutcome {
        // Serialize: each sync runs after the previous one finishes.
        let previous = tail
        let work = Task { () -> CoachSyncOutcome in
            await previous?.value
            return await self.performSync(
                trigger: trigger,
                entryId: entryId,
                activityId: activityId,
                wait: wait,
                refreshSettings: refreshSettings
            )
        }
        tail = Task { _ = await work.value }
        return await work.value
    }

    private func performSync(
        trigger: CoachSyncRequest.Trigger,
        entryId: UUID?,
        activityId: UUID?,
        wait: Bool,
        refreshSettings: Bool
    ) async -> CoachSyncOutcome {
        let now = environment.now()
        guard let userId = environment.userId() else {
            if state.userId != nil { await reset() }
            return .signedOut
        }
        if state.userId != userId {
            state = CoachSyncState(userId: userId)
            persist()
            await scheduler.removeAllPending()
        }

        var loadedSettings = mirror.load()
        let stale = mirror.fetchedAt().map { now.timeIntervalSince($0) > Self.settingsMaxAge } ?? true
        if refreshSettings || loadedSettings == nil || stale {
            if let fetched = try? await service.fetchSettings() {
                mirror.save(fetched, at: now)
                loadedSettings = fetched
            }
        }
        guard let settings = loadedSettings, settings.enabled else {
            if !state.rows.isEmpty {
                state.rows = []
                persist()
            }
            await scheduler.removeAllPending()
            return .disabled
        }

        var device = await environment.device()
        device.notificationStatus = await scheduler.authorizationStatus()
        let location = settings.locationRecsEnabled
            ? await environment.locationContext(Self.locationMaxAge)
            : nil
        let timeZone = environment.timeZone()
        let request = CoachSyncRequest(
            trigger: trigger,
            localDay: CoachLocalDay.string(for: now, timeZone: timeZone),
            timezone: timeZone.identifier,
            entryId: entryId,
            activityId: activityId,
            device: device,
            location: location,
            wait: wait
        )
        let generated = (try? await service.sync(request))?.generated ?? false

        let changes: [CoachMessage]
        do {
            changes = try await service.fetchChanges(since: state.cursor)
        } catch {
            await reconcileNotifications()
            return .failed(CoachViewModel.friendlyMessage(for: error))
        }
        apply(changes: changes, now: environment.now())
        if let unread = try? await service.fetchUnreadCount() {
            state.unreadCount = unread
        }
        state.lastSyncAt = now
        persist()
        await reconcileNotifications()

        let days = Array(Set(changes.map(\.localDay))).sorted()
        if !days.isEmpty { environment.postThreadChange(days) }
        return .synced(changed: changes.count, generated: generated)
    }

    private func apply(changes: [CoachMessage], now: Date) {
        state.rows = CoachNotificationPolicy.merge(rows: state.rows, changes: changes, now: now)
        if let newest = changes.map(\.updatedAt).max() {
            state.cursor = max(state.cursor ?? newest, newest)
        }
        state.suppressed = state.suppressed.filter { $0.value > now }
    }

    /// Re-plans pending requests from the persisted rows (no network).
    func reconcileNotifications() async {
        let status = await scheduler.authorizationStatus()
        guard status == .authorized || status == .provisional else { return }
        guard mirror.load()?.enabled == true else { return }
        let now = environment.now()
        state.rows = state.rows.filter { $0.deliverAt > now }
        state.suppressed = state.suppressed.filter { $0.value > now }
        await scheduler.reconcile(
            rows: state.rows,
            unreadCount: state.unreadCount,
            suppressed: Set(state.suppressed.keys),
            now: now
        )
        await scheduler.setBadge(state.unreadCount)
        persist()
    }

    // MARK: Cancel-on-log

    /// Removes pending coach texts due within the next 60 minutes; they stay
    /// suppressed locally until their time passes or the server replaces them.
    @discardableResult
    func cancelUpcomingAfterLog() async -> [UUID] {
        let now = environment.now()
        let ids = CoachNotificationPolicy.idsToCancelOnLog(rows: state.rows, now: now)
        guard !ids.isEmpty else { return [] }
        for row in state.rows where ids.contains(row.id) {
            state.suppressed[row.id] = row.deliverAt.addingTimeInterval(60)
        }
        persist()
        await scheduler.cancel(messageIds: ids)
        return ids
    }

    // MARK: Lock-screen replies

    /// Sends a reply typed on a notification. The request is persisted first
    /// so a failure is retried on the next foreground (same id, idempotent).
    /// Coach replies that arrive within `timeout` are posted immediately.
    @discardableResult
    func sendNotificationReply(
        _ request: CoachSendRequest,
        inReplyTo messageId: UUID?,
        timeout: TimeInterval
    ) async -> [CoachMessage] {
        state.outbox.append(CoachOutboxItem(request: request, enqueuedAt: environment.now(), attempts: 0))
        persist()
        let result = await CoachStreamCollector.collect(
            service.send(request),
            localDay: request.localDay,
            timeout: timeout,
            now: environment.now
        )
        settleOutbox(request.clientRequestId, result: result)
        if let messageId { try? await service.markRead([messageId]) }
        let replies = result.replies.filter { !$0.body.isEmpty }
        if !replies.isEmpty {
            state.unreadCount += replies.count
            await scheduler.presentImmediately(
                replies,
                firstBadge: state.unreadCount - replies.count + 1
            )
        }
        persist()
        return replies
    }

    func flushOutbox() async {
        let now = environment.now()
        state.outbox.removeAll { now.timeIntervalSince($0.enqueuedAt) > Self.outboxMaxAge }
        for item in state.outbox {
            let result = await CoachStreamCollector.collect(
                service.send(item.request),
                localDay: item.request.localDay,
                timeout: 30,
                now: environment.now
            )
            settleOutbox(item.request.clientRequestId, result: result)
        }
        persist()
    }

    private func settleOutbox(_ id: UUID, result: CoachStreamCollector.Result) {
        let delivered = result.accepted
            || (result.failure.map { !$0.retryable } ?? false)
            || (result.transportFailed && !result.transportRetryable)
        if delivered {
            state.outbox.removeAll { $0.request.clientRequestId == id }
        } else if let index = state.outbox.firstIndex(where: { $0.request.clientRequestId == id }) {
            state.outbox[index].attempts += 1
            if state.outbox[index].attempts >= 5 { state.outbox.remove(at: index) }
        }
    }

    // MARK: Background refresh

    /// Asks iOS for a refresh in ~2 h (heuristic; never relied on).
    nonisolated static func scheduleAppRefresh(now: Date = Date()) {
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshIdentifier)
        request.earliestBeginDate = now.addingTimeInterval(2 * 3600)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Unavailable in the simulator and when Background App Refresh is off.
        }
    }

    private func persist() {
        store.save(state)
    }
}
