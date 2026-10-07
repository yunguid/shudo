import Foundation
import Testing

@testable import shudo

/// Vectors from the progress research (adapted to the lean bulk 162.5 → 175 lb).
struct ProgressPolicyTests {
    private static let lb = BodyUnits.kilograms(pounds:)

    private func daily(_ values: [Double], from start: String = "2026-09-01") -> [WeightSample] {
        values.enumerated().map { offset, kg in
            WeightSample(localDay: LocalDayMath.adding(offset, to: start)!, kilograms: kg)
        }
    }

    // MARK: LocalDayMath

    @Test func localDayMathRoundTripsAndRejectsImpossibleDays() {
        #expect(LocalDayMath.days(from: "2026-10-06", to: "2027-03-30") == 175)
        #expect(LocalDayMath.adding(175, to: "2026-10-06") == "2027-03-30")
        #expect(LocalDayMath.adding(-1, to: "2026-03-01") == "2026-02-28")
        #expect(LocalDayMath.date("2026-02-31") == nil)
        #expect(LocalDayMath.date("2026-9-1") == nil)
        #expect(LocalDayMath.days(from: "2026-11-01", to: "2026-11-02") == 1)  // DST weekend
    }

    // MARK: WeightTrendPolicy

    @Test func oneSampleTrendEqualsItAndHasNoRate() throws {
        let samples = [WeightSample(localDay: "2026-10-06", kilograms: 80)]
        let summary = try #require(WeightTrendPolicy.summary(samples, today: "2026-10-06"))
        #expect(summary.trendKG == 80)
        #expect(summary.weeklyRateKG == nil)
        #expect(summary.sevenDayAverageKG == nil)
    }

    @Test func flatFortnightHasZeroRate() throws {
        let samples = daily(Array(repeating: 80, count: 14))
        let rate = try #require(WeightTrendPolicy.weeklyRate(samples, endingOn: samples.last!.localDay))
        #expect(abs(rate) < 1e-9)
    }

    @Test func steadyLossRateAndLaggingTrend() throws {
        let samples = daily((0...20).map { 80 - 0.1 * Double($0) })
        let end = samples.last!.localDay
        let rate = try #require(WeightTrendPolicy.weeklyRate(samples, endingOn: end))
        #expect(abs(rate - -0.7) < 0.001)
        let trend = try #require(WeightTrendPolicy.smoothed(samples).last)
        #expect(trend.trend > trend.raw)
    }

    @Test func gapAwareSmoothingUsesEffectiveAlpha() throws {
        let samples = [
            WeightSample(localDay: "2026-09-01", kilograms: 80),
            WeightSample(localDay: "2026-09-08", kilograms: 79),
        ]
        let last = try #require(WeightTrendPolicy.smoothed(samples).last)
        // α_eff = 1 − 0.9⁷
        #expect(abs(last.trend - 79.478) < 0.001)
    }

    @Test func outlierInfluenceIsClamped() throws {
        let samples = daily(Array(repeating: 80, count: 14) + [86])
        let last = try #require(WeightTrendPolicy.smoothed(samples).last)
        #expect(abs(last.trend - 80.25) < 1e-9)
    }

    @Test func rateNeedsFiveSamplesSpanningTenDays() {
        let fourIn21 = ["2026-09-10", "2026-09-15", "2026-09-22", "2026-09-30"]
            .map { WeightSample(localDay: $0, kilograms: 80) }
        #expect(WeightTrendPolicy.weeklyRate(fourIn21, endingOn: "2026-09-30") == nil)

        let fiveOverNine = ["2026-09-21", "2026-09-23", "2026-09-25", "2026-09-28", "2026-09-30"]
            .map { WeightSample(localDay: $0, kilograms: 80) }
        #expect(WeightTrendPolicy.weeklyRate(fiveOverNine, endingOn: "2026-09-30") == nil)

        let fiveOverTen = ["2026-09-20", "2026-09-23", "2026-09-25", "2026-09-28", "2026-09-30"]
            .map { WeightSample(localDay: $0, kilograms: 80) }
        #expect(WeightTrendPolicy.weeklyRate(fiveOverTen, endingOn: "2026-09-30") != nil)
    }

