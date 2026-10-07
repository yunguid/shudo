import Foundation

// MARK: - Thread state types (consumed by the Today screen)

/// The coach's "typing" indicator. `.thinking` shows the typing bubble (with
/// an optional tool label such as "Checking what's near you…"); `.streaming`
/// means text is arriving in that message's bubble.
enum CoachTypingState: Equatable, Sendable {
    case thinking(label: String?)
    case streaming(messageId: UUID)
}

/// Luke's optimistic bubble until the server accepts the turn.
struct CoachPendingSend: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case sending
        case failed(message: String, retryable: Bool)
    }

    let clientRequestId: UUID
    var text: String
    var inputMode: CoachInputMode
    var localDay: String
    var createdAt: Date
    /// JPEG for the bubble thumbnail while the photo uploads.
    var attachmentJPEG: Data?
    var hasAttachment: Bool
    var state: State

    var id: UUID { clientRequestId }

    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }
}

/// A turn whose user message reached the server but whose reply stream
/// broke and could not be resumed automatically. Retrying resends the same
/// `client_request_id`, which replays or tails the server run.
struct CoachTurnInterruption: Equatable, Sendable {
    let clientRequestId: UUID
    let userMessageId: UUID?
    let message: String
    let retryable: Bool
}

enum CoachThreadItem: Identifiable, Equatable {
    case message(CoachMessage)
    case pending(CoachPendingSend)

    var id: UUID {
        switch self {
        case .message(let message): return message.id
        case .pending(let pending): return pending.clientRequestId
        }
    }

    var date: Date {
        switch self {
        case .message(let message): return message.deliverAt
        case .pending(let pending): return pending.createdAt
        }
    }
}

enum CoachAttachment: Equatable, Sendable {
    /// Uploaded to `coach-media` before the turn is sent.
    case jpeg(Data)
    /// Already uploaded (e.g. by a camera flow).
    case uploaded(path: String)
}

/// Notification/badge side effects, injectable for tests.
@MainActor
protocol CoachThreadNotifying: AnyObject {
    var isAppActive: Bool { get }
    func removeDelivered(messageIds: [UUID])
    func setBadge(_ count: Int)
    /// Called when a reply finishes while the app isn't active.
    func presentReplies(_ messages: [CoachMessage], unreadCount: Int)
}

/// `UIApplication.beginBackgroundTask` seam, injectable for tests.
@MainActor
protocol CoachBackgroundTasking: AnyObject {
    func begin(_ name: String) -> Int?
    func end(_ token: Int?)
}

// MARK: - Merge policy

enum CoachThreadMerge {
    /// Server rows win, except: a local bubble still streaming may be ahead
    /// of the throttled DB copy, a local `read_at` survives a racing read,
    /// and in-flight local rows the server doesn't return yet (`keepingLocal`)
    /// are kept.
    static func merge(
        local: [CoachMessage],
        fetched: [CoachMessage],
        keepingLocal keep: Set<UUID>
    ) -> [CoachMessage] {
        var result: [UUID: CoachMessage] = [:]
        for message in fetched { result[message.id] = message }
        for message in local {
            if let server = result[message.id] {
                result[message.id] = reconcile(local: message, server: server)
            } else if keep.contains(message.id) {
                result[message.id] = message
            }
        }
        return CoachThreadOrdering.sorted(Array(result.values))
    }

    static func reconcile(local: CoachMessage, server: CoachMessage) -> CoachMessage {
        var merged = server
        if server.isStreaming, local.body.count > server.body.count, local.body.hasPrefix(server.body) {
            merged.body = local.body
            merged.isStreaming = local.isStreaming
        }
        if merged.readAt == nil, let readAt = local.readAt { merged.readAt = readAt }
        return merged
    }
}

// MARK: - View model

