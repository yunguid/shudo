import Foundation

/// Everything the Today thread shows besides meals and coach messages: the
/// selected day's workouts, the body check-ins (the day's card + the
/// fallback weigh-in reminder), the week's day totals for the header's
/// week strip, and the goal anchor for "Day 35 of the bulk".
@MainActor
final class TodayDayContext: ObservableObject {
    @Published private(set) var localDay: String
    /// Server rows for `localDay` (the logging overlay is merged at render).
    @Published private(set) var serverActivities: [Activity] = []
    /// Newest first, ~60 days.
    @Published private(set) var checkIns: [WeightCheckIn] = []
    @Published private(set) var dayTotals: [DailyNutritionTotal] = []
    @Published private(set) var targetHistory: [DailyMacroTargetSnapshot] = []
    @Published private(set) var goal: BodyGoalSettings?

    private let train: any TrainServing
    private let body: any BodyServicing
    private let timezone: () -> String
    private var activityGeneration = UUID()
    private var weekTask: Task<Void, Never>?

    init(
        localDay: String,
        train: any TrainServing,
        body: any BodyServicing,
        timezone: @escaping () -> String
    ) {
        self.localDay = localDay
        self.train = train
        self.body = body
        self.timezone = timezone
    }

    /// The day's check-in (photo and/or weight), if any.
    var checkIn: WeightCheckIn? { checkIns.first { $0.localDay == localDay } }

    /// Server rows overlaid with the shared logging controller's local and
    /// tracked rows for the same day, oldest first.
    func activities(overlay: [Activity]) -> [Activity] {
        ActivityTimelineMerge
            .merge(loaded: serverActivities, overlay: overlay.filter { $0.localDay == localDay })
            .reversed()
    }

    func load(localDay day: String) async {
        if day != localDay {
            localDay = day
            serverActivities = []
        }
        let generation = UUID()
        activityGeneration = generation
        guard let rows = try? await train.fetchActivities(localDay: day) else { return }
        guard activityGeneration == generation, localDay == day else { return }
        serverActivities = rows
    }

    func refreshAll() async {
        async let activities: Void = load(localDay: localDay)
        async let checkIns: Void = refreshCheckIns()
        async let goal: Void = refreshGoal()
        async let week: Void = refreshWeek()
        _ = await (activities, checkIns, goal, week)
    }

    func refreshCheckIns() async {
        guard let rows = try? await body.checkIns(limit: 60) else { return }
        checkIns = rows
    }

    func refreshGoal() async {
        guard let settings = try? await body.goalSettings() else { return }
        goal = settings
    }

    func refreshWeek() async {
        guard let history = try? await body.nutrition(timezone: timezone()) else { return }
        dayTotals = history.totals
        targetHistory = history.targetHistory
    }

    /// Totals move when a meal finishes analyzing; refresh the week strip
    /// shortly after, without hammering the view during 650 ms polls.
    func scheduleWeekRefresh(after seconds: Double = 3) {
        weekTask?.cancel()
        weekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.refreshWeek()
        }
    }

    /// A check-in saved anywhere (Body tab, capture bar) shows immediately.
    func upsert(_ checkIn: WeightCheckIn) {
        checkIns.removeAll { $0.localDay == checkIn.localDay }
        checkIns.append(checkIn)
        checkIns.sort { $0.localDay > $1.localDay }
    }

    func remove(activityId: UUID) {
        serverActivities.removeAll { $0.id == activityId }
    }
}
