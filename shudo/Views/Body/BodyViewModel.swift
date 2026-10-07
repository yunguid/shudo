import SwiftUI
import UIKit

/// Everything the Body screen renders, derived deterministically from the
/// loaded rows (pure; unit-tested through the policies it composes).
struct BodySnapshot: Equatable {
    var today: String
    var units: String
    var todayCheckIn: WeightCheckIn?
    /// Photo check-ins, newest first.
    var photoCheckIns: [WeightCheckIn]
    /// Latest photo before today: the camera's ghost overlay.
    var ghostCheckIn: WeightCheckIn?
    var trendPoints: [WeightTrendPoint]
    var trend: WeightTrendSummary?
    var goal: BodyGoal?
    var trajectory: Trajectory
    var streak: Int
    var streakAtRisk: Bool
    /// Day N of the current goal (1-based), when its start is known.
    var dayNumber: Int?
    var weighInCount: Int { trendPoints.count }
    var showsTrendChart: Bool { weighInCount >= WeightTrendPolicy.minChartSamples }

    /// The barbell meter's start/current/target in kg.
    var meterStartKG: Double? { goal?.startWeightKG }
    var meterTargetKG: Double? { goal?.targetWeightKG }
    var meterCurrentKG: Double? { trend?.trendKG ?? goal?.startWeightKG }

    static func make(
        profile: Profile,
        settings: BodyGoalSettings,
        checkIns: [WeightCheckIn],
        today: String
    ) -> BodySnapshot {
        let ordered = checkIns.sorted { $0.localDay > $1.localDay }
        let samples = WeightTrendPolicy.samples(from: ordered)
        let trend = WeightTrendPolicy.summary(samples, today: today)
        let photos = ordered.filter(\.hasPhoto)
        let goal = makeGoal(profile: profile, settings: settings, samples: samples, checkIns: ordered, today: today)
        let days = StreakPolicy.checkInDays(ordered)
        let dayNumber = goal?.startDay.flatMap { LocalDayMath.days(from: $0, to: today) }.map { max($0 + 1, 1) }
        return BodySnapshot(
            today: today,
            units: profile.units,
            todayCheckIn: ordered.first { $0.localDay == today },
            photoCheckIns: photos,
            ghostCheckIn: photos.first { $0.localDay < today } ?? photos.first,
            trendPoints: WeightTrendPolicy.smoothed(samples),
            trend: trend,
            goal: goal,
            trajectory: TrajectoryPolicy.evaluate(
                goal: goal,
                trend: trend,
                fallbackWeightKG: goal?.startWeightKG ?? settings.selfReportedWeightKG ?? profile.weightKG,
                today: today
            ),
            streak: StreakPolicy.current(days: days, today: today),
            streakAtRisk: StreakPolicy.isAtRisk(days: days, today: today),
            dayNumber: dayNumber
        )
    }

    /// Goal anchor fallbacks, in order: the stored 2.0 anchor, the first
    /// weigh-in, the self-reported profile weight.
    static func makeGoal(
        profile: Profile,
        settings: BodyGoalSettings,
        samples: [WeightSample],
        checkIns: [WeightCheckIn],
        today: String
    ) -> BodyGoal? {
        let target = settings.targetWeightKG ?? profile.targetWeightKG
        guard target != nil || settings.goalType != .maintain else { return nil }
        let firstDay = checkIns.map(\.localDay).min()
        return BodyGoal(
            phase: GoalPhase(goalType: settings.goalType),
            startWeightKG: settings.goalStartWeightKG ?? samples.first?.kilograms
                ?? settings.selfReportedWeightKG ?? profile.weightKG,
            targetWeightKG: target,
            startDay: settings.goalStartedOn ?? firstDay.map { min($0, today) } ?? today,
            targetDay: settings.goalDate
        )
    }
}

@MainActor
final class BodyViewModel: ObservableObject {
    @Published private(set) var profile: Profile
    @Published private(set) var settings: BodyGoalSettings
    @Published private(set) var checkIns: [WeightCheckIn] = []
    @Published private(set) var nutrition = BodyNutritionHistory()
    @Published private(set) var summaries: [WeeklyInsightSummary] = []
    @Published private(set) var snapshot: BodySnapshot
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published var errorMessage: String?