/// Per-day coach thread: fetched rows merged with optimistic sends and live
/// streams. Lane I3 renders `items` (merged with meals/activities) and calls
/// `send`, `retry`, `act`, `refresh`, `markVisibleRead`, `onForeground`.
@MainActor
final class CoachViewModel: ObservableObject {
    /// The day on screen (`YYYY-MM-DD`).
    @Published private(set) var localDay: String
    /// Visible coach + user rows for `localDay`, chronological.
    @Published private(set) var messages: [CoachMessage] = []
    /// Optimistic user bubbles not yet accepted (sending or failed).
    @Published private(set) var pendingSends: [CoachPendingSend] = []
    @Published private(set) var typing: CoachTypingState?
    /// Unread coach messages across all days (badge).
    @Published private(set) var unreadCount = 0
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Accepted turns whose reply was cut off, keyed by client request id.
    @Published private(set) var interruptions: [UUID: CoachTurnInterruption] = [:]
    /// Card ids (`CoachCardAction.id`) with an action in flight.
    @Published private(set) var actionsInFlight: Set<UUID> = []
    /// Set by `focus(messageId:day:)` (deep link); the thread scrolls to it.
    @Published private(set) var focusedMessageId: UUID?

    /// Messages and pending bubbles for `localDay`, chronological.
    var items: [CoachThreadItem] {
        let pending = pendingSends.filter { $0.localDay == localDay }
        guard !pending.isEmpty else { return messages.map(CoachThreadItem.message) }
        return (messages.map(CoachThreadItem.message) + pending.map(CoachThreadItem.pending))
            .sorted { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    var isShowingToday: Bool { localDay == todayLocalDay() }
    var isSending: Bool { turns.values.contains { $0.task != nil } }

    func interruption(forUserMessage id: UUID) -> CoachTurnInterruption? {
        interruptions.values.first { $0.userMessageId == id }
    }

    // MARK: Dependencies

    private let service: any CoachServing
    private let timeZone: () -> TimeZone
    private let now: () -> Date
    private let locationContext: () async -> LocationContext?
    private weak var notifier: CoachThreadNotifying?
    private let backgroundTasks: CoachBackgroundTasking?
    private let autoResumeDelays: [UInt64]

    // MARK: State

    private struct Turn {
        var request: CoachSendRequest
        var attachmentJPEG: Data?
        var locationResolved: Bool
        var accepted = false
        var finished = false
        var userMessageId: UUID?
        var streamedMessageIds: Set<UUID> = []
        var task: Task<Void, Never>?
    }

    private enum AttemptOutcome {
        case finished
        case cancelled
        case transport(Error)
        case serverError(CoachStreamFailure)
    }

    private var store: [String: [UUID: CoachMessage]] = [:]
    private var turns: [UUID: Turn] = [:]
    private var recentlyStreamed: [UUID: Date] = [:]
    private var actionRequestIds: [String: UUID] = [:]
    private var unsyncedReadIds: Set<UUID> = []
    private var loadGeneration = UUID()
    private var pinnedToToday = true
    private var syncObserver: NSObjectProtocol?

    static let recentlyStreamedRetention: TimeInterval = 120

    init(
        service: any CoachServing,
        localDay: String? = nil,
        timeZone: @escaping () -> TimeZone = { .autoupdatingCurrent },
        now: @escaping () -> Date = { Date() },
        locationContext: @escaping () async -> LocationContext? = { nil },
        notifier: CoachThreadNotifying? = nil,
        backgroundTasks: CoachBackgroundTasking? = nil,
        observesSyncNotifications: Bool = false,
        autoResumeDelays: [UInt64] = [700_000_000, 2_000_000_000]
    ) {
        self.service = service
        self.timeZone = timeZone
        self.now = now
        self.locationContext = locationContext
        self.notifier = notifier
        self.backgroundTasks = backgroundTasks
        self.autoResumeDelays = autoResumeDelays
        let today = CoachLocalDay.string(for: now(), timeZone: timeZone())
        self.localDay = localDay ?? today
        self.pinnedToToday = (localDay ?? today) == today
        if observesSyncNotifications {
            syncObserver = NotificationCenter.default.addObserver(
                forName: .coachThreadDidChange,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let days = note.userInfo?["local_days"] as? [String]
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if days == nil || days?.contains(self.localDay) == true {
                        Task { await self.refresh() }
                    } else {
                        Task { await self.refreshUnreadCount() }
                    }
                }
            }
        }
    }

    deinit {
        if let syncObserver { NotificationCenter.default.removeObserver(syncObserver) }
    }

    /// The production wiring: live service, notification center, background
    /// task wrapper, cached nearby-store context (≤10 min old) on sends.
    static func live(timeZone: @escaping () -> TimeZone = { .autoupdatingCurrent }) -> CoachViewModel {
        CoachViewModel(
            service: CoachService.live,
            timeZone: timeZone,
            locationContext: { await NearbyStoreScout.shared.contextIfEnabled(maxAge: 10 * 60, refreshIfStale: false) },
            notifier: LiveCoachThreadNotifier.shared,
            backgroundTasks: UIKitCoachBackgroundTasks.shared,
            observesSyncNotifications: true
        )
    }

    // MARK: Loading

    /// Loads (or reloads) a day. `nil` reloads the current day, rolling over
    /// to the new today when the thread is pinned to today.
    func refresh(day: String? = nil) async {
        let today = todayLocalDay()
        let target: String
        if let day, CoachLocalDay.isValid(day) {
            target = day
            pinnedToToday = day == today
        } else {
            target = pinnedToToday ? today : localDay
        }
        if target != localDay {
            localDay = target
            typing = nil
            publish()
        }
        let generation = UUID()
        loadGeneration = generation
        isLoading = messages.isEmpty
        do {
            let fetched = try await service.fetchDay(target)
            guard loadGeneration == generation else { return }
            pruneRecentlyStreamed()
            let local = Array((store[target] ?? [:]).values)
            let merged = CoachThreadMerge.merge(
                local: local,
                fetched: fetched,
                keepingLocal: keptLocalIds()
            )
            store[target] = Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            reconcilePendingSends(with: fetched)
            errorMessage = nil
            publish()
        } catch {
            guard loadGeneration == generation else { return }
            if !(error is CancellationError) {
                errorMessage = Self.friendlyMessage(for: error)
            }
        }
        if loadGeneration == generation { isLoading = false }
        await refreshUnreadCount()
    }

    /// Jump to a message from a deep link / notification tap.
    func focus(messageId: UUID?, day: String?) async {
        await refresh(day: day ?? localDay)
        focusedMessageId = messageId
    }

    func consumeFocus() {
        focusedMessageId = nil
    }

    /// App returned to the foreground: roll the day over, resume replies that
    /// died while backgrounded, and reload.
    func onForeground() async {
        for (id, interruption) in interruptions where interruption.retryable {
            retry(id)
        }
        for (id, turn) in turns where turn.accepted && !turn.finished && turn.task == nil {
            startTurn(id)
        }
        await refresh()
    }

    func refreshUnreadCount() async {
        guard let count = try? await service.fetchUnreadCount() else { return }
        unreadCount = count
        notifier?.setBadge(count)
    }

    // MARK: Sending

    /// Sends a message to Shudo. Returns the turn's `client_request_id`, or
    /// nil when there was nothing to send. The bubble appears immediately;
    /// failures leave it in place with a retry affordance.
    @discardableResult
    func send(
        text: String,
        mode: CoachInputMode = .typed,
        speechEngine: String? = nil,
        attachment: CoachAttachment? = nil,
        contextHint: CoachContextHint? = nil
    ) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || attachment != nil else { return nil }
        guard trimmed.count <= CoachSendRequest.maximumTextLength else {
            errorMessage = "That’s too long for one message. Trim it a little."
            return nil
        }
        let today = todayLocalDay()
        if localDay != today {
            pinnedToToday = true
            localDay = today
            publish()
            Task { await self.refresh() }
        }

        let id = UUID()
        var attachmentPath: String?
        var attachmentJPEG: Data?
        switch attachment {
        case .jpeg(let data)?: attachmentJPEG = data
        case .uploaded(let path)?: attachmentPath = path
        case nil: break
        }
        let request = CoachSendRequest(
            clientRequestId: id,
            text: trimmed,
            inputMode: mode,
            speechEngine: mode == .dictated ? speechEngine : nil,
            localDay: today,
            timezone: timeZone().identifier,
            attachmentPath: attachmentPath,
            location: nil,
            contextHint: contextHint
        )
        pendingSends.append(CoachPendingSend(
            clientRequestId: id,
            text: trimmed,
            inputMode: mode,
            localDay: today,
            createdAt: now(),
            attachmentJPEG: attachmentJPEG,
            hasAttachment: attachment != nil,
            state: .sending
        ))
        turns[id] = Turn(request: request, attachmentJPEG: attachmentJPEG, locationResolved: false)
        errorMessage = nil
        startTurn(id)
        return id
    }

