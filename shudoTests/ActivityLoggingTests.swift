import Foundation
import Testing
@testable import shudo

/// Scripted `TrainServing`: queued log outcomes, per-id fetch sequences
/// (the last element repeats), and recorded side effects.
private actor FakeTrainService: TrainServing {
    struct Activation: Equatable {
        let planId: UUID
        let clientRequestId: UUID
    }

    private(set) var logRequests: [ActivityLogRequest] = []
    private var logOutcomes: [Result<ActivityLogResult, Error>] = []
    private var fetchScripts: [UUID: [Activity?]] = [:]
    private(set) var fetchCounts: [UUID: Int] = [:]
    private var plans = TrainingPlanState()
    private var listed: [Activity] = []
    private var deleteError: Error?
    private(set) var deleted: [UUID] = []
    private var activationErrors: [Error?] = []
    private(set) var activations: [Activation] = []

    func queueLog(_ outcome: Result<ActivityLogResult, Error>) { logOutcomes.append(outcome) }
    func script(_ id: UUID, _ rows: [Activity?]) { fetchScripts[id] = rows }
    func setPlans(_ state: TrainingPlanState) { plans = state }
    func setListed(_ rows: [Activity]) { listed = rows }
    func setDeleteError(_ error: Error?) { deleteError = error }
    func queueActivation(_ error: Error?) { activationErrors.append(error) }

    func fetchActivities(fromLocalDay: String, throughLocalDay: String?, limit: Int) async throws -> [Activity] {
        listed
    }

    func fetchActivity(id: UUID) async throws -> Activity? {
        fetchCounts[id, default: 0] += 1
        guard var rows = fetchScripts[id], let first = rows.first else { return nil }
        if rows.count > 1 {
            rows.removeFirst()
            fetchScripts[id] = rows
        }
        return first
    }

    func fetchTrainingPlans() async throws -> TrainingPlanState { plans }

    func logActivity(_ request: ActivityLogRequest) async throws -> ActivityLogResult {
        logRequests.append(request)
        guard !logOutcomes.isEmpty else {
            return ActivityLogResult(activityId: UUID(), status: .processing, duplicate: false)
        }
        return try logOutcomes.removeFirst().get()
    }

    func deleteActivity(id: UUID) async throws {
        if let deleteError { throw deleteError }
        deleted.append(id)
    }

    func activateTrainingPlan(planId: UUID, clientRequestId: UUID) async throws {
        activations.append(Activation(planId: planId, clientRequestId: clientRequestId))
        if !activationErrors.isEmpty, let error = activationErrors.removeFirst() { throw error }
    }

    func signedActivityImageURL(path: String) async -> URL? { nil }
}

private final class Recorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
    var values: [Value] { lock.withLock { storage } }
}

@MainActor
private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return true
}

private enum Fixture {
    static let timezone = "America/New_York"
    static let today = "2026-10-06"
    static let now = TrainDateParser.parse("2026-10-06T16:00:00Z")!

    static func row(
        _ id: UUID = UUID(),
        day: String = today,
        status: ActivityStatus,
        title: String = "Workout",
        session: String? = nil,
        clientRequestId: UUID? = nil,
        exercises: [ActivityExercise] = [],
        updatedAt: Date = Date(timeIntervalSince1970: 1_791_300_000)
    ) -> Activity {
        let start = TrainCalendar.date(fromLocalDay: day, timezone: timezone)!
        return Activity(
            id: id,
            clientRequestId: clientRequestId,
            localDay: day,
            occurredAt: start.addingTimeInterval(18 * 3_600),
            status: status,
            kind: .strength,
            title: title,
            details: ActivityDetails(
                exercises: exercises,
                planSessionId: session,
                analysisPreview: status == .processing ? "Bench 185 for 8…" : nil),
            updatedAt: updatedAt)
    }

    @MainActor
    static func controller(_ service: FakeTrainService) -> ActivityLoggingController {
        let controller = ActivityLoggingController(
            service: service, sleep: { _ in try await Task.sleep(nanoseconds: 2_000_000) })
        controller.pollTimeout = 2
        return controller
    }

    static let profile = Profile(
        userId: "00000000-0000-4000-8000-000000000001",
        timezone: timezone,
        dailyMacroTarget: MacroTarget(caloriesKcal: 2_950, proteinG: 175, carbsG: 360, fatG: 85),
        units: "imperial",
        goalType: .gain)

