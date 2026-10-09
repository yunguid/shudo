#if DEBUG
import SwiftUI
import UIKit

/// Offline Train fixtures for PolishPreview (`-shudoPolishPreview train`)
/// and UI tests: an active 4-day upper/lower plan, two weeks of lifting with
/// PRs, a morning bike, a walk, and today's session still being read.
///
/// Variants via `-shudoTrainPreview <variant>`:
///   (none)  the Train tab        `prs` / `recent`  scrolled to that section
///   `next`  nothing logged today `done`  today's session read, with a PR
///   `detail` an activity detail  `log`  the typed logger on "Next up"
///   `empty`  no plan yet         `draft` a drafted plan waiting to run
///   `log-free` the logger with no session    `plan` the plan sheet
///   `detail-today` today's Lower B (a PR) in full
enum TrainPreviewFixtures {
    static let timezone = "America/New_York"

    static var variant: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-shudoTrainPreview"),
              arguments.indices.contains(flag + 1) else { return nil }
        return arguments[flag + 1]
    }

    static let profile = Profile(
        userId: "00000000-0000-4000-8000-000000000001",
        timezone: timezone,
        dailyMacroTarget: MacroTarget(caloriesKcal: 2_950, proteinG: 175, carbsG: 360, fatG: 85),
        units: "imperial",
        heightCM: 180.3,
        weightKG: 73.7,
        targetWeightKG: 79.4,
        displayName: "Luke",
        activityLevel: .light,
        goalType: .gain,
        goalNotes: "Lean bulk 162.5 → 175 lb.",
        onboardingStatus: .completed,
        onboardingCompletedAt: Date()
    )

    // MARK: Plan

    static let planDoc = TrainingPlanDoc(
        name: "Upper / Lower",
        phase: "lean_bulk",
        sessionsPerWeek: 4,
        rotation: ["upper_a", "lower_a", "upper_b", "lower_b"],
        sessions: [
            TrainingSession(
                id: "upper_a", name: "Upper A", focus: "chest & back, heavy", estMinutes: 60,
                exercises: [
                    PlannedExercise(name: "Barbell bench press", key: "barbell_bench_press", sets: 4, repMin: 6, repMax: 8,
                                    restSec: 150, incrementLb: 5, cue: "Pause on the chest"),
                    PlannedExercise(name: "Weighted pull-up", key: "weighted_pull_up", sets: 4, repMin: 6, repMax: 8,
                                    restSec: 150, incrementLb: 5),
                    PlannedExercise(name: "Incline DB press", key: "incline_db_press", sets: 3, repMin: 8, repMax: 10,
                                    restSec: 120, incrementLb: 5),
                    PlannedExercise(name: "Chest-supported row", sets: 3, repMin: 8, repMax: 12, restSec: 90),
                    PlannedExercise(name: "Lateral raise", sets: 3, repMin: 12, repMax: 15, restSec: 60),
                    PlannedExercise(name: "EZ-bar curl", sets: 3, repMin: 10, repMax: 12, restSec: 60),
                ]),
            TrainingSession(
                id: "lower_a", name: "Lower A", focus: "squat", estMinutes: 60,
                exercises: [
                    PlannedExercise(name: "Back squat", key: "back_squat", sets: 4, repMin: 5, repMax: 7,
                                    restSec: 180, incrementLb: 10, cue: "Brace, sit between the hips"),
                    PlannedExercise(name: "Romanian deadlift", key: "romanian_deadlift", sets: 3, repMin: 8, repMax: 10,
                                    restSec: 120, incrementLb: 10),
                    PlannedExercise(name: "Leg press", sets: 3, repMin: 10, repMax: 12, restSec: 90, incrementLb: 20),
                    PlannedExercise(name: "Standing calf raise", sets: 4, repMin: 10, repMax: 15, restSec: 60),
                ]),
            TrainingSession(
                id: "upper_b", name: "Upper B", focus: "shoulders & arms", estMinutes: 55,
                exercises: [
                    PlannedExercise(name: "Overhead press", key: "overhead_press", sets: 4, repMin: 6, repMax: 8,
                                    restSec: 150, incrementLb: 5),
                    PlannedExercise(name: "Barbell row", key: "barbell_row", sets: 4, repMin: 6, repMax: 8,
                                    restSec: 120, incrementLb: 5),
                    PlannedExercise(name: "Dip", key: "dip", sets: 3, repMin: 8, repMax: 12, restSec: 90),
                    PlannedExercise(name: "Cable fly", sets: 3, repMin: 12, repMax: 15, restSec: 60),
                    PlannedExercise(name: "Hammer curl", sets: 3, repMin: 10, repMax: 12, restSec: 60),
                ]),
            TrainingSession(
                id: "lower_b", name: "Lower B", focus: "deadlift", estMinutes: 55,
                exercises: [
                    PlannedExercise(name: "Deadlift", key: "deadlift", sets: 3, repMin: 4, repMax: 6,
                                    restSec: 180, incrementLb: 10),
                    PlannedExercise(name: "Bulgarian split squat", key: "bulgarian_split_squat", sets: 3, repMin: 8, repMax: 10,
                                    restSec: 90, incrementLb: 5, cue: "Old boarding-school favorite"),
                    PlannedExercise(name: "Hip thrust", sets: 3, repMin: 8, repMax: 12, restSec: 90, incrementLb: 10),
                    PlannedExercise(name: "Hanging leg raise", sets: 3, repMin: 10, repMax: 15, restSec: 60),
                ]),
        ],
        conditioning: TrainingConditioning(kind: "bike", minutes: 10, when: "morning", optional: true),
        equipmentAssumed: ["commercial gym"],
        notes: "Double progression: when every working set hits the top of the range, add weight and start back at the bottom."
    )

    static let activePlan = TrainingPlan(
        id: UUID(uuidString: "5A1E0000-0000-4000-8000-0000000000A1")!,
        status: .active,
        plan: planDoc,
        rationale: "Four sessions fit a six-day work week with two evenings to spare; the rotation means a missed day just slides.",
        createdAt: Date().addingTimeInterval(-15 * 86_400),
        activatedAt: Date().addingTimeInterval(-15 * 86_400)
    )

    static var draftPlan: TrainingPlan {
        var doc = planDoc
        doc.name = "Upper / Lower + Arms"
        return TrainingPlan(
            id: UUID(uuidString: "5A1E0000-0000-4000-8000-0000000000D1")!,
            status: .draft,
            plan: doc,
            changeSummary: "Same four days, plus a 30-minute arms finisher on Saturdays. Squat volume drops a set while your deadlift catches up.",
            createdAt: Date())
    }

    // MARK: Activities

    private static func day(_ offset: Int) -> String {
        TrainCalendar.adding(days: offset, to: TrainCalendar.localDay(for: Date(), timezone: timezone), timezone: timezone)
            ?? TrainCalendar.localDay(for: Date(), timezone: timezone)
    }

    private static func at(_ offset: Int, hour: Int, minute: Int = 0) -> Date {
        let calendar = TrainCalendar.calendar(timezone: timezone)
        let start = TrainCalendar.date(fromLocalDay: day(offset), timezone: timezone) ?? Date()
        let date = calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: start) ?? start
        // Keep "today" rows in the past even early in the morning.
        return min(date, Date().addingTimeInterval(-Double(abs(offset) + 1) * 60))
    }

    private static func sets(_ weight: Double?, _ reps: [Int], warmups: [(Double, Int)] = []) -> [ActivitySet] {
        warmups.map { ActivitySet(reps: $0.1, weight: $0.0, isWarmup: true) }
            + reps.map { ActivitySet(reps: $0, weight: weight) }
    }

    private static func lift(
        _ id: String, offset: Int, hour: Int, session: String, title: String, minutes: Double, kcal: Double,
        exercises: [ActivityExercise], prs: [ActivityPR] = [], input: String
    ) -> Activity {
        Activity(
            id: UUID(uuidString: id)!,
            clientRequestId: UUID(),
            localDay: day(offset),
            occurredAt: at(offset, hour: hour, minute: 15),
            status: .complete,
            source: "voice",
            kind: .strength,
            title: title,
            durationMin: minutes,
            activeKcal: kcal,
            intensity: .hard,
            rpe: 8,
            details: ActivityDetails(
                exercises: exercises, prs: prs, planSessionId: session, burnMethod: .met, met: 5.0,
                weightKgUsed: 73.7),
            inputText: input,
            confidence: 0.86
        )
    }

    static var activities: [Activity] {
        [
            lift("A0000000-0000-4000-8000-000000000013", offset: -13, hour: 18, session: "upper_a", title: "Upper A",
                 minutes: 58, kcal: 296,
                 exercises: [
                    ActivityExercise(name: "Barbell bench press", key: "barbell_bench_press",
                                     sets: sets(175, [8, 8, 7, 6], warmups: [(95, 10), (135, 5)])),
                    ActivityExercise(name: "Weighted pull-up", key: "weighted_pull_up", sets: sets(20, [8, 7, 6, 6])),
                    ActivityExercise(name: "Incline DB press", key: "incline_db_press", sets: sets(55, [10, 9, 8])),
                    ActivityExercise(name: "Lateral raise", sets: sets(20, [15, 13, 12])),
                 ],
                 input: "Upper A. Bench 175 for 8 8 7 6, pull-ups plus 20 for 8 7 6 6, incline dumbbells 55s 10 9 8, laterals 20s."),
            lift("A0000000-0000-4000-8000-000000000011", offset: -11, hour: 18, session: "lower_a", title: "Lower A",
                 minutes: 62, kcal: 334,
                 exercises: [
                    ActivityExercise(name: "Back squat", key: "back_squat", sets: sets(205, [7, 6, 6, 5], warmups: [(135, 5)])),
                    ActivityExercise(name: "Romanian deadlift", key: "romanian_deadlift", sets: sets(185, [10, 9, 8])),
                    ActivityExercise(name: "Leg press", sets: sets(270, [12, 11, 10])),
                 ],
                 input: "Squats 205, 7 6 6 5. RDL 185 10 9 8. Leg press 270."),
            lift("A0000000-0000-4000-8000-000000000009", offset: -9, hour: 18, session: "upper_b", title: "Upper B",
                 minutes: 54, kcal: 270,
                 exercises: [
                    ActivityExercise(name: "Overhead press", key: "overhead_press", sets: sets(105, [8, 7, 6, 6])),
                    ActivityExercise(name: "Barbell row", key: "barbell_row", sets: sets(155, [8, 8, 7, 7])),
                    ActivityExercise(name: "Dip", key: "dip", sets: sets(nil, [12, 10, 9])),
                 ],
                 input: "OHP 105 8 7 6 6, rows 155 8 8 7 7, dips bodyweight 12 10 9."),
            Activity(
                id: UUID(uuidString: "B0000000-0000-4000-8000-000000000008")!,
                localDay: day(-8), occurredAt: at(-8, hour: 7), status: .complete, source: "text", kind: .cycle,
                title: "Morning bike", durationMin: 10, distanceKm: 4.2, activeKcal: 41, intensity: .easy,
                details: ActivityDetails(burnMethod: .met, met: 5.8, weightKgUsed: 73.7),
                inputText: "10 min bike"),
            lift("A0000000-0000-4000-8000-000000000007", offset: -7, hour: 18, session: "lower_b", title: "Lower B",
                 minutes: 56, kcal: 318,
                 exercises: [
                    ActivityExercise(name: "Deadlift", key: "deadlift", sets: sets(275, [5, 5, 4], warmups: [(135, 5), (225, 3)])),
                    ActivityExercise(name: "Bulgarian split squat", key: "bulgarian_split_squat", sets: sets(40, [10, 9, 8])),
                    ActivityExercise(name: "Hip thrust", sets: sets(185, [12, 10, 10])),
                 ],
                 input: "Deads 275 for 5 5 4, split squats 40s, hip thrust 185."),
            lift("A0000000-0000-4000-8000-000000000005", offset: -5, hour: 18, session: "upper_a", title: "Upper A",
                 minutes: 61, kcal: 312,
                 exercises: [
                    ActivityExercise(name: "Barbell bench press", key: "barbell_bench_press",
                                     sets: sets(180, [8, 8, 8, 8], warmups: [(95, 10), (135, 5)])),
                    ActivityExercise(name: "Weighted pull-up", key: "weighted_pull_up", sets: sets(25, [8, 7, 7, 6])),
                    ActivityExercise(name: "Incline DB press", key: "incline_db_press", sets: sets(60, [10, 10, 9])),
                    ActivityExercise(name: "Lateral raise", sets: sets(20, [15, 15, 14])),
                    ActivityExercise(name: "EZ-bar curl", sets: sets(65, [12, 11, 10])),
                 ],
                 prs: [
                    ActivityPR(exercise: "Barbell bench press", kind: .e1rm, value: 228, unit: "lb", previous: 222),
                    ActivityPR(exercise: "Incline DB press", kind: .e1rm, value: 80, unit: "lb", previous: 73),
                 ],
                 input: "Upper A. Bench 180 for 4 sets of 8, finally. Pull-ups plus 25 8 7 7 6. Incline 60s 10 10 9. Laterals, curls."),
            Activity(
                id: UUID(uuidString: "B0000000-0000-4000-8000-000000000004")!,
                localDay: day(-4), occurredAt: at(-4, hour: 9, minute: 5), status: .complete, source: "text", kind: .walk,
                title: "Walk to the office", durationMin: 42, distanceKm: 3.4, activeKcal: 128, intensity: .easy,
                details: ActivityDetails(burnMethod: .met, met: 3.3, weightKgUsed: 73.7),
                inputText: "Walked to work, about 40 min"),
            lift("A0000000-0000-4000-8000-000000000003", offset: -3, hour: 18, session: "lower_a", title: "Lower A",
                 minutes: 64, kcal: 352,
                 exercises: [
                    ActivityExercise(name: "Back squat", key: "back_squat",
                                     sets: sets(215, [7, 7, 7, 7], warmups: [(135, 5), (185, 3)])),
                    ActivityExercise(name: "Romanian deadlift", key: "romanian_deadlift", sets: sets(195, [10, 10, 10])),
                    ActivityExercise(name: "Leg press", sets: sets(290, [12, 12, 11])),
                    ActivityExercise(name: "Standing calf raise", sets: sets(135, [15, 14, 13, 12])),
                 ],
                 prs: [ActivityPR(exercise: "Back squat", kind: .e1rm, value: 265, unit: "lb", previous: 253)],
                 input: "Squat 215 for 4 sets of 7. RDL 195 3x10. Leg press 290, calves."),
            lift("A0000000-0000-4000-8000-000000000001", offset: -1, hour: 18, session: "upper_b", title: "Upper B",
                 minutes: 57, kcal: 284,
                 exercises: [
                    ActivityExercise(name: "Overhead press", key: "overhead_press", sets: sets(110, [8, 8, 7, 6])),
                    ActivityExercise(name: "Barbell row", key: "barbell_row", sets: sets(160, [8, 8, 8, 7])),
                    ActivityExercise(name: "Dip", key: "dip", sets: sets(nil, [12, 11, 10])),
                    ActivityExercise(name: "Cable fly", sets: sets(30, [15, 14, 12])),
                    ActivityExercise(name: "Hammer curl", sets: sets(35, [12, 10, 10])),
                 ],
                 prs: [ActivityPR(exercise: "Overhead press", kind: .e1rm, value: 139, unit: "lb", previous: 133)],
                 input: "OHP 110 8 8 7 6. Rows 160 8 8 8 7. Dips, flies, hammers."),
            Activity(
                id: UUID(uuidString: "B0000000-0000-4000-8000-000000000000")!,
                localDay: day(0), occurredAt: at(0, hour: 7, minute: 10), status: .complete, source: "voice", kind: .cycle,
                title: "Morning bike", durationMin: 10, distanceKm: 4.4, activeKcal: 43, intensity: .moderate,
                details: ActivityDetails(deviceLabel: "apple_watch", burnMethod: .device),
                inputText: "10 minutes on the bike"),
            processingToday,
        ]
    }

    static var processingToday: Activity {
        Activity(
            id: UUID(uuidString: "C0000000-0000-4000-8000-000000000000")!,
            clientRequestId: UUID(uuidString: "C0000000-0000-4000-8000-0000000000CC"),
            localDay: day(0),
            occurredAt: at(0, hour: 18, minute: 40),
            status: .processing,
            source: "voice",
            kind: .strength,
            title: "Lower B",
            details: ActivityDetails(
                planSessionId: "lower_b",
                analysisPreview: "Deadlifts 285 for 5, 5, 4 — split squats, hip thrusts, leg raises · ~55 min"),
            inputText: "Lower B. Deads 285 for 5 5 4, split squats 45s 10 9 9, hip thrust 195, leg raises.",
            updatedAt: Date()
        )
    }

    /// Today's Lower B, stuck before it reached the server.
    static var unsentToday: Activity {
        var row = processingToday
        row.localState = .notSent(message: "No connection — not sent")
        return row
    }

    /// Today's Lower B once it has been read.
    static var completedToday: Activity {
        var row = processingToday
        row.status = .complete
        row.durationMin = 54
        row.activeKcal = 301
        row.details = ActivityDetails(
            exercises: [
                ActivityExercise(name: "Deadlift", key: "deadlift",
                                 sets: sets(285, [5, 5, 4], warmups: [(135, 5), (225, 3)])),
                ActivityExercise(name: "Bulgarian split squat", key: "bulgarian_split_squat", sets: sets(45, [10, 9, 9])),
                ActivityExercise(name: "Hip thrust", sets: sets(195, [12, 11, 10])),
                ActivityExercise(name: "Hanging leg raise", sets: sets(nil, [15, 12, 12])),
            ],
            prs: [ActivityPR(exercise: "Deadlift", kind: .e1rm, value: 333, unit: "lb", previous: 321)],
            planSessionId: "lower_b", burnMethod: .met, met: 5.0, weightKgUsed: 73.7)
        return row
    }

    static var detailActivity: Activity {
        activities.first { $0.id == UUID(uuidString: "A0000000-0000-4000-8000-000000000005")! }!
    }

    // MARK: Screens

    @MainActor
    static func viewModel(plans: TrainingPlanState, activities: [Activity]) -> TrainViewModel {
        let service = PreviewTrainService(plans: plans, activities: activities)
        return TrainViewModel(
            profile: profile,
            service: service,
            preloadedPlans: plans,
            preloadedActivities: activities)
    }

    @MainActor
    @ViewBuilder
    static func screen() -> some View {
        switch variant {
        case "detail":
            NavigationStack {
                ActivityDetailView(
                    activity: detailActivity,
                    units: profile.units,
                    onDelete: { true })
            }
        case "log":
            let next = planDoc.session(id: "upper_a")!
            WorkoutLogSheet(
                session: next,
                targets: DoubleProgressionPolicy.targets(for: next, history: activities),
                onSubmit: { _ in })
        case "log-free":
            WorkoutLogSheet(initialKind: .cardio, onSubmit: { _ in })
        case "plan":
            TrainingPlanSheet(plan: activePlan, onChange: {})
        case "detail-today":
            NavigationStack {
                ActivityDetailView(activity: completedToday, units: profile.units, onDelete: { true })
            }
        case "detail-reading":
            NavigationStack {
                ActivityDetailView(activity: processingToday, units: profile.units, onDelete: { true })
            }
        case "detail-unsent":
            NavigationStack {
                ActivityDetailView(activity: unsentToday, units: profile.units, onRetry: {}, onDelete: { true })
            }
        case "empty":
            NavigationStack {
                TrainScreen(
                    viewModel: viewModel(plans: TrainingPlanState(), activities: Array(activities.suffix(4).dropLast())),
                    onAskCoach: { _ in })
            }
        case "next":
            NavigationStack {
                TrainScreen(
                    viewModel: viewModel(plans: TrainingPlanState(active: activePlan), activities: Array(activities.dropLast())),
                    onAskCoach: { _ in })
            }
        case "done":
            NavigationStack {
                TrainScreen(
                    viewModel: viewModel(
                        plans: TrainingPlanState(active: activePlan), activities: Array(activities.dropLast()) + [completedToday]),
                    onAskCoach: { _ in })
            }
        case "unsent":
            // Today's log never reached the server: the history keeps its card.
            NavigationStack {
                TrainScreen(
                    viewModel: viewModel(
                        plans: TrainingPlanState(active: activePlan), activities: Array(activities.dropLast()) + [unsentToday]),
                    onAskCoach: { _ in },
                    previewScrollAnchor: "recent")
            }
        case "landing":
            // Today's session is being read, then lands with a PR ~3.5 s in.
            NavigationStack {
                TrainScreen(
                    viewModel: TrainViewModel(
                        profile: profile,
                        service: PreviewTrainService(
                            plans: TrainingPlanState(active: activePlan), activities: activities,
                            landing: completedToday),
                        preloadedPlans: TrainingPlanState(active: activePlan),
                        preloadedActivities: activities),
                    onAskCoach: { _ in })
            }
        case "draft":
            NavigationStack {
                TrainScreen(
                    viewModel: viewModel(plans: TrainingPlanState(active: activePlan, draft: draftPlan), activities: activities),
                    onAskCoach: { _ in })
            }
        default:
            NavigationStack {
                TrainScreen(
                    viewModel: viewModel(plans: TrainingPlanState(active: activePlan), activities: activities),
                    onAskCoach: { _ in },
                    previewScrollAnchor: variant)
            }
        }
    }
}