    /// Retries a failed bubble or an interrupted reply with the SAME
    /// `client_request_id` (server-side idempotent).
    func retry(_ clientRequestId: UUID) {
        guard let turn = turns[clientRequestId], turn.task == nil, !turn.finished else { return }
        if let index = pendingSends.firstIndex(where: { $0.clientRequestId == clientRequestId }) {
            pendingSends[index].state = .sending
        }
        interruptions[clientRequestId] = nil
        startTurn(clientRequestId)
    }

    /// Drops a failed bubble that was never accepted.
    func discardPending(_ clientRequestId: UUID) {
        guard let turn = turns[clientRequestId], turn.task == nil, !turn.accepted else { return }
        turns[clientRequestId] = nil
        pendingSends.removeAll { $0.clientRequestId == clientRequestId }
    }

    private func startTurn(_ id: UUID) {
        guard turns[id] != nil, turns[id]?.task == nil else { return }
        turns[id]?.task = Task { [weak self] in
            await self?.driveTurn(id)
        }
    }

    private func driveTurn(_ id: UUID) async {
        let token = backgroundTasks?.begin("coach-send")
        var resumes = 0
        loop: while true {
            let outcome = await attemptTurn(id)
            guard turns[id] != nil else { break loop }
            switch outcome {
            case .finished, .cancelled:
                break loop
            case .serverError(let failure):
                typing = nil
                if turns[id]?.accepted == true {
                    markInterrupted(id, message: failure.message, retryable: failure.retryable)
                } else {
                    markPendingFailed(id, message: failure.message, retryable: failure.retryable)
                }
                break loop
            case .transport(let error):
                typing = nil
                let retryable = CoachServiceError.isRetryable(error)
                guard turns[id]?.accepted == true else {
                    markPendingFailed(id, message: Self.friendlyMessage(for: error), retryable: retryable)
                    break loop
                }
                if retryable, resumes < autoResumeDelays.count {
                    try? await Task.sleep(nanoseconds: autoResumeDelays[resumes])
                    resumes += 1
                    if Task.isCancelled { break loop }
                    continue loop
                }
                markInterrupted(id, message: Self.friendlyMessage(for: error), retryable: retryable)
                Task { await self.refresh() }
                break loop
            }
        }
        turns[id]?.task = nil
        if turns[id]?.finished == true { turns[id] = nil }
        backgroundTasks?.end(token)
    }

