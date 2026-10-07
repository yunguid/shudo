import Combine
import Foundation

/// What the workout logger hands back: the words (typed or dictated), an
/// optional photo, and the plan session it was logged against.
struct WorkoutLogDraft: Equatable, Sendable {
    var text: String
    var speechEngine: String?
    var imageJPEG: Data?
    var planSessionId: String?
    var kindHint: ActivityKind?
    var occurredAt: Date?

    init(
        text: String,
        speechEngine: String? = nil,
        imageJPEG: Data? = nil,
        planSessionId: String? = nil,
        kindHint: ActivityKind? = nil,
        occurredAt: Date? = nil
    ) {
        self.text = text
        self.speechEngine = speechEngine
        self.imageJPEG = imageJPEG
        self.planSessionId = planSessionId
        self.kindHint = kindHint
        self.occurredAt = occurredAt
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canSubmit: Bool {
        (!trimmedText.isEmpty || imageJPEG?.isEmpty == false)
            && trimmedText.count <= SupabaseService.maximumActivityTextLength
    }

    /// Card title while the server reads the log.
    func optimisticTitle(sessionName: String?) -> String {
        if let sessionName, !sessionName.isEmpty { return sessionName }
        let firstLine = trimmedText.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstLine.isEmpty {
            return firstLine.count > 48 ? String(firstLine.prefix(47)) + "…" : firstLine
        }
        if imageJPEG != nil { return "Workout screenshot" }
        return kindHint?.label ?? "New workout"
    }
}

/// Optimistic workout logging, owned by a view model rather than any sheet —
/// the same invariants as meal submission (`TodayViewModel`):
///
/// - `submit` shows a placeholder card immediately and returns; the sheet
///   dismisses on the spot while the upload runs here.
/// - A failed upload flips the placeholder to "Not sent" with the payload
///   preserved. `retry` re-sends the SAME client_request_id, so an ambiguous
///   failure (request landed, response lost) can never double-log.
/// - Once accepted, the server row is polled (650 ms → 3 s) until it settles;
///   `onActivitySettled` fires once per settled row.
/// - A reload that already contains the server row for a failed placeholder
///   (matched by client_request_id) drops the placeholder instead of
///   duplicating it.
///
/// One controller can be shared by the Today thread and the Train tab so a
/// workout logged anywhere shows up everywhere.
@MainActor
final class ActivityLoggingController: ObservableObject {
    /// Local placeholders and tracked server rows, keyed by id.
    @Published private(set) var overlay: [UUID: Activity] = [:]

    /// Fires when a tracked row leaves `processing` (complete or failed).
    var onActivitySettled: ((Activity) -> Void)?
    /// Fires when the server accepts a log (use it to cancel near-term coach
    /// nudges and kick a coach sync with the activity id).
    var onActivityAccepted: ((UUID) -> Void)?

    struct PendingSubmission: Equatable {
        let request: ActivityLogRequest
        var placeholder: Activity
    }

    private let service: any TrainServing
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let now: () -> Date
    private var pending: [UUID: PendingSubmission] = [:]
    private var submissionTasks: [UUID: Task<Void, Never>] = [:]
    private var pollingTasks: [UUID: Task<Void, Never>] = [:]
    var pollTimeout: TimeInterval = ActivityPollingPolicy.timeout

    static let notSentStatusMessage = "Not sent — check your connection and retry"
    static let stalledMessage = "Still working in the background"

    init(
        service: any TrainServing,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.sleep = sleep
        self.now = now
    }

    /// Overlay rows, newest first.
    var activities: [Activity] { ActivityTimelineMerge.sorted(Array(overlay.values)) }

    func isPendingSubmission(_ id: UUID) -> Bool { pending[id] != nil }

    func pendingRequest(for id: UUID) -> ActivityLogRequest? { pending[id]?.request }

    // MARK: Submit / retry / discard

