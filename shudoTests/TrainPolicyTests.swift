import Foundation
import Testing
@testable import shudo

/// Pure Train policies: e1RM, lift identity, rotation, double progression,
/// PRs, the week strip, polling cadence, list merging and card copy.
struct TrainPolicyTests {
    private static let timezone = "America/New_York"

    /// Tuesday 2026-10-06, noon in New York (week runs Mon 10/5 – Sun 10/11).
    private static let now = TrainDateParser.parse("2026-10-06T16:00:00Z")!

    private static func at(_ localDay: String, hour: Int = 18) -> Date {
        let start = TrainCalendar.date(fromLocalDay: localDay, timezone: timezone)!
        return start.addingTimeInterval(TimeInterval(hour * 3_600))
    }

    private static func activity(
        _ localDay: String,
        hour: Int = 18,
        kind: ActivityKind = .strength,
        session: String? = nil,
        status: ActivityStatus = .complete,
        exercises: [ActivityExercise] = [],
        localState: ActivityLocalState? = nil,
        clientRequestId: UUID? = nil,
        updatedAt: Date? = nil
    ) -> Activity {
        Activity(
            id: UUID(),
            clientRequestId: clientRequestId,
            localDay: localDay,
            occurredAt: at(localDay, hour: hour),
            status: status,
            kind: kind,
            title: session ?? kind.label,
            details: ActivityDetails(exercises: exercises, planSessionId: session),
            updatedAt: updatedAt,
            localState: localState)
    }

    private static func lift(_ name: String, _ weight: Double?, _ reps: [Int], key: String? = nil, unit: WeightUnit = .lb) -> ActivityExercise {
        ActivityExercise(name: name, key: key, sets: reps.map { ActivitySet(reps: $0, weight: weight, unit: unit) })
    }

    private static let bench = PlannedExercise(
        name: "Barbell bench press", key: "barbell_bench_press", sets: 4, repMin: 6, repMax: 8, incrementLb: 5)

    // MARK: Strength math

    @Test func epleyEstimatesOneRepMaxWithinItsReliableRange() throws {
        let e1rm = try #require(StrengthMath.e1rm(weight: 185, reps: 8))
        #expect(abs(e1rm - 234.333) < 0.01)
        #expect(StrengthMath.e1rm(weight: 225, reps: 1) == 225)
        #expect(StrengthMath.e1rm(weight: 100, reps: 12) != nil)
        #expect(StrengthMath.e1rm(weight: 100, reps: 13) == nil)
        #expect(StrengthMath.e1rm(weight: 0, reps: 5) == nil)
        #expect(StrengthMath.e1rm(weight: 100, reps: 0) == nil)

        let kilograms = try #require(StrengthMath.e1rmPounds(ActivitySet(reps: 5, weight: 100, unit: .kg)))
        #expect(abs(kilograms - 257.206) < 0.01)
        #expect(StrengthMath.e1rmPounds(ActivitySet(reps: 5, weight: 135, isWarmup: true)) == nil)
        #expect(StrengthMath.e1rmPounds(ActivitySet(reps: 12, weight: nil)) == nil)
    }

    @Test func weightsFormatWithoutNoise() {
        #expect(StrengthMath.formatWeight(185) == "185")
        #expect(StrengthMath.formatWeight(92.5) == "92.5")
        #expect(StrengthMath.formatWeight(184.99) == "185")
        #expect(StrengthMath.kilogramIncrement(fromPounds: 5) == 2.5)
        #expect(StrengthMath.kilogramIncrement(fromPounds: 10) == 5)
        #expect(StrengthMath.kilogramIncrement(fromPounds: nil) == 2.5)
        #expect(StrengthMath.kilogramIncrement(fromPounds: 1) == 1.25)
    }