    private func attemptTurn(_ id: UUID) async -> AttemptOutcome {
        guard let turn = turns[id] else { return .cancelled }
        if let jpeg = turn.attachmentJPEG, turn.request.attachmentPath == nil {
            do {
                let path = try await service.uploadAttachment(jpeg: jpeg, localDay: turn.request.localDay)
                turns[id]?.request.attachmentPath = path
                turns[id]?.attachmentJPEG = nil
            } catch {
                return Task.isCancelled ? .cancelled : .transport(error)
            }
        }
        if turns[id]?.locationResolved == false {
            let location = await locationContext()
            turns[id]?.request.location = location
            turns[id]?.locationResolved = true
        }
        guard let request = turns[id]?.request else { return .cancelled }

        var failure: CoachStreamFailure?
        var sawDone = false
        do {
            for try await event in service.send(request) {
                if Task.isCancelled { return .cancelled }
                apply(event, turnId: id)
                switch event {
                case .done: sawDone = true
                case .error(let error): failure = error
                default: break
                }
            }
        } catch {
            if Task.isCancelled || error is CancellationError { return .cancelled }
            return .transport(error)
        }
        if let failure, !sawDone { return .serverError(failure) }
        guard sawDone else { return .transport(CoachServiceError.streamEndedEarly) }
        return .finished
    }