    static let plan = TrainingPlan(
        id: UUID(),
        status: .active,
        plan: TrainingPlanDoc(
            name: "Upper / Lower",
            sessionsPerWeek: 4,
            rotation: ["upper_a", "lower_a", "upper_b", "lower_b"],
            sessions: [
                TrainingSession(id: "upper_a", name: "Upper A", exercises: [
                    PlannedExercise(name: "Barbell bench press", sets: 4, repMin: 6, repMax: 8, incrementLb: 5)]),
                TrainingSession(id: "lower_a", name: "Lower A", exercises: [
                    PlannedExercise(name: "Back squat", sets: 4, repMin: 5, repMax: 7, incrementLb: 10)]),
                TrainingSession(id: "upper_b", name: "Upper B", exercises: []),
                TrainingSession(id: "lower_b", name: "Lower B", exercises: []),
            ]),
        createdAt: Date(timeIntervalSince1970: 1_790_000_000),
        activatedAt: Date(timeIntervalSince1970: 1_790_000_000))
}

@MainActor
struct ActivityLoggingTests {
    private let draft = WorkoutLogDraft(
        text: "bench 185 for 8, 8, 7",
        speechEngine: "apple.speech_transcriber",
        planSessionId: "upper_a",
        kindHint: .strength)

    @Test func submitShowsAPlaceholderInstantlyThenFollowsTheServerRowToCompletion() async throws {
        let service = FakeTrainService()
        let serverId = UUID()
        await service.queueLog(.success(ActivityLogResult(activityId: serverId, status: .processing, duplicate: false)))
        let processing = Fixture.row(serverId, status: .processing, title: "Workout", session: "upper_a")
        var complete = Fixture.row(serverId, status: .complete, title: "Upper A — bench day", session: "upper_a")
        complete.activeKcal = 300
        await service.script(serverId, [processing, processing, complete])

        let controller = Fixture.controller(service)
        let settled = Recorder<Activity>()
        let accepted = Recorder<UUID>()
        controller.onActivitySettled = { settled.append($0) }
        controller.onActivityAccepted = { accepted.append($0) }

        let placeholderId = controller.submit(
            draft, localDay: Fixture.today, timezone: Fixture.timezone, sessionName: "Upper A")

        let placeholder = try #require(controller.overlay[placeholderId])
        #expect(placeholder.localState == .sending)
        #expect(placeholder.isProcessing)
        #expect(placeholder.isLocalOnly)
        #expect(placeholder.title == "Upper A")
        #expect(placeholder.planSessionId == "upper_a")
        #expect(placeholder.kind == .strength)
        #expect(placeholder.localDay == Fixture.today)
        #expect(controller.isPendingSubmission(placeholderId))

        #expect(await waitUntil { settled.values.count == 1 })
        #expect(controller.overlay[placeholderId] == nil)
        #expect(!controller.isPendingSubmission(placeholderId))
        #expect(controller.overlay[serverId]?.status == .complete)
        #expect(controller.overlay[serverId]?.title == "Upper A — bench day")
        #expect(settled.values.map(\.id) == [serverId])
        #expect(accepted.values == [serverId])

        let requests = await service.logRequests
        #expect(requests.count == 1)
        #expect(requests[0].text == "bench 185 for 8, 8, 7")
        #expect(requests[0].speechEngine == "apple.speech_transcriber")
        #expect(requests[0].planSessionId == "upper_a")
        #expect(requests[0].localDay == Fixture.today)
        #expect(requests[0].clientRequestId == placeholder.clientRequestId)
    }

    @Test func processingRowsKeepTheOptimisticTitleOverTheServerPlaceholder() async {
        let service = FakeTrainService()
        let serverId = UUID()
        await service.queueLog(.success(ActivityLogResult(activityId: serverId, status: .processing, duplicate: false)))
        await service.script(serverId, [Fixture.row(serverId, status: .processing, title: "Reading your workout")])
        let controller = Fixture.controller(service)
        controller.submit(draft, localDay: Fixture.today, timezone: Fixture.timezone, sessionName: "Upper A")
        // The first poll lands the server row (it carries the analysis preview).
        #expect(await waitUntil { controller.overlay[serverId]?.analysisPreview != nil })
        #expect(controller.overlay[serverId]?.title == "Upper A")
        #expect(controller.overlay[serverId]?.analysisPreview == "Bench 185 for 8…")
        controller.forget(serverId)
        #expect(controller.overlay[serverId] == nil)
    }