extension TrainScreen {
    init(viewModel: TrainViewModel, onAskCoach: @escaping (String) -> Void, previewScrollAnchor: String?) {
        self.init(viewModel: viewModel, onAskCoach: onAskCoach)
        self.previewScrollAnchor = previewScrollAnchor
    }
}

/// Offline `TrainServing`: serves fixtures, accepts logs, and "reads" a new
/// log for a few seconds before completing it.
actor PreviewTrainService: TrainServing {
    private var plans: TrainingPlanState
    private var rows: [UUID: Activity]
    private var acceptedAt: [UUID: Date] = [:]
    /// A row that finishes reading on its own a few seconds in (the
    /// `landing` variant: watch today's session land).
    private var landing: (at: Date, row: Activity)?

    init(plans: TrainingPlanState, activities: [Activity], landing: Activity? = nil, after delay: TimeInterval = 3.5) {
        self.plans = plans
        self.rows = Dictionary(uniqueKeysWithValues: activities.map { ($0.id, $0) })
        self.landing = landing.map { (Date().addingTimeInterval(delay), $0) }
    }

    private func land() {
        guard let landing, Date() >= landing.at else { return }
        var row = landing.row
        row.updatedAt = Date()
        rows[row.id] = row
        self.landing = nil
    }

    func fetchActivities(fromLocalDay: String, throughLocalDay: String?, limit: Int) async throws -> [Activity] {
        land()
        let filtered = rows.values.filter { row in
            row.localDay >= fromLocalDay && (throughLocalDay.map { row.localDay <= $0 } ?? true)
        }
        return Array(ActivityTimelineMerge.sorted(filtered).prefix(limit))
    }

    func fetchActivity(id: UUID) async throws -> Activity? {
        land()
        guard var row = rows[id] else { return nil }
        if let accepted = acceptedAt[id], row.status == .processing, Date().timeIntervalSince(accepted) > 4 {
            row.status = .complete
            row.details.analysisPreview = nil
            row.durationMin = 50
            row.activeKcal = 290
            row.updatedAt = Date()
            rows[id] = row
        }
        return row
    }

    func fetchTrainingPlans() async throws -> TrainingPlanState { plans }

    func logActivity(_ request: ActivityLogRequest) async throws -> ActivityLogResult {
        try await Task.sleep(nanoseconds: 600_000_000)
        if let existing = rows.values.first(where: { $0.clientRequestId == request.clientRequestId }) {
            return ActivityLogResult(activityId: existing.id, status: existing.status, duplicate: true)
        }
        let id = UUID()
        rows[id] = Activity(
            id: id,
            clientRequestId: request.clientRequestId,
            localDay: request.localDay,
            occurredAt: request.occurredAt ?? Date(),
            status: .processing,
            kind: request.kindHint ?? .strength,
            title: "Workout",
            details: ActivityDetails(planSessionId: request.planSessionId, analysisPreview: "Reading your session…"),
            inputText: request.text)
        acceptedAt[id] = Date()
        return ActivityLogResult(activityId: id, status: .processing, duplicate: false)
    }

    func deleteActivity(id: UUID) async throws {
        rows[id] = nil
    }

    func activateTrainingPlan(planId: UUID, clientRequestId: UUID) async throws {
        guard var draft = plans.draft, draft.id == planId else { return }
        draft.status = .active
        plans = TrainingPlanState(active: draft, draft: nil)
    }

    func signedActivityImageURL(path: String) async -> URL? { nil }
}
#endif