    @Test func liftIdentityFoldsNamingNoiseButKeepsDistinctLifts() {
        #expect(LiftIdentity.normalizedName("Barbell Bench Press") == LiftIdentity.normalizedName("bench-press"))
        #expect(LiftIdentity.normalizedName("Pull-ups") == LiftIdentity.normalizedName("pull up"))
        #expect(LiftIdentity.normalizedName("Dumbbell bench press") == LiftIdentity.normalizedName("DB bench press"))
        #expect(LiftIdentity.normalizedName("DB bench press") != LiftIdentity.normalizedName("Bench press"))
        #expect(LiftIdentity.normalizedName("Incline bench press") != LiftIdentity.normalizedName("Bench press"))
        #expect(LiftIdentity.matches(
            plannedName: "Flat bench", plannedKey: "BARBELL_BENCH_PRESS",
            loggedName: "Bench", loggedKey: "barbell_bench_press"))
        #expect(LiftIdentity.matches(Self.bench, Self.lift("Bench press", 185, [8])))
        #expect(!LiftIdentity.matches(Self.bench, Self.lift("Incline bench press", 155, [8])))
    }

    // MARK: Rotation

    @Test func rotationIsAQueueNotWeekdaySlots() {
        let rotation = ["upper_a", "lower_a", "upper_b", "lower_b"]
        #expect(SessionRotationPolicy.nextSessionId(rotation: rotation, completedSessionIds: []) == "upper_a")
        #expect(SessionRotationPolicy.nextSessionId(rotation: rotation, completedSessionIds: ["upper_a"]) == "lower_a")
        #expect(SessionRotationPolicy.nextSessionId(
            rotation: rotation, completedSessionIds: ["upper_a", "lower_a", "upper_b", "lower_b"]) == "upper_a")
        // Ids from an older plan are skipped, not treated as a reset.
        #expect(SessionRotationPolicy.nextSessionId(
            rotation: rotation, completedSessionIds: ["upper_b", "push_day", "legs_old"]) == "lower_b")
        #expect(SessionRotationPolicy.nextSessionId(rotation: [], completedSessionIds: ["upper_a"]) == nil)
    }

    @Test func repeatedSessionsInTheRotationFollowRecentHistory() {
        let rotation = ["a", "b", "a", "c"]
        #expect(SessionRotationPolicy.nextSessionId(rotation: rotation, completedSessionIds: ["a", "b", "a"]) == "c")
        #expect(SessionRotationPolicy.nextSessionId(rotation: rotation, completedSessionIds: ["c", "a"]) == "b")
        #expect(SessionRotationPolicy.nextSessionId(rotation: rotation, completedSessionIds: ["a"]) == "b")
    }

    @Test func completedSessionsComeFromHistoryInOrderAndSkipFailures() {
        let activities = [
            Self.activity("2026-10-05", session: "upper_b"),
            Self.activity("2026-10-01", session: "upper_a"),
            Self.activity("2026-10-03", session: "lower_a", status: .failed),
            Self.activity("2026-10-03", hour: 19, session: "lower_a"),
            Self.activity("2026-10-06", session: "lower_b", status: .processing),
            Self.activity("2026-10-06", hour: 20, session: "upper_a", status: .failed,
                          localState: .notSent(message: "offline")),
            Self.activity("2026-10-04", kind: .cycle),
        ]
        #expect(SessionRotationPolicy.completedSessionIds(from: activities) == ["upper_a", "lower_a", "upper_b", "lower_b"])

        let plan = TrainPreviewFixtures.planDoc
        #expect(SessionRotationPolicy.nextSession(plan: plan, activities: activities)?.id == "upper_a")
    }

    // MARK: Double progression

    private static func last(_ sets: [ActivitySet]) -> LastPerformance {
        LastPerformance(sets: sets, localDay: "2026-10-01", activityId: UUID())
    }

    @Test func everySetAtTheTopOfTheRangeAddsWeightAndResetsReps() {
        let target = DoubleProgressionPolicy.nextTarget(
            for: Self.bench,
            last: Self.last([ActivitySet(reps: 5, weight: 135, isWarmup: true)]
                + [8, 8, 8, 8].map { ActivitySet(reps: $0, weight: 180) }))
        #expect(target.basis == .increaseWeight(by: 5))
        #expect(target.weight == 185)
        #expect(target.reps == [6, 6, 6, 6])
        #expect(target.prescription == "4×6 @ 185")
        #expect(target.deltaLabel == "+5 lb")
        #expect(target.addsWeight)
    }

    @Test func aMissedRepKeepsTheWeightAndAddsOneRepToTheWeakestSet() {
        let target = DoubleProgressionPolicy.nextTarget(
            for: Self.bench, last: Self.last([8, 8, 7, 6].map { ActivitySet(reps: $0, weight: 180) }))
        #expect(target.basis == .addReps)
        #expect(target.weight == 180)
        #expect(target.reps == [8, 8, 7, 7])
        #expect(target.prescription == "180 × 8/8/7/7")
        #expect(target.deltaLabel == "+1 rep")
        #expect(!target.addsWeight)

        let tied = DoubleProgressionPolicy.nextTarget(
            for: Self.bench, last: Self.last([8, 7, 7, 7].map { ActivitySet(reps: $0, weight: 180) }))
        #expect(tied.reps == [8, 8, 7, 7])
    }

    @Test func topOfRangeOnTooFewSetsAsksForTheMissingSet() {
        let target = DoubleProgressionPolicy.nextTarget(
            for: Self.bench, last: Self.last([8, 8].map { ActivitySet(reps: $0, weight: 180) }))
        #expect(target.basis == .addSet)
        #expect(target.reps == [8, 8, 8, 8])
        #expect(target.prescription == "4×8 @ 180")
        #expect(target.deltaLabel == "+1 set")
    }

    @Test func dropSetsProgressFromTheTopWeight() {
        let sets = [ActivitySet(reps: 8, weight: 185), ActivitySet(reps: 7, weight: 185),
                    ActivitySet(reps: 8, weight: 165), ActivitySet(reps: 8, weight: 165)]
        let target = DoubleProgressionPolicy.nextTarget(for: Self.bench, last: Self.last(sets))
        // Only the 185 sets count: 8/7 padded to four sets, weakest bumped.
        #expect(target.weight == 185)
        #expect(target.reps == [8, 8, 7, 7])
        #expect(target.basis == .addReps)
    }

    @Test func firstTimeUsesThePlanRange() {
        let target = DoubleProgressionPolicy.nextTarget(for: Self.bench, last: nil)
        #expect(target.basis == .firstTime)
        #expect(target.weight == nil)
        #expect(target.prescription == "4×6–8")
        #expect(target.deltaLabel == nil)
        #expect(!target.addsWeight)
    }

    @Test func kilogramLiftsStepInPlateSizedJumps() {
        let target = DoubleProgressionPolicy.nextTarget(
            for: Self.bench,
            last: Self.last([8, 8, 8, 8].map { ActivitySet(reps: $0, weight: 80, unit: .kg) }))
        #expect(target.weight == 82.5)
        #expect(target.unit == .kg)
        #expect(target.prescription == "4×6 @ 82.5 kg")
        #expect(target.deltaLabel == "+2.5 kg")
    }

    @Test func bodyweightLiftsProgressByReps() {
        let dips = PlannedExercise(name: "Dip", sets: 3, repMin: 8, repMax: 12)
        let target = DoubleProgressionPolicy.nextTarget(
            for: dips, last: Self.last([12, 10, 9].map { ActivitySet(reps: $0, weight: nil) }))
        #expect(target.weight == nil)
        #expect(target.reps == [12, 10, 10])
        #expect(target.prescription == "12/10/10")
        #expect(target.basis == .addReps)
    }

    @Test func lastPerformanceIsTheMostRecentSettledLogOfThatLift() throws {
        let history = [
            Self.activity("2026-09-28", exercises: [Self.lift("Bench press", 175, [8, 8, 7, 6])]),
            Self.activity("2026-10-01", exercises: [Self.lift("Barbell bench press", 180, [8, 8, 8, 8])]),
            Self.activity("2026-10-03", exercises: [Self.lift("Back squat", 215, [7, 7, 7, 7])]),
            Self.activity("2026-10-06", status: .processing,
                          exercises: [Self.lift("Bench press", 185, [6, 6, 6, 6])]),
        ]
        let performance = try #require(DoubleProgressionPolicy.lastPerformance(of: Self.bench, in: history))
        #expect(performance.localDay == "2026-10-01")
        #expect(performance.sets.map(\.reps) == [8, 8, 8, 8])

        let session = TrainingSession(id: "upper_a", name: "Upper A", exercises: [
            Self.bench, PlannedExercise(name: "Overhead press", sets: 3, repMin: 6, repMax: 8)])
        let targets = DoubleProgressionPolicy.targets(for: session, history: history)
        #expect(targets.map(\.prescription) == ["4×6 @ 185", "3×6–8"])
    }

    // MARK: PRs

    @Test func detectsE1RMAndRepPRsAgainstEarlierHistoryOnly() {
        let earlier = Self.activity("2026-10-01", exercises: [
            Self.lift("Barbell bench press", 175, [8, 8]),
            Self.lift("Dip", nil, [10, 9]),
        ])
        let later = Self.activity("2026-10-09", exercises: [Self.lift("Barbell bench press", 225, [5])])
        let current = Self.activity("2026-10-05", exercises: [
            Self.lift("Bench press", 180, [8, 8]),
            Self.lift("Incline DB press", 60, [10]),
            Self.lift("Dip", nil, [12, 10]),
        ])
        let prs = PRPolicy.detectPRs(in: current, history: [earlier, later, current])
        #expect(prs == [
            ActivityPR(exercise: "Bench press", kind: .e1rm, value: 228, unit: "lb", previous: 222),
            ActivityPR(exercise: "Dip", kind: .reps, value: 12, unit: "reps", previous: 10),
        ])
        // Matching the old best is not a PR; the first log of a lift isn't either.
        let repeatSession = Self.activity("2026-10-07", exercises: [Self.lift("Bench press", 180, [8])])
        #expect(PRPolicy.detectPRs(in: repeatSession, history: [earlier, current, repeatSession]).isEmpty)
    }

    @Test func boardKeepsTheBestPerLiftAndLeadsWithTheMainLifts() {
        let older = Self.activity("2026-09-20", exercises: [
            Self.lift("Barbell bench press", 175, [8], key: "barbell_bench_press"),
            Self.lift("Back squat", 245, [5], key: "back_squat"),
            Self.lift("Leg press", 400, [10]),
        ])
        let newer = Self.activity("2026-10-04", exercises: [
            Self.lift("Bench press", 185, [8]),
            Self.lift("Back squat", 225, [5], key: "back_squat"),
            Self.lift("Pull-up", nil, [14, 12]),
        ])
        let board = PRPolicy.board(
            from: [newer, older, Self.activity("2026-10-06", status: .processing,
                                                exercises: [Self.lift("Bench press", 300, [8])])],
            freshSince: "2026-09-30",
            priority: ["Back squat", "Bench press"])
        #expect(board.map(\.name) == ["Back squat", "Bench press", "Leg press", "Pull-up"])
        let squat = board[0]
        #expect(squat.bestSet.weight == 245)
        #expect(squat.localDay == "2026-09-20")
        #expect(!squat.isFresh)
        let bench = board[1]
        #expect(bench.id == "barbell_bench_press")
        #expect(bench.bestSet.weight == 185)
        #expect(bench.isFresh)
        #expect(abs((bench.e1rmPounds ?? 0) - 234.33) < 0.01)
        #expect(board[3].e1rmPounds == nil)
        #expect(board[3].bestSet.reps == 14)
        #expect(PRPolicy.priorityLifts(for: TrainPreviewFixtures.planDoc).prefix(4) == [
            "Barbell bench press", "Back squat", "Overhead press", "Deadlift",
        ])
    }

    // MARK: Weekly ring

    @Test func weeksRunMondayToSundayInTheProfileTimezone() {
        #expect(TrainCalendar.weekDays(containing: Self.now, timezone: Self.timezone) == [
            "2026-10-05", "2026-10-06", "2026-10-07", "2026-10-08", "2026-10-09", "2026-10-10", "2026-10-11",
        ])
        let sundayNight = TrainDateParser.parse("2026-10-12T03:30:00Z")!  // Sun 23:30 in New York
        #expect(TrainCalendar.weekDays(containing: sundayNight, timezone: Self.timezone).first == "2026-10-05")
        // DST ends Sunday 2026-11-01 in New York.
        #expect(TrainCalendar.adding(days: 1, to: "2026-10-31", timezone: Self.timezone) == "2026-11-01")
        #expect(TrainCalendar.adding(days: 1, to: "2026-11-01", timezone: Self.timezone) == "2026-11-02")
        #expect(TrainCalendar.localDay(for: Self.now, timezone: Self.timezone) == "2026-10-06")
    }

    @Test func weekStripCountsDistinctTrainingDaysThisWeek() {
        let plan = TrainPreviewFixtures.planDoc
        let activities = [
            Self.activity("2026-10-04", session: "lower_b"),                      // last week
            Self.activity("2026-10-05", session: "upper_a"),
            Self.activity("2026-10-05", hour: 20, kind: .strength),               // split log, same day
            Self.activity("2026-10-06", hour: 7, kind: .cycle),                   // bike isn't a session
            Self.activity("2026-10-06", session: "lower_a", status: .processing), // still being read
            Self.activity("2026-10-06", hour: 21, kind: .strength, status: .failed),
        ]
        #expect(TrainingWeekPolicy.sessionsThisWeek(activities: activities, now: Self.now, timezone: Self.timezone) == 2)

        let progress = TrainingWeekPolicy.progress(activities: activities, plan: plan, now: Self.now, timezone: Self.timezone)
        #expect(progress.completed == 2)
        #expect(progress.target == 4)
        #expect(progress.countLabel == "2 of 4")
        #expect(progress.days.map(\.marker) == ["U", "L", nil, nil, nil, nil, nil])
        #expect(progress.days.map(\.trained) == [true, true, false, false, false, false, false])
        #expect(progress.days[1].isToday)
        #expect(progress.days[2].isFuture)
        #expect(progress.days.map(\.weekdayInitial) == ["M", "T", "W", "T", "F", "S", "S"])

        let noPlan = TrainingWeekPolicy.progress(activities: activities, plan: nil, now: Self.now, timezone: Self.timezone)
        #expect(noPlan.target == nil)
        #expect(noPlan.countLabel == nil)
        #expect(noPlan.days[0].symbolName == ActivityKind.strength.symbolName)
    }

    // MARK: Polling + merge

    @Test func pollingBacksOffFrom650msToThreeSeconds() {
        var delay = ActivityPollingPolicy.initialDelay
        var delays: [UInt64] = [delay]
        for _ in 0..<5 {
            delay = ActivityPollingPolicy.nextDelay(after: delay)
            delays.append(delay)
        }
        #expect(delays == [650_000_000, 975_000_000, 1_462_500_000, 2_193_750_000, 3_000_000_000, 3_000_000_000])
    }

    @Test func mergeDropsLostResponsePlaceholdersAndPrefersNewerRows() {
        let requestId = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let server = Self.activity("2026-10-06", session: "upper_a", status: .processing,
                                   clientRequestId: requestId, updatedAt: t0)
        let placeholder = Self.activity("2026-10-06", hour: 19, session: "upper_a", status: .failed,
                                        localState: .notSent(message: "offline"), clientRequestId: requestId)
        var settled = server
        settled.status = .complete
        settled.updatedAt = t0.addingTimeInterval(5)
        var stale = server
        stale.updatedAt = t0.addingTimeInterval(-5)
        stale.title = "Stale"
        let other = Self.activity("2026-10-05")

        let merged = ActivityTimelineMerge.merge(loaded: [server, other], overlay: [placeholder, settled])
        #expect(merged.map(\.id) == [server.id, other.id])
        #expect(merged.first?.status == .complete)

        let keepsLoaded = ActivityTimelineMerge.merge(loaded: [server], overlay: [stale])
        #expect(keepsLoaded.first?.title == server.title)

        var tiedOptimistic = server
        tiedOptimistic.title = "Upper A (optimistic)"
        #expect(ActivityTimelineMerge.merge(loaded: [server], overlay: [tiedOptimistic]).first?.title
            == "Upper A (optimistic)")
    }

    // MARK: Card copy

    @Test func strengthSubtitleLeadsWithTheTopSet() {
        let activity = Self.activity("2026-10-05", exercises: [
            ActivityExercise(name: "Barbell bench press", sets: [
                ActivitySet(reps: 10, weight: 95, isWarmup: true),
                ActivitySet(reps: 8, weight: 185), ActivitySet(reps: 6, weight: 185),
                ActivitySet(reps: 9, weight: 175),
            ]),
            Self.lift("Incline DB press", 60, [10, 10, 9]),
            Self.lift("EZ-bar curl", 65, [12]),
            ActivityExercise(name: "Notes only", sets: []),
        ])
        #expect(ActivitySummaryFormatter.subtitle(for: activity, units: "imperial") == "Bench press 185×8 · +2 lifts")

        let pullUps = Self.activity("2026-10-05", exercises: [Self.lift("Pull-up", nil, [12, 12, 12])])
        #expect(ActivitySummaryFormatter.subtitle(for: pullUps, units: "imperial") == "Pull-up 3×12")
        let uneven = Self.activity("2026-10-05", exercises: [Self.lift("Pull-up", nil, [12, 10])])
        #expect(ActivitySummaryFormatter.subtitle(for: uneven, units: "imperial") == "Pull-up ×12")
    }

    @Test func cardioSubtitleShowsTimeAndDistanceInTheProfileUnits() {
        var run = Self.activity("2026-10-05", kind: .run)
        run.durationMin = 32
        run.distanceKm = 5
        #expect(ActivitySummaryFormatter.subtitle(for: run, units: "imperial") == "32 min · 3.1 mi")
        #expect(ActivitySummaryFormatter.subtitle(for: run, units: "metric") == "32 min · 5.0 km")
        #expect(ActivitySummaryFormatter.metaDuration(for: run) == nil)
        var bare = Self.activity("2026-10-05", kind: .sport)
        bare.intensity = .hard
        #expect(ActivitySummaryFormatter.subtitle(for: bare, units: "imperial") == "Hard")
        #expect(ActivitySummaryFormatter.subtitle(for: Self.activity("2026-10-05", kind: .other), units: "imperial") == nil)
    }

    @Test func copyHelpersStayShortAndHonest() {
        #expect(ActivitySummaryFormatter.durationText(minutes: 52.4) == "52 min")
        #expect(ActivitySummaryFormatter.durationText(minutes: 65) == "1 h 5 min")
        #expect(ActivitySummaryFormatter.durationText(minutes: 120) == "2 h")
        #expect(ActivitySummaryFormatter.shortLiftName("Barbell bench press") == "Bench press")
        #expect(ActivitySummaryFormatter.shortLiftName("Barbell row") == "Barbell row")
        #expect(ActivitySummaryFormatter.shortLiftName("Dumbbell row") == "DB row")
        #expect(ActivitySummaryFormatter.shortLiftName("incline DB press") == "Incline DB press")
        #expect(ActivitySummaryFormatter.setText(ActivitySet(reps: 5, weight: 100, unit: .kg), units: "imperial") == "100 kg×5")
        #expect(ActivitySummaryFormatter.setText(ActivitySet(reps: 5, weight: 100, unit: .kg), units: "metric") == "100×5")
        #expect(ActivitySummaryFormatter.setText(ActivitySet(reps: 12), units: "imperial") == "×12")
    }

    @Test func exerciseSummaryCollapsesStraightSets() {
        #expect(ActivitySummaryFormatter.exerciseSummary(Self.lift("Bench", 185, [8, 8, 8, 8]), units: "imperial") == "4×8 @ 185")
        #expect(ActivitySummaryFormatter.exerciseSummary(Self.lift("Bench", 185, [8, 8, 7]), units: "imperial") == "185 × 8/8/7")
        #expect(ActivitySummaryFormatter.exerciseSummary(Self.lift("Squat", 100, [5, 5], unit: .kg), units: "imperial") == "2×5 @ 100 kg")
        #expect(ActivitySummaryFormatter.exerciseSummary(Self.lift("Dip", nil, [10, 8]), units: "imperial") == "10/8")
        let pyramid = ActivityExercise(name: "Deadlift", sets: [
            ActivitySet(reps: 5, weight: 185), ActivitySet(reps: 5, weight: 205), ActivitySet(reps: 3, weight: 225)])
        #expect(ActivitySummaryFormatter.exerciseSummary(pyramid, units: "imperial") == "225×3 top")
    }

    @Test func detailSummaryListsEverySetWhenTheLoadChanged() {
        #expect(ActivitySummaryFormatter.setsSummary(Self.lift("Bench", 185, [8, 8, 7]), units: "imperial") == "185 × 8/8/7")
        let pyramid = ActivityExercise(name: "Deadlift", sets: [
            ActivitySet(reps: 10, weight: 135, isWarmup: true),
            ActivitySet(reps: 5, weight: 185), ActivitySet(reps: 5, weight: 205), ActivitySet(reps: 3, weight: 225)])
        #expect(ActivitySummaryFormatter.setsSummary(pyramid, units: "imperial") == "185×5, 205×5, 225×3")
    }

    @Test func cardStatLineIsTheTopSetAndTheTime() {
        var lift = Self.activity("2026-10-05", exercises: [
            Self.lift("Barbell bench press", 180, [8, 8, 8, 8]), Self.lift("Weighted pull-up", 25, [8, 7, 7, 6]),
        ])
        #expect(ActivitySummaryFormatter.statLine(for: lift, units: "imperial") == "Bench press 180×8")
        lift.durationMin = 61
        #expect(ActivitySummaryFormatter.statLine(for: lift, units: "imperial") == "Bench press 180×8 · 1 h 1 min")
        var ride = Self.activity("2026-10-05", kind: .cycle)
        ride.durationMin = 10
        ride.distanceKm = 4.4
        #expect(ActivitySummaryFormatter.statLine(for: ride, units: "imperial") == "10 min · 2.7 mi")
    }

    @Test func aLogBeingReadShowsItsOwnWordsNotAStatus() {
        var row = Self.activity("2026-10-06", status: .processing)
        #expect(ActivityCard.readingLine(for: row) == "Logging…")
        row.inputText = "  Deads 285 for 5 5 4 "
        #expect(ActivityCard.readingLine(for: row) == "Deads 285 for 5 5 4")
        row.details.analysisPreview = "Deadlifts 285 for 5, 5, 4"
        #expect(ActivityCard.readingLine(for: row) == "Deadlifts 285 for 5, 5, 4")
    }

    @Test func burnExplanationIsOnePlainSentenceAndNeverFeedsTheTargets() {
        var row = Self.activity("2026-10-05")
        row.durationMin = 61
        row.details.burnMethod = .met
        row.details.met = 5
        row.details.weightKgUsed = 73.7
        let estimate = ActivityDetailView.burnExplanation(for: row, units: "imperial")
        #expect(estimate == "Estimated from 1 h 1 min at 162 lb and how hard you went. Not added back to your food targets.")
        #expect(!estimate.contains("MET"))
        row.details.burnMethod = .device
        row.details.deviceLabel = "apple_watch"
        #expect(ActivityDetailView.burnExplanation(for: row, units: "imperial")
            == "From your Apple Watch. Not added back to your food targets.")
    }

    @Test func prPartsSplitValueUnitAndGain() {
        let parts = ActivityDetailView.prParts(
            ActivityPR(exercise: "Bench press", kind: .e1rm, value: 228, unit: "lb", previous: 222))
        #expect(parts.value == "228")
        #expect(parts.unit == "lb e1RM")
        #expect(parts.delta == "+6")
        let first = ActivityDetailView.prParts(ActivityPR(exercise: "Dip", kind: .reps, value: 15, unit: "reps"))
        #expect(first.unit == "reps")
        #expect(first.delta == nil)
    }

    @Test func draftsCarryAnHonestOptimisticTitle() {
        #expect(WorkoutLogDraft(text: "").optimisticTitle(sessionName: "Upper A") == "Upper A")
        #expect(WorkoutLogDraft(text: "Ran 3 miles\nfelt good").optimisticTitle(sessionName: nil) == "Ran 3 miles")
        #expect(WorkoutLogDraft(text: "", imageJPEG: Data([1])).optimisticTitle(sessionName: nil) == "Workout screenshot")
        #expect(WorkoutLogDraft(text: "", kindHint: .walk).optimisticTitle(sessionName: nil) == "Walk")
        #expect(WorkoutLogDraft(text: String(repeating: "x", count: 80)).optimisticTitle(sessionName: nil).count == 48)
        #expect(!WorkoutLogDraft(text: "  ").canSubmit)
        #expect(WorkoutLogDraft(text: " ", imageJPEG: Data([1])).canSubmit)
        #expect(!WorkoutLogDraft(text: String(repeating: "x", count: 4_001)).canSubmit)
    }
}