    @Test func aFailedSendIsRetriedWithTheSameClientRequestId() async throws {
        let service = FakeTrainService()
        let serverId = UUID()
        await service.queueLog(.failure(URLError(.notConnectedToInternet)))
        await service.queueLog(.success(ActivityLogResult(activityId: serverId, status: .processing, duplicate: true)))
        await service.script(serverId, [Fixture.row(serverId, status: .complete, title: "Upper A")])
        let controller = Fixture.controller(service)

        let placeholderId = controller.submit(draft, localDay: Fixture.today, timezone: Fixture.timezone)
        #expect(await waitUntil { controller.overlay[placeholderId]?.isNotSent == true })
        let failed = try #require(controller.overlay[placeholderId])
        #expect(failed.status == .failed)
        #expect(failed.errorMessage == "Couldn’t reach the server. Check your connection and try again.")
        #expect(!failed.countsTowardHistory)
        #expect(controller.isPendingSubmission(placeholderId))

        controller.retry(placeholderId)
        #expect(controller.overlay[placeholderId]?.localState == .sending)
        #expect(await waitUntil { controller.overlay[serverId]?.status == .complete })
        #expect(controller.overlay[placeholderId] == nil)

        let requests = await service.logRequests
        #expect(requests.count == 2)
        #expect(requests[0] == requests[1])
    }

    @Test func aReloadThatAlreadyHasTheRowDropsTheNotSentPlaceholder() async throws {
        let service = FakeTrainService()
        await service.queueLog(.failure(URLError(.timedOut)))
        let controller = Fixture.controller(service)
        let placeholderId = controller.submit(draft, localDay: Fixture.today, timezone: Fixture.timezone)
        #expect(await waitUntil { controller.overlay[placeholderId]?.isNotSent == true })
        let requestId = try #require(controller.pendingRequest(for: placeholderId)?.clientRequestId)

        // The first request landed; only its response was lost.
        let serverId = UUID()
        let landed = Fixture.row(serverId, status: .processing, session: "upper_a", clientRequestId: requestId)
        let finished = Fixture.row(serverId, status: .complete, session: "upper_a", clientRequestId: requestId,
                                   updatedAt: Date(timeIntervalSince1970: 1_791_300_100))
        await service.script(serverId, [landed, finished])
        controller.reconcile(withLoaded: [landed])
        #expect(controller.overlay[placeholderId] == nil)
        #expect(!controller.isPendingSubmission(placeholderId))
        #expect(ActivityTimelineMerge.merge(loaded: [landed], overlay: controller.activities).count == 1)
        #expect(await waitUntil { controller.overlay[serverId]?.status == .complete })

        // Once a load catches up, the tracked copy is pruned.
        controller.reconcile(withLoaded: [finished])
        #expect(controller.overlay[serverId] == nil)
        #expect(await service.logRequests.count == 1)
    }

    @Test func discardDropsTheCardAndItsPayload() async {
        let service = FakeTrainService()
        await service.queueLog(.failure(URLError(.notConnectedToInternet)))
        let controller = Fixture.controller(service)
        let placeholderId = controller.submit(draft, localDay: Fixture.today, timezone: Fixture.timezone)
        #expect(await waitUntil { controller.overlay[placeholderId]?.isNotSent == true })
        controller.discard(placeholderId)
        #expect(controller.overlay.isEmpty)
        #expect(!controller.isPendingSubmission(placeholderId))
        controller.retry(placeholderId)
        #expect(controller.overlay.isEmpty)
        #expect(await service.logRequests.count == 1)
    }

    @Test func pollerSettlesReportsDeletionAndGivesUpAfterRepeatedErrors() async throws {
        let service = FakeTrainService()
        let id = UUID()
        await service.script(id, [
            Fixture.row(id, status: .processing), Fixture.row(id, status: .processing),
            Fixture.row(id, status: .complete),
        ])
        let updates = Recorder<ActivityStatus>()
        let settled = try await ActivityPoller.poll(
            id: id, timeout: 10, fetch: { try await service.fetchActivity(id: $0) },
            sleep: { _ in }, onUpdate: { updates.append($0.status) })
        #expect(settled?.status == .complete)
        #expect(updates.values == [.processing, .processing, .complete])

        let missing = try await ActivityPoller.poll(
            id: UUID(), timeout: 10, fetch: { try await service.fetchActivity(id: $0) },
            sleep: { _ in }, onUpdate: { _ in })
        #expect(missing == nil)

        let attempts = Recorder<Int>()
        await #expect(throws: URLError.self) {
            _ = try await ActivityPoller.poll(
                id: id, timeout: 10,
                fetch: { _ in attempts.append(1); throw URLError(.timedOut) },
                sleep: { _ in }, onUpdate: { _ in })
        }
        #expect(attempts.values.count == ActivityPollingPolicy.maximumConsecutiveErrors)