    /// Accepts a log locally and returns the placeholder id immediately.
    @discardableResult
    func submit(
        _ draft: WorkoutLogDraft,
        localDay: String,
        timezone: String,
        sessionName: String? = nil,
        clientRequestId: UUID = UUID()
    ) -> UUID {
        let timestamp = now()
        let request = ActivityLogRequest(
            clientRequestId: clientRequestId,
            localDay: localDay,
            timezone: timezone,
            text: draft.trimmedText,
            speechEngine: draft.speechEngine,
            occurredAt: draft.occurredAt,
            planSessionId: draft.planSessionId,
            imageJPEG: draft.imageJPEG,
            kindHint: draft.kindHint
        )
        let placeholderId = UUID()
        let placeholder = Activity(
            id: placeholderId,
            clientRequestId: clientRequestId,
            localDay: localDay,
            occurredAt: draft.occurredAt ?? timestamp,
            status: .processing,
            source: draft.speechEngine == nil ? "text" : "voice",
            kind: draft.kindHint ?? (draft.planSessionId != nil ? .strength : .other),
            title: draft.optimisticTitle(sessionName: sessionName),
            details: ActivityDetails(planSessionId: draft.planSessionId),
            inputText: draft.trimmedText.isEmpty ? nil : draft.trimmedText,
            createdAt: timestamp,
            updatedAt: timestamp,
            localState: .sending
        )
        pending[placeholderId] = PendingSubmission(request: request, placeholder: placeholder)
        overlay[placeholderId] = placeholder
        startSubmission(placeholderId: placeholderId)
        return placeholderId
    }

    /// Re-sends a not-sent placeholder with its preserved payload and SAME
    /// client_request_id (the server dedupes). No-op while a send is running.
    func retry(_ placeholderId: UUID) {
        guard var submission = pending[placeholderId], submissionTasks[placeholderId] == nil else { return }
        submission.placeholder.localState = .sending
        submission.placeholder.status = .processing
        submission.placeholder.errorMessage = nil
        submission.placeholder.updatedAt = now()
        pending[placeholderId] = submission
        overlay[placeholderId] = submission.placeholder
        startSubmission(placeholderId: placeholderId)
    }

    /// Drops a local card (and its preserved payload) that never reached the server.
    func discard(_ placeholderId: UUID) {
        submissionTasks[placeholderId]?.cancel()
        submissionTasks[placeholderId] = nil
        pending[placeholderId] = nil
        overlay[placeholderId] = nil
    }

    private func startSubmission(placeholderId: UUID) {
        guard submissionTasks[placeholderId] == nil, let submission = pending[placeholderId] else { return }
        submissionTasks[placeholderId] = Task { [weak self] in
            guard let self else { return }
            await self.runSubmission(placeholderId: placeholderId, submission: submission)
            self.submissionTasks[placeholderId] = nil
        }
    }

    private func runSubmission(placeholderId: UUID, submission: PendingSubmission) async {
        do {
            let result = try await service.logActivity(submission.request)
            guard !Task.isCancelled, pending[placeholderId] != nil else { return }
            pending[placeholderId] = nil
            overlay[placeholderId] = nil
            var accepted = submission.placeholder
            accepted.id = result.activityId
            accepted.status = result.status
            accepted.localState = nil
            accepted.updatedAt = now()
            // A duplicate means an earlier attempt already landed; whatever
            // the server has wins over this guess as soon as polling reads it.
            if overlay[result.activityId] == nil || overlay[result.activityId]?.status == .processing {
                overlay[result.activityId] = accepted
            }
            onActivityAccepted?(result.activityId)
            if result.status == .processing || result.duplicate {
                track(id: result.activityId)
            } else {
                await refreshOnce(id: result.activityId)
            }
        } catch {
            guard !Task.isCancelled, var failed = pending[placeholderId]?.placeholder else { return }
            failed.status = .failed
            failed.localState = .notSent(message: Self.notSentStatusMessage)
            failed.errorMessage = Self.submissionErrorMessage(error)
            failed.updatedAt = now()
            pending[placeholderId]?.placeholder = failed
            overlay[placeholderId] = failed
        }
    }

    static func submissionErrorMessage(_ error: Error) -> String {
        if let trainError = error as? TrainServiceError, let message = trainError.errorDescription {
            return message
        }
        if case SupabaseService.ServiceError.networkError = error {
            return "Couldn’t reach the server. Check your connection and try again."
        }
        if error is URLError {
            return "Couldn’t reach the server. Check your connection and try again."
        }
        return "The workout wasn’t sent. Please try again."
    }

