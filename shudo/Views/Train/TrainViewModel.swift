import Combine
import Foundation

struct ActivityDayGroup: Identifiable, Equatable {
    var localDay: String
    var title: String
    var activities: [Activity]

    var id: String { localDay }
}

/// Everything the Train screen renders, derived in one pure pass from the
/// plan rows and the merged activity history.
struct TrainSnapshot: Equatable {
    var activePlan: TrainingPlan?
    var draftPlan: TrainingPlan?
    var nextSession: TrainingSession?
    var nextTargets: [LiftTarget]
    /// The plan session already logged today (newest), if any.
    var loggedToday: Activity?
    var loggedTodaySession: TrainingSession?
    var week: TrainingWeekProgress
    var personalBests: [PersonalBest]
    var recent: [ActivityDayGroup]
    var totalActivityCount: Int

    static let empty = TrainSnapshot(
        activePlan: nil, draftPlan: nil, nextSession: nil, nextTargets: [], loggedToday: nil,
        loggedTodaySession: nil, week: .empty, personalBests: [], recent: [], totalActivityCount: 0)

    static func make(
        plans: TrainingPlanState,
        activities: [Activity],
        now: Date,
        timezone: String,
        units: String,
        recentLimit: Int
    ) -> TrainSnapshot {
        let today = TrainCalendar.localDay(for: now, timezone: timezone)
        let plan = plans.active?.plan
        let next = plan.flatMap { SessionRotationPolicy.nextSession(plan: $0, activities: activities) }
        let targets = next.map {
            DoubleProgressionPolicy.targets(
                for: $0, history: activities, preferredUnit: WeightUnit(preference: units))
        } ?? []
        let loggedToday = activities
            .filter { $0.localDay == today && $0.planSessionId != nil && $0.countsTowardHistory }
            .max { $0.occurredAt < $1.occurredAt }
        let freshSince = TrainCalendar.adding(days: -6, to: today, timezone: timezone)
        return TrainSnapshot(
            activePlan: plans.active,
            draftPlan: plans.draft,
            nextSession: next,
            nextTargets: targets,
            loggedToday: loggedToday,
            loggedTodaySession: loggedToday?.planSessionId.flatMap { plan?.session(id: $0) },
            week: TrainingWeekPolicy.progress(activities: activities, plan: plan, now: now, timezone: timezone),
            personalBests: PRPolicy.board(
                from: activities, freshSince: freshSince, priority: PRPolicy.priorityLifts(for: plan)),
            recent: dayGroups(Array(activities.prefix(recentLimit)), today: today, timezone: timezone),
            totalActivityCount: activities.count
        )
    }

    static func dayGroups(_ activities: [Activity], today: String, timezone: String) -> [ActivityDayGroup] {
        let yesterday = TrainCalendar.adding(days: -1, to: today, timezone: timezone)
        var groups: [ActivityDayGroup] = []
        for activity in activities {
            if let index = groups.firstIndex(where: { $0.localDay == activity.localDay }) {
                groups[index].activities.append(activity)
            } else {
                let title: String
                if activity.localDay == today {
                    title = "Today"
                } else if activity.localDay == yesterday {
                    title = "Yesterday"
                } else {
                    title = displayTitle(localDay: activity.localDay)
                }
                groups.append(ActivityDayGroup(localDay: activity.localDay, title: title, activities: [activity]))
            }
        }
        return groups
    }

    /// "Mon, Oct 5" — formatted from a noon anchor in the device timezone so
    /// the calendar day never shifts.
    static func displayTitle(localDay: String) -> String {
        let parts = localDay.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return localDay }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        guard let date = Calendar(identifier: .gregorian).date(from: components) else { return localDay }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// Owns the Train tab: plan rows, activity history, optimistic logging,
/// deletes and plan activation. Views read `snapshot`.
@MainActor
final class TrainViewModel: ObservableObject {
    @Published private(set) var snapshot: TrainSnapshot = .empty
    @Published private(set) var plans = TrainingPlanState()
    /// Server rows merged with locally tracked ones, newest first.
    @Published private(set) var activities: [Activity] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published private(set) var isActivatingPlan = false
    @Published var errorMessage: String?

    let logging: ActivityLoggingController
    private let service: any TrainServing
    private let now: () -> Date
    private(set) var profile: Profile
    private var loadedActivities: [Activity] = []
    private var overlay: [UUID: Activity] = [:]
    private var recentLimit = TrainViewModel.recentPageSize
    private var loadGeneration = UUID()
    private var lastLoadedAt: Date?
    private var activationRequestIds: [UUID: UUID] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// History window for rotation, targets, the ring and the PR board.
    static let historyDays = 180
    static let historyRowLimit = 600
    static let recentPageSize = 12

    init(
        profile: Profile,
        service: any TrainServing = SupabaseService(),
        logging: ActivityLoggingController? = nil,
        preloadedPlans: TrainingPlanState? = nil,
        preloadedActivities: [Activity]? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.profile = profile
        self.service = service
        self.logging = logging ?? ActivityLoggingController(service: service)
        self.now = now
        self.overlay = self.logging.overlay
        if let preloadedPlans { plans = preloadedPlans }
        if let preloadedActivities {
            loadedActivities = ActivityTimelineMerge.sorted(preloadedActivities)
            hasLoaded = true
        }
        rebuild()
        self.logging.$overlay
            .dropFirst()
            .sink { [weak self] overlay in
                guard let self else { return }
                self.overlay = overlay
                self.rebuild()
            }
            .store(in: &cancellables)
        if preloadedActivities != nil {
            for row in loadedActivities where row.status == .processing {
                self.logging.track(row)
            }
        }
    }