    @Test func rateWindowIgnoresOldWeighIns() {
        let old = daily([80, 80.1, 80.2, 80.3, 80.4, 80.5, 80.6, 80.7, 80.8, 80.9, 81], from: "2026-08-01")
        #expect(WeightTrendPolicy.weeklyRate(old, endingOn: "2026-10-06") == nil)
    }

    @Test func sevenDayAverageNeedsThreeWeighInsThisWeek() throws {
        let samples = [
            WeightSample(localDay: "2026-09-20", kilograms: 74),
            WeightSample(localDay: "2026-10-01", kilograms: 74.2),
            WeightSample(localDay: "2026-10-04", kilograms: 74.6),
        ]
        let two = try #require(WeightTrendPolicy.summary(samples, today: "2026-10-06"))
        #expect(two.weighInsLast7 == 2)
        #expect(two.sevenDayAverageKG == nil)

        let three = try #require(
            WeightTrendPolicy.summary(samples + [WeightSample(localDay: "2026-10-06", kilograms: 74.4)], today: "2026-10-06"))
        #expect(three.weighInsLast7 == 3)
        #expect(abs((three.sevenDayAverageKG ?? 0) - 74.4) < 1e-9)
    }

    @Test func samplesSkipPhotoOnlyCheckIns() {
        let now = Date()
        let checkIns = [
            WeightCheckIn(
                id: UUID(), localDay: "2026-10-06", weightKG: nil,
                progressPhotoPath: "u/2026-10-06/p.jpg", createdAt: now, updatedAt: now),
            WeightCheckIn(
                id: UUID(), localDay: "2026-10-05", weightKG: 74, progressPhotoPath: nil,
                createdAt: now, updatedAt: now),
        ]
        #expect(WeightTrendPolicy.samples(from: checkIns) == [WeightSample(localDay: "2026-10-05", kilograms: 74)])
    }

    // MARK: TrajectoryPolicy (today 2026-10-06; bulk to 175 lb; trend 162.5; planned +0.5 lb/wk)

    private func bulk(targetDay: String? = nil) -> BodyGoal {
        BodyGoal(
            phase: .bulk, startWeightKG: Self.lb(162.5), targetWeightKG: Self.lb(175),
            startDay: "2026-10-06", targetDay: targetDay)
    }

    private func trend(pounds: Double, ratePounds: Double?) -> WeightTrendSummary {
        WeightTrendSummary(
            latestDay: "2026-10-06", latestKG: Self.lb(pounds), trendKG: Self.lb(pounds),
            weeklyRateKG: ratePounds.map(Self.lb), sevenDayAverageKG: nil, weighInsLast7: 3,
            sampleCount: 8)
    }

    private func evaluate(_ goal: BodyGoal, pounds: Double = 162.5, rate: Double?) -> Trajectory {
        TrajectoryPolicy.evaluate(
            goal: goal, trend: trend(pounds: pounds, ratePounds: rate), fallbackWeightKG: nil,
            today: "2026-10-06")
    }

    @Test func onPaceBulkProjectsTheGoalDay() {
        let result = evaluate(bulk(), rate: 0.5)
        #expect(result.status == .onPace)
        #expect(result.projectedDay == "2027-03-30")
        #expect(
            TrajectoryPolicy.sentence(result, goal: bulk(), units: "imperial")
                == "At +0.5 lb/wk you hit 175 lb around Mar 30, 2027.")
    }

    @Test func deadlineReportsRequiredRateAndLateness() throws {
        let goal = bulk(targetDay: "2027-03-01")
        let result = evaluate(goal, rate: 0.5)
        let required = try #require(result.requiredRateKG)
        #expect(abs(BodyUnits.pounds(required) - 0.599) < 0.001)
        #expect(result.daysLate == 29)
    }

    @Test func losingOnABulkIsWrongDirectionWithoutProjection() {
        let result = evaluate(bulk(), rate: -0.3)
        #expect(result.status == .wrongDirection)
        #expect(result.projectedDay == nil)
    }

    @Test func overHalfPercentBodyweightIsTooFast() {
        #expect(evaluate(bulk(), pounds: 163, rate: 1.0).status == .tooFast)
        #expect(evaluate(bulk(), pounds: 163, rate: 0.8).status == .ahead)
    }

    @Test func slowAndFlatBulksAreBehindAndStalled() {
        #expect(evaluate(bulk(), rate: 0.1).status == .behind)
        #expect(evaluate(bulk(), rate: 0.02).status == .stalled)
        #expect(evaluate(bulk(), rate: -0.02).status == .stalled)
        #expect(evaluate(bulk(), rate: 0.25).status == .onPace)
        #expect(evaluate(bulk(), rate: 0.75).status == .onPace)
    }

    @Test func reachingTheTargetIsGoalReached() {
        #expect(evaluate(bulk(), pounds: 175, rate: 0.4).status == .goalReached)
        #expect(evaluate(bulk(), pounds: 176, rate: nil).status == .goalReached)
    }

    @Test func noWeighInsFallsBackToTheSelfReportedWeight() throws {
        let result = TrajectoryPolicy.evaluate(
            goal: bulk(), trend: nil, fallbackWeightKG: Self.lb(162.5), today: "2026-10-06")
        #expect(result.status == .insufficientData)
        #expect(result.currentIsSelfReported)
        let remaining = try #require(result.remainingKG)
        #expect(abs(BodyUnits.pounds(remaining) - 12.5) < 1e-9)
        #expect(
            TrajectoryPolicy.sentence(result, goal: bulk(), units: "imperial")
                == "12.5 lb to 175 lb. Weigh-ins start when your scale lands.")
    }

    @Test func projectionsBeyondTwoYearsAreDropped() {
        let result = evaluate(bulk(), rate: 0.06)
        #expect(result.status == .behind)
        #expect(result.projectedDay == nil)
    }

    @Test func noTargetIsNoGoal() {
        let goal = BodyGoal(phase: .bulk, startWeightKG: 74)
        #expect(
            TrajectoryPolicy.evaluate(goal: goal, trend: nil, fallbackWeightKG: 74, today: "2026-10-06").status
                == .noGoal)
    }

    @Test func laneRunsQuarterToThreeQuarterPoundsPerWeek() throws {
        let lane = TrajectoryPolicy.lane(goal: bulk(), weeks: 4)
        #expect(lane.count == 5)
        let last = try #require(lane.last)
        #expect(last.day == "2026-11-03")
        #expect(abs(BodyUnits.pounds(last.low) - 163.5) < 1e-6)
        #expect(abs(BodyUnits.pounds(last.high) - 165.5) < 1e-6)
    }

    // MARK: StreakPolicy

    @Test func streakCountsThroughTodayOrYesterday() {
        #expect(StreakPolicy.current(days: ["2026-10-04", "2026-10-05", "2026-10-06"], today: "2026-10-06") == 3)
        #expect(StreakPolicy.current(days: ["2026-10-04", "2026-10-05"], today: "2026-10-06") == 2)
        #expect(StreakPolicy.isAtRisk(days: ["2026-10-04", "2026-10-05"], today: "2026-10-06"))
        #expect(StreakPolicy.current(days: ["2026-10-03", "2026-10-04"], today: "2026-10-06") == 0)
        #expect(StreakPolicy.current(days: [], today: "2026-10-06") == 0)
        #expect(StreakPolicy.current(days: ["2026-02-28", "2026-03-01"], today: "2026-03-01") == 2)
    }

    @Test func photoOnlyAndWeightOnlyDaysBothCountAsCheckIns() {
        let now = Date()
        let days = StreakPolicy.checkInDays([
            WeightCheckIn(id: UUID(), localDay: "2026-10-06", weightKG: nil, progressPhotoPath: "p", createdAt: now, updatedAt: now),
            WeightCheckIn(id: UUID(), localDay: "2026-10-05", weightKG: 74, progressPhotoPath: nil, createdAt: now, updatedAt: now),
        ])
        #expect(days == ["2026-10-05", "2026-10-06"])
    }

    // MARK: AdherencePolicy (bulk, 2,900 kcal / 175 g protein)

    private let target = MacroTarget(caloriesKcal: 2_900, proteinG: 175, carbsG: 365, fatG: 82)

    private func day(kcal: Double, protein: Double = 175, entries: Int = 3) -> DailyNutritionTotal {
        DailyNutritionTotal(localDay: "2026-10-05", proteinG: protein, carbsG: 300, fatG: 80, caloriesKcal: kcal, entryCount: entries)
    }

    @Test func bulkCalorieBandBoundaries() {
        func calories(_ kcal: Double) -> FuelDay.Calories? {
            AdherencePolicy.day(total: day(kcal: kcal), target: target, phase: .bulk)?.calories
        }
        #expect(calories(2_700) == .under)
        #expect(calories(2_755) == .onPlan)
        #expect(calories(3_335) == .onPlan)
        #expect(calories(3_350) == .over)
    }

    @Test func proteinHitIsNinetyPercent() {
        #expect(AdherencePolicy.day(total: day(kcal: 2_900, protein: 157), target: target, phase: .bulk)?.proteinHit == false)
        #expect(AdherencePolicy.day(total: day(kcal: 2_900, protein: 158), target: target, phase: .bulk)?.proteinHit == true)
    }

    @Test func unloggedDaysAreNotScoredAndTodayIsPending() throws {
        #expect(AdherencePolicy.day(total: nil, target: target, phase: .bulk) == nil)
        #expect(AdherencePolicy.day(total: day(kcal: 0, entries: 0), target: target, phase: .bulk) == nil)
        #expect(AdherencePolicy.level(nil) == 0)
        let today = try #require(AdherencePolicy.day(total: day(kcal: 1_200, protein: 90), target: target, phase: .bulk, isToday: true))
        #expect(today.isPending)
    }

    @Test func fuelLevelsRewardHittingBoth() throws {
        let both = try #require(AdherencePolicy.day(total: day(kcal: 2_950, protein: 180), target: target, phase: .bulk))
        #expect(AdherencePolicy.level(both) == 4)
        let neither = try #require(AdherencePolicy.day(total: day(kcal: 2_000, protein: 120), target: target, phase: .bulk))
        #expect(AdherencePolicy.level(neither) == 1)
        let proteinOnly = try #require(AdherencePolicy.day(total: day(kcal: 2_700, protein: 180), target: target, phase: .bulk))
        #expect(AdherencePolicy.level(proteinOnly) == 3)
        let farUnder = try #require(AdherencePolicy.day(total: day(kcal: 1_500, protein: 180), target: target, phase: .bulk))
        #expect(AdherencePolicy.level(farUnder) == 2)
        // A cut reads 2,700 as on plan.
        #expect(AdherencePolicy.day(total: day(kcal: 2_700), target: target, phase: .cut)?.calories == .onPlan)
    }

    // MARK: Barbell meter

    @Test func barbellLoadsOnePlatePairPerTwoAndAHalfPounds() {
        #expect(BarbellMeter.slots(goalPounds: 12.5) == 5)
        #expect(abs(BarbellMeter.filled(gainedPounds: 4.5, goalPounds: 12.5) - 1.8) < 1e-9)
        #expect(BarbellMeter.filled(gainedPounds: -1, goalPounds: 12.5) == 0)
        #expect(BarbellMeter.filled(gainedPounds: 20, goalPounds: 12.5) == 5)
        #expect(BarbellMeter.slots(goalPounds: 60) == 8)
    }
}