    private func apply(_ event: CoachStreamEvent, turnId id: UUID) {
        let day = turns[id]?.request.localDay ?? localDay
        switch event {
        case .accepted(_, let userMessage, _):
            turns[id]?.accepted = true
            if let userMessage {
                upsert(userMessage)
                turns[id]?.userMessageId = userMessage.id
            }
            pendingSends.removeAll { $0.clientRequestId == id }
            interruptions[id] = nil
            if case .streaming? = typing {} else { typing = .thinking(label: nil) }

        case .status(let label):
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            typing = .thinking(label: trimmed.isEmpty ? nil : trimmed)

        case .delta(let messageId, let text):
            appendDelta(text, to: messageId, day: day)
            turns[id]?.streamedMessageIds.insert(messageId)
            recentlyStreamed[messageId] = now()
            typing = .streaming(messageId: messageId)

        case .message(let message):
            upsert(message)
            recentlyStreamed[message.id] = now()
            if message.role == .coach {
                turns[id]?.streamedMessageIds.insert(message.id)
                if !message.isStreaming { typing = nil }
            } else if message.role == .user {
                pendingSends.removeAll { $0.clientRequestId == id }
            }

        case .done(_, let messageIds):
            typing = nil
            turns[id]?.finished = true
            let ids = (turns[id]?.streamedMessageIds ?? []).union(messageIds)
            var replies: [CoachMessage] = []
            var needsReload = false
            for messageId in ids {
                guard var message = findMessage(messageId) else {
                    needsReload = true
                    continue
                }
                if message.isStreaming {
                    message.isStreaming = false
                    put(message)
                    needsReload = true
                }
                if message.role == .coach { replies.append(message) }
            }
            if let notifier, !notifier.isAppActive, !replies.isEmpty {
                notifier.presentReplies(
                    CoachThreadOrdering.sorted(replies),
                    unreadCount: unreadCount
                )
            }
            publish()
            if needsReload { Task { await self.refresh() } }

        case .error:
            typing = nil
        }
    }

    private func appendDelta(_ text: String, to messageId: UUID, day: String) {
        if var existing = findMessage(messageId) {
            existing.body += text
            existing.isStreaming = true
            put(existing)
        } else {
            let placeholder = CoachMessage(
                id: messageId,
                role: .coach,
                kind: CoachMessageKind.text.rawValue,
                body: text,
                rawPayload: .object(["streaming": .bool(true)]),
                localDay: day,
                deliverAt: now(),
                status: .delivered
            )
            put(placeholder)
        }
        publish()
    }

    private func markPendingFailed(_ id: UUID, message: String, retryable: Bool) {
        guard let index = pendingSends.firstIndex(where: { $0.clientRequestId == id }) else { return }
        pendingSends[index].state = .failed(message: message, retryable: retryable)
    }

    private func markInterrupted(_ id: UUID, message: String, retryable: Bool) {
        interruptions[id] = CoachTurnInterruption(
            clientRequestId: id,
            userMessageId: turns[id]?.userMessageId,
            message: message,
            retryable: retryable
        )
        // Stop showing half-written bubbles as live.
        for messageId in turns[id]?.streamedMessageIds ?? [] {
            if var message = findMessage(messageId), message.isStreaming {
                message.isStreaming = false
                put(message)
            }
        }
        publish()
    }

    /// A fetched user row proves the server has a turn we think failed:
    /// drop the bubble and tail the run for its reply.
    private func reconcilePendingSends(with fetched: [CoachMessage]) {
        let accepted = Set(fetched.compactMap { $0.role == .user ? $0.clientRequestId : nil })
        guard !accepted.isEmpty else { return }
        for id in accepted where turns[id] != nil {
            let userMessage = fetched.first { $0.clientRequestId == id }
            pendingSends.removeAll { $0.clientRequestId == id }
            turns[id]?.accepted = true
            turns[id]?.userMessageId = userMessage?.id
            if turns[id]?.task == nil, turns[id]?.finished == false, interruptions[id] == nil {
                startTurn(id)
            }
        }
        pendingSends.removeAll { accepted.contains($0.clientRequestId) }
    }