    // MARK: Tracking server rows

    /// Starts polling a server row that is still processing (e.g. found on
    /// reload after a relaunch). No-op if already tracked or settled.
    func track(_ activity: Activity) {
        guard activity.localState == nil, activity.status == .processing else { return }
        if overlay[activity.id] == nil || (overlay[activity.id]?.updatedAt ?? .distantPast) < activity.updatedAt {
            overlay[activity.id] = activity
        }
        track(id: activity.id)
    }

    private func track(id: UUID) {
        guard pollingTasks[id] == nil else { return }
        let fetch: @Sendable (UUID) async throws -> Activity? = { [service] in try await service.fetchActivity(id: $0) }
        let sleep = self.sleep
        let timeout = pollTimeout
        pollingTasks[id] = Task { [weak self] in
            do {
                let settled = try await ActivityPoller.poll(
                    id: id,
                    timeout: timeout,
                    fetch: fetch,
                    sleep: sleep,
                    onUpdate: { [weak self] row in await self?.apply(row) }
                )
                self?.finishTracking(id: id, settled: settled, deleted: settled == nil)
            } catch is CancellationError {
                return
            } catch {
                self?.markStalled(id: id)
            }
        }
    }

    private func refreshOnce(id: UUID) async {
        guard let row = try? await service.fetchActivity(id: id) else { return }
        apply(row)
        if row.status != .processing { onActivitySettled?(row) }
    }

    private func apply(_ row: Activity) {
        guard let existing = overlay[row.id] else {
            overlay[row.id] = row
            return
        }
        // The server inserts a placeholder title while it reads the log; keep
        // the optimistic one ("Upper A", the first words said) until the
        // analysis lands a real title.
        var merged = row
        if row.status == .processing, !existing.title.isEmpty {
            merged.title = existing.title
        }
        overlay[row.id] = merged
    }

    private func finishTracking(id: UUID, settled: Activity?, deleted: Bool) {
        pollingTasks[id] = nil
        if deleted {
            overlay[id] = nil
            return
        }
        guard let settled else { return }
        if settled.status == .processing {
            markStalled(id: id)
        } else {
            onActivitySettled?(settled)
        }
    }

    private func markStalled(id: UUID) {
        pollingTasks[id] = nil
        guard var row = overlay[id], row.status == .processing else { return }
        row.localState = .stalled(message: Self.stalledMessage)
        overlay[id] = row
    }

    /// Stops tracking a row (deleted, or the owner no longer cares).
    func forget(_ id: UUID) {
        pollingTasks[id]?.cancel()
        pollingTasks[id] = nil
        if pending[id] != nil { discard(id) }
        overlay[id] = nil
    }

    // MARK: Reconcile with a fresh load

    /// Call after every fetch: drops not-sent placeholders the server already
    /// has (by client_request_id), starts polling rows still processing, and
    /// prunes settled overlay rows the load has caught up with.
    func reconcile(withLoaded loaded: [Activity]) {
        let loadedById = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let loadedByRequest = Dictionary(
            loaded.compactMap { row in row.clientRequestId.map { ($0, row) } },
            uniquingKeysWith: { first, _ in first })

        for (placeholderId, submission) in pending where submissionTasks[placeholderId] == nil {
            guard let serverRow = loadedByRequest[submission.request.clientRequestId] else { continue }
            pending[placeholderId] = nil
            overlay[placeholderId] = nil
            if serverRow.status == .processing { track(serverRow) }
        }

        for (id, row) in overlay where !row.isLocalOnly {
            guard let fresh = loadedById[id] else { continue }
            if fresh.status != .processing, fresh.updatedAt >= row.updatedAt {
                pollingTasks[id]?.cancel()
                pollingTasks[id] = nil
                overlay[id] = nil
            }
        }

        for row in loaded where row.status == .processing {
            if case .stalled = overlay[row.id]?.localState {
                overlay[row.id] = row
            }
            track(row)
        }
    }
}