        let stuck = UUID()
        await service.script(stuck, [Fixture.row(stuck, status: .processing)])
        let clock = Recorder<Int>()
        let base = Date(timeIntervalSince1970: 0)
        let timedOut = try await ActivityPoller.poll(
            id: stuck, timeout: 150, fetch: { try await service.fetchActivity(id: $0) },
            sleep: { _ in },
            now: { clock.append(1); return base.addingTimeInterval(Double(clock.values.count - 1) * 100) },
            onUpdate: { _ in })
        #expect(timedOut?.status == .processing)
        #expect(await service.fetchCounts[stuck] == 1)
    }
}

@MainActor
struct TrainViewModelTests {
    private static func history(processingId: UUID) -> [Activity] {
        [
            Fixture.row(day: "2026-10-01", status: .complete, title: "Upper A", session: "upper_a", exercises: [
                ActivityExercise(name: "Barbell bench press", sets: [8, 8, 8, 8].map { ActivitySet(reps: $0, weight: 180) }),
            ]),
            Fixture.row(day: "2026-10-05", status: .complete, title: "Lower A", session: "lower_a", exercises: [
                ActivityExercise(name: "Back squat", sets: [7, 6, 6, 5].map { ActivitySet(reps: $0, weight: 215) }),
            ]),
            Fixture.row(processingId, day: "2026-10-06", status: .processing, title: "Upper B", session: "upper_b"),
        ]
    }

    private static func viewModel(_ service: FakeTrainService) -> TrainViewModel {
        TrainViewModel(
            profile: Fixture.profile,
            service: service,
            logging: Fixture.controller(service),
            now: { Fixture.now })
    }

    @Test func loadBuildsTheSnapshotAndTracksRowsStillProcessing() async {
        let service = FakeTrainService()
        let processingId = UUID()
        await service.setPlans(TrainingPlanState(active: Fixture.plan))
        await service.setListed(Self.history(processingId: processingId))
        await service.script(processingId, [Fixture.row(processingId, day: "2026-10-06", status: .processing,
                                                        title: "Upper B", session: "upper_b")])
        let viewModel = Self.viewModel(service)
        #expect(!viewModel.hasLoaded)
        await viewModel.load()

        #expect(viewModel.hasLoaded)
        #expect(viewModel.errorMessage == nil)
        let snapshot = viewModel.snapshot
        #expect(snapshot.activePlan?.id == Fixture.plan.id)
        #expect(snapshot.nextSession?.id == "lower_b")
        #expect(snapshot.loggedToday?.id == processingId)
        #expect(snapshot.loggedTodaySession?.name == "Upper B")
        #expect(snapshot.week.completed == 2)
        #expect(snapshot.week.target == 4)
        #expect(snapshot.recent.map(\.localDay) == ["2026-10-06", "2026-10-05", "2026-10-01"])
        #expect(snapshot.recent.first?.title == "Today")
        #expect(snapshot.recent.dropFirst().first?.title == "Yesterday")
        #expect(snapshot.personalBests.map(\.name) == ["Barbell bench press", "Back squat"])
        #expect(await waitUntil { viewModel.logging.overlay[processingId] != nil })
    }

    @Test func loggingAgainstThePlanAdvancesTheRotationOptimistically() async {
        let service = FakeTrainService()
        await service.setPlans(TrainingPlanState(active: Fixture.plan))
        await service.setListed([])
        await service.queueLog(.failure(URLError(.notConnectedToInternet)))
        let viewModel = Self.viewModel(service)
        await viewModel.load()
        #expect(viewModel.snapshot.nextSession?.id == "upper_a")
        #expect(viewModel.snapshot.nextTargets.map(\.prescription) == ["4×6–8"])

        let placeholderId = viewModel.log(
            WorkoutLogDraft(text: "upper a done", planSessionId: "upper_a"), sessionName: "Upper A")
        #expect(viewModel.snapshot.recent.first?.activities.first?.id == placeholderId)
        #expect(viewModel.snapshot.loggedToday?.id == placeholderId)
        #expect(viewModel.snapshot.nextSession?.id == "lower_a")
        #expect(viewModel.snapshot.week.completed == 1)

        // A send that fails stops counting, but the card stays for retry.
        #expect(await waitUntil { viewModel.activity(id: placeholderId)?.isNotSent == true })
        #expect(viewModel.snapshot.nextSession?.id == "upper_a")
        #expect(viewModel.snapshot.week.completed == 0)
        #expect(viewModel.snapshot.recent.first?.activities.first?.id == placeholderId)

        let discarded = await viewModel.delete(viewModel.activity(id: placeholderId)!)
        #expect(discarded)
        #expect(viewModel.activities.isEmpty)
    }