    // MARK: Card actions

    /// Runs a card button. Reuses one idempotency key per (card, decision)
    /// until it succeeds. Returns false (and sets `errorMessage`) on failure.
    @discardableResult
    func act(on action: CoachCardAction) async -> Bool {
        guard !actionsInFlight.contains(action.id) else { return false }
        var request = action
        if let reused = actionRequestIds[action.dedupeKey] {
            request.clientRequestId = reused
        } else {
            actionRequestIds[action.dedupeKey] = action.clientRequestId
        }
        actionsInFlight.insert(action.id)
        defer { actionsInFlight.remove(action.id) }
        do {
            let changed = try await service.act(on: request)
            actionRequestIds[action.dedupeKey] = nil
            for message in changed { upsert(message) }
            errorMessage = nil
            return true
        } catch {
            errorMessage = Self.friendlyMessage(for: error)
            return false
        }
    }

    // MARK: Read state

    /// Marks every delivered coach message on the visible day as read (call
    /// while the thread is on screen), clears their delivered notifications
    /// and updates the badge.
    func markVisibleRead() async {
        let current = now()
        let ids = messages.filter { $0.isUnread(at: current) }.map(\.id)
        let toSend = Set(ids).union(unsyncedReadIds)
        guard !toSend.isEmpty else { return }
        for id in ids {
            if var message = findMessage(id) {
                message.readAt = current
                put(message)
            }
        }
        if !ids.isEmpty {
            unreadCount = max(0, unreadCount - ids.count)
            publish()
            notifier?.removeDelivered(messageIds: ids)
            notifier?.setBadge(unreadCount)
        }
        do {
            try await service.markRead(Array(toSend))
            unsyncedReadIds.subtract(toSend)
        } catch {
            unsyncedReadIds.formUnion(toSend)
        }
    }

    // MARK: Store

    func message(id: UUID) -> CoachMessage? { findMessage(id) }

    private func findMessage(_ id: UUID) -> CoachMessage? {
        for day in store.values {
            if let message = day[id] { return message }
        }
        return nil
    }

    private func put(_ message: CoachMessage) {
        for day in store.keys where day != message.localDay && store[day]?[message.id] != nil {
            store[day]?[message.id] = nil
        }
        store[message.localDay, default: [:]][message.id] = message
    }

    private func upsert(_ incoming: CoachMessage) {
        if let existing = findMessage(incoming.id) {
            put(CoachThreadMerge.reconcile(local: existing, server: incoming))
        } else {
            put(incoming)
        }
        if incoming.role == .user, let clientRequestId = incoming.clientRequestId {
            pendingSends.removeAll { $0.clientRequestId == clientRequestId }
        }
        publish()
    }

    private func publish() {
        let current = now()
        let day = store[localDay] ?? [:]
        let visible = day.values.filter {
            $0.status != .superseded
                && ($0.deliverAt <= current.addingTimeInterval(5) || recentlyStreamed[$0.id] != nil)
        }
        let sorted = CoachThreadOrdering.sorted(visible)
        if sorted != messages { messages = sorted }
    }

    private func keptLocalIds() -> Set<UUID> {
        var ids = Set(recentlyStreamed.keys)
        for turn in turns.values where !turn.finished || turn.task != nil {
            ids.formUnion(turn.streamedMessageIds)
        }
        return ids
    }

    private func pruneRecentlyStreamed() {
        let cutoff = now().addingTimeInterval(-Self.recentlyStreamedRetention)
        recentlyStreamed = recentlyStreamed.filter { $0.value >= cutoff }
    }

    private func todayLocalDay() -> String {
        CoachLocalDay.string(for: now(), timeZone: timeZone())
    }

    nonisolated static func friendlyMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "You’re offline. Shudo will get it when you’re back."
            case .timedOut:
                return "Shudo took too long to answer. Try again."
            default:
                return "Couldn’t reach Shudo. Try again."
            }
        }
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return "Couldn’t reach Shudo. Try again."
    }
}