    let service: any BodyServicing
    let photos: BodyPhotoLoader
    private let fixedToday: String?
    private let loadsRemotely: Bool
    private var didAttemptAnchor = false

    init(profile: Profile, service: any BodyServicing = LiveBodyService()) {
        self.profile = profile
        self.service = service
        photos = BodyPhotoLoader(service: service)
        settings = BodyGoalSettings(profile: profile)
        fixedToday = nil
        loadsRemotely = true
        snapshot = BodySnapshot.make(
            profile: profile,
            settings: BodyGoalSettings(profile: profile),
            checkIns: [],
            today: LocalDayMath.today(in: profile.timezone)
        )
    }

    #if DEBUG
        init(
            previewProfile: Profile,
            settings: BodyGoalSettings,
            checkIns: [WeightCheckIn],
            nutrition: BodyNutritionHistory,
            summaries: [WeeklyInsightSummary],
            service: any BodyServicing,
            today: String
        ) {
            profile = previewProfile
            self.settings = settings
            self.checkIns = checkIns
            self.nutrition = nutrition
            self.summaries = summaries
            self.service = service
            photos = BodyPhotoLoader(service: service)
            fixedToday = today
            loadsRemotely = false
            hasLoaded = true
            snapshot = BodySnapshot.make(
                profile: previewProfile, settings: settings, checkIns: checkIns, today: today)
        }
    #endif

    var today: String { fixedToday ?? LocalDayMath.today(in: profile.timezone) }
    var units: String { profile.units }
    var phase: GoalPhase { GoalPhase(goalType: settings.goalType) }

    func load() async {
        guard loadsRemotely, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let checkInsTask = service.checkIns(limit: 400)
        async let settingsTask = service.goalSettings()
        async let nutritionTask = service.nutrition(timezone: profile.timezone)
        async let summariesTask = service.weeklySummaries(limit: 12)

        do {
            checkIns = try await checkInsTask
            errorMessage = nil
        } catch {
            if !hasLoaded { errorMessage = "Couldn’t load your check-ins. Pull to retry." }
        }
        if let loaded = try? await settingsTask { settings = loaded }
        if let loaded = try? await nutritionTask { nutrition = loaded }
        if let loaded = try? await summariesTask { summaries = loaded }
        hasLoaded = true
        recompute()
        await anchorGoalIfNeeded()
    }

    func applySaved(_ checkIn: WeightCheckIn) {
        checkIns.removeAll { $0.localDay == checkIn.localDay || $0.id == checkIn.id }
        checkIns.append(checkIn)
        checkIns.sort { $0.localDay > $1.localDay }
        recompute()
    }

    func removePhoto(_ checkIn: WeightCheckIn) async {
        do {
            let remaining = try await service.removePhoto(checkIn)
            checkIns.removeAll { $0.id == checkIn.id }
            if let remaining { checkIns.append(remaining) }
            checkIns.sort { $0.localDay > $1.localDay }
            recompute()
        } catch {
            errorMessage = "Couldn’t remove that photo. Try again."
        }
    }

    /// Profiles from before 2.0 have no goal anchor; without one the barbell
    /// meter would drift every time `profiles.weight_kg` moves. Lock it once.
    private func anchorGoalIfNeeded() async {
        guard !didAttemptAnchor, settings.goalStartWeightKG == nil, settings.goalType != .maintain,
            let start = snapshot.goal?.startWeightKG, let day = snapshot.goal?.startDay
        else { return }
        didAttemptAnchor = true
        do {
            try await service.anchorGoal(startedOn: day, startWeightKG: start)
            settings.goalStartWeightKG = (start * 100).rounded() / 100
            if settings.goalStartedOn == nil { settings.goalStartedOn = day }
            recompute()
        } catch {
            // Older servers lack the columns; the derived fallback still renders.
        }
    }

    private func recompute() {
        snapshot = BodySnapshot.make(profile: profile, settings: settings, checkIns: checkIns, today: today)
    }
}