    @Test func deleteIsOptimisticAndRollsBackOnFailure() async throws {
        let service = FakeTrainService()
        let processingId = UUID()
        let rows = Self.history(processingId: processingId)
        await service.setPlans(TrainingPlanState(active: Fixture.plan))
        await service.setListed(rows)
        let viewModel = Self.viewModel(service)
        await viewModel.load()
        let target = rows[1]

        await service.setDeleteError(TrainServiceError.stillProcessing)
        let failed = await viewModel.delete(target)
        #expect(!failed)
        #expect(viewModel.activity(id: target.id) != nil)
        #expect(viewModel.errorMessage == TrainServiceError.stillProcessing.errorDescription)

        await service.setDeleteError(nil)
        let deleted = await viewModel.delete(target)
        #expect(deleted)
        #expect(viewModel.activity(id: target.id) == nil)
        #expect(await service.deleted == [target.id])
        #expect(viewModel.snapshot.week.completed == 1)
    }

    @Test func activatingADraftReusesItsRequestIdAcrossRetries() async throws {
        let service = FakeTrainService()
        var draft = Fixture.plan
        draft.id = UUID()
        draft.status = .draft
        draft.activatedAt = nil
        await service.setPlans(TrainingPlanState(active: nil, draft: draft))
        await service.setListed([])
        let viewModel = Self.viewModel(service)
        await viewModel.load()
        #expect(viewModel.snapshot.draftPlan?.id == draft.id)
        #expect(viewModel.snapshot.nextSession == nil)

        await service.queueActivation(URLError(.timedOut))
        await viewModel.activateDraft()
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.snapshot.draftPlan?.id == draft.id)

        var activated = draft
        activated.status = .active
        await service.setPlans(TrainingPlanState(active: activated, draft: nil))
        await viewModel.activateDraft()
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.snapshot.activePlan?.id == draft.id)
        #expect(viewModel.snapshot.draftPlan == nil)
        #expect(viewModel.snapshot.nextSession?.id == "upper_a")

        let activations = await service.activations
        #expect(activations.count == 2)
        #expect(activations.allSatisfy { $0.planId == draft.id })
        #expect(activations[0].clientRequestId == activations[1].clientRequestId)
    }

    @Test func aFailedLoadKeepsWhatWasShowing() async {
        let service = FakeTrainService()
        let viewModel = TrainViewModel(
            profile: Fixture.profile,
            service: FailingTrainService(),
            logging: Fixture.controller(service),
            preloadedPlans: TrainingPlanState(active: Fixture.plan),
            preloadedActivities: [Fixture.row(day: "2026-10-05", status: .complete, session: "upper_a")],
            now: { Fixture.now })
        #expect(viewModel.hasLoaded)
        await viewModel.load()
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.snapshot.activePlan?.id == Fixture.plan.id)
        #expect(viewModel.activities.count == 1)
        #expect(viewModel.snapshot.nextSession?.id == "lower_a")
    }
}

private struct FailingTrainService: TrainServing {
    func fetchActivities(fromLocalDay: String, throughLocalDay: String?, limit: Int) async throws -> [Activity] {
        throw URLError(.notConnectedToInternet)
    }
    func fetchActivity(id: UUID) async throws -> Activity? { throw URLError(.notConnectedToInternet) }
    func fetchTrainingPlans() async throws -> TrainingPlanState { throw URLError(.notConnectedToInternet) }
    func logActivity(_ request: ActivityLogRequest) async throws -> ActivityLogResult {
        throw URLError(.notConnectedToInternet)
    }
    func deleteActivity(id: UUID) async throws { throw URLError(.notConnectedToInternet) }
    func activateTrainingPlan(planId: UUID, clientRequestId: UUID) async throws {
        throw URLError(.notConnectedToInternet)
    }
    func signedActivityImageURL(path: String) async -> URL? { nil }
}