    var timezone: String { profile.timezone }
    var units: String { profile.units }
    var todayLocalDay: String { TrainCalendar.localDay(for: now(), timezone: timezone) }
    var canShowMoreRecent: Bool { snapshot.totalActivityCount > recentLimit }

    func applyProfile(_ updated: Profile) {
        profile = updated
        rebuild()
    }

    func activity(id: UUID) -> Activity? {
        activities.first { $0.id == id }
    }

    func showMoreRecent() {
        recentLimit += 20
        rebuild()
    }

    // MARK: Loading

    func load() async {
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        defer { if loadGeneration == generation { isLoading = false } }
        let today = todayLocalDay
        let from = TrainCalendar.adding(days: -Self.historyDays, to: today, timezone: timezone) ?? today
        let service = self.service
        let limit = Self.historyRowLimit
        async let fetchedPlans = Self.capture { try await service.fetchTrainingPlans() }
        async let fetchedActivities = Self.capture {
            try await service.fetchActivities(fromLocalDay: from, throughLocalDay: nil, limit: limit)
        }
        let (planResult, activityResult) = await (fetchedPlans, fetchedActivities)
        guard loadGeneration == generation else { return }

        var failures: [Error] = []
        switch planResult {
        case .success(let state): plans = state
        case .failure(let error): failures.append(error)
        }
        switch activityResult {
        case .success(let rows):
            loadedActivities = ActivityTimelineMerge.sorted(rows)
            logging.reconcile(withLoaded: rows)
            hasLoaded = true
            lastLoadedAt = now()
        case .failure(let error): failures.append(error)
        }
        errorMessage = failures.isEmpty ? nil : "Couldn’t refresh training. Pull down to try again."
        rebuild()
    }

    func refresh() async { await load() }

    /// Reloads when the tab reappears or the app returns to the foreground
    /// and the data is older than `maxAge` — workouts logged by the coach
    /// from chat arrive this way.
    func refreshIfStale(maxAge: TimeInterval = 60) async {
        guard !isLoading else { return }
        if let lastLoadedAt, now().timeIntervalSince(lastLoadedAt) < maxAge { return }
        await load()
    }

    nonisolated private static func capture<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }

    // MARK: Logging

    /// Accepts a workout immediately (the sheet dismisses on the spot); the
    /// upload, retries and polling are owned by `logging`.
    @discardableResult
    func log(_ draft: WorkoutLogDraft, sessionName: String? = nil) -> UUID {
        logging.submit(draft, localDay: todayLocalDay, timezone: timezone, sessionName: sessionName)
    }

    func retry(_ activity: Activity) {
        logging.retry(activity.id)
    }

    /// Deletes a workout. Local cards that never reached the server are just
    /// dropped; server rows are removed optimistically and restored if the
    /// delete fails.
    @discardableResult
    func delete(_ activity: Activity) async -> Bool {
        if activity.isLocalOnly {
            logging.discard(activity.id)
            return true
        }
        let previous = loadedActivities
        loadedActivities.removeAll { $0.id == activity.id }
        logging.forget(activity.id)
        rebuild()
        do {
            try await service.deleteActivity(id: activity.id)
            return true
        } catch {
            loadedActivities = previous
            if activity.status == .processing { logging.track(activity) }
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "Couldn’t delete that workout. Please try again."
            rebuild()
            return false
        }
    }

    // MARK: Plan

    /// Runs the draft plan via the coach_chat card action. The same
    /// client_request_id is reused if the first attempt fails ambiguously.
    func activateDraft() async {
        guard let draft = plans.draft, !isActivatingPlan else { return }
        isActivatingPlan = true
        defer { isActivatingPlan = false }
        let requestId = activationRequestIds[draft.id] ?? UUID()
        activationRequestIds[draft.id] = requestId
        do {
            try await service.activateTrainingPlan(planId: draft.id, clientRequestId: requestId)
            var promoted = draft
            promoted.status = .active
            promoted.activatedAt = now()
            plans = TrainingPlanState(active: promoted, draft: nil)
            errorMessage = nil
            rebuild()
            if let fresh = try? await service.fetchTrainingPlans() {
                plans = fresh
                rebuild()
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn’t start that plan. Try again."
        }
    }

    func imageURL(for activity: Activity) async -> URL? {
        guard let path = activity.imagePath else { return nil }
        return await service.signedActivityImageURL(path: path)
    }

    /// Client-side PRs for a row the server didn't flag (display only).
    func fallbackPRs(for activity: Activity) -> [ActivityPR] {
        guard activity.prs.isEmpty, activity.status == .complete else { return [] }
        return PRPolicy.detectPRs(in: activity, history: activities, displayUnit: WeightUnit(preference: units))
    }

    // MARK: Derivation

    private func rebuild() {
        activities = ActivityTimelineMerge.merge(loaded: loadedActivities, overlay: Array(overlay.values))
        snapshot = TrainSnapshot.make(
            plans: plans,
            activities: activities,
            now: now(),
            timezone: timezone,
            units: units,
            recentLimit: recentLimit
        )
    }
}
