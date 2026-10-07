#if DEBUG
import SwiftUI
import UIKit

/// Offline app shell for PolishPreview and UI tests: one believable lean-bulk
/// day (162.5 → 175 lb, five weeks in) told as a thread — yesterday's recap
/// and the morning game plan, a check-in photo, meal receipts with the
/// coach's reactions, a protein-gap nudge that turns into a nearby snack
/// card, the evening lift with a PR, Luke's replies, and dinner still
/// analyzing. The clock is pinned to 7:40 PM New York so timestamps read the
/// same whenever the screenshot is taken.
///
/// Launch with `-shudoPolishPreview main | today-expanded | today-cards`;
/// add `-shudoTodayPreview typing` to start a coach turn that stays in the
/// "thinking" state (typing indicator), `quiet` for a light day (the plan and
/// two meals), or `empty` for a fresh day with nothing in it yet.
enum ShellPreviewFixtures {
    static let timezone = "America/New_York"
    static let userId = "00000000-0000-4000-8000-000000000001"
    static let chickenBowlId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let upperAId = UUID(uuidString: "A0000000-0000-4000-8000-0000000000AA")!

    static var options: Set<String> {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-shudoTodayPreview"),
              arguments.indices.contains(flag + 1) else { return [] }
        return Set(arguments[flag + 1].split(separator: ",").map { String($0).lowercased() })
    }

    // MARK: Clock

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        return calendar
    }

    static var today: String { LocalDayMath.today(in: timezone) }

    /// Today at `hour:minute` New York time.
    static func at(_ hour: Int, _ minute: Int) -> Date {
        let start = calendar.startOfDay(for: Date())
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start) ?? start
    }

    /// The preview's "now": 7:40 PM today, advancing in real time.
    private static let clockOffset: TimeInterval = at(19, 40).timeIntervalSince(Date())
    static func now() -> Date { Date().addingTimeInterval(clockOffset) }

    // MARK: Profile

    static var profile: Profile {
        Profile(
            userId: userId,
            timezone: timezone,
            dailyMacroTarget: MacroTarget(caloriesKcal: 2_900, proteinG: 175, carbsG: 365, fatG: 82),
            units: "imperial",
            heightCM: 177.8,
            weightKG: BodyUnits.kilograms(pounds: 162.5),
            targetWeightKG: BodyUnits.kilograms(pounds: 175),
            displayName: "Luke",
            activityLevel: .active,
            goalType: .gain,
            goalNotes: "Lean bulk to 175. Lift four days a week.",
            onboardingStatus: .completed,
            onboardingCompletedAt: Date(),
            avatarPath: nil
        )
    }

    // MARK: Meals

    static func entries() -> [Entry] {
        if options.contains("empty") { return [] }
        if options.contains("quiet") { return Array(allEntries().prefix(2)) }
        return allEntries()
    }

    private static func allEntries() -> [Entry] {
        [
            Entry(
                id: UUID(uuidString: "11111111-1111-4111-8111-0000000000E1")!,
                createdAt: at(7, 40), summary: "Eggs, rice, banana", imageURL: nil,
                proteinG: 38, carbsG: 92, fatG: 14, caloriesKcal: 640, localDay: today, status: .complete
            ),
            Entry(
                id: chickenBowlId,
                createdAt: at(12, 41), summary: "Chicken rice bowl", imageURL: nil,
                proteinG: 58, carbsG: 72, fatG: 19, caloriesKcal: 695, localDay: today, status: .complete
            ),
            Entry(
                id: UUID(uuidString: "11111111-1111-4111-8111-0000000000E3")!,
                createdAt: at(14, 15), summary: "Whole milk, 16 oz", imageURL: nil,
                proteinG: 16, carbsG: 24, fatG: 16, caloriesKcal: 300, localDay: today, status: .complete
            ),
            Entry(
                id: UUID(uuidString: "11111111-1111-4111-8111-0000000000E4")!,
                createdAt: at(15, 52), summary: "Core Power Elite + Chobani Complete", imageURL: nil,
                proteinG: 67, carbsG: 22, fatG: 8, caloriesKcal: 410, localDay: today, status: .complete,
                analysisNotes: "Label values.\n\nOnline sources: [fairlife.com](https://fairlife.com), [chobani.com](https://www.chobani.com)."
            ),
            Entry(
                id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                createdAt: at(19, 38), summary: "Steak, two cups of rice, broccoli", imageURL: nil,
                proteinG: 0, carbsG: 0, fatG: 0, caloriesKcal: 0, localDay: today,
                status: .analyzing,
                statusMessage: "Checking nutrition sources",
                statusUpdatedAt: Date(),
                analysisPreview: "8 oz sirloin, 2 cups cooked white rice, 1 cup broccoli with butter — about 1,050 kcal so far…"
            ),
        ]
    }

    /// The lunch bowl after a correction lands (smaller rice portion).
    static func correctedChickenBowl() -> Entry {
        Entry(
            id: chickenBowlId,
            createdAt: at(12, 41), summary: "Chicken rice bowl", imageURL: nil,
            proteinG: 57, carbsG: 49, fatG: 18, caloriesKcal: 560, localDay: today,
            status: .complete, statusMessage: "Ready", statusUpdatedAt: Date()
        )
    }

    // MARK: Workouts

    static var upperA: Activity {
        Activity(
            id: upperAId,
            clientRequestId: UUID(uuidString: "A0000000-0000-4000-8000-0000000000AB"),
            localDay: today,
            occurredAt: at(18, 15),
            status: .complete,
            source: "voice",
            kind: .strength,
            title: "Upper A",
            durationMin: 58,
            activeKcal: 310,
            details: ActivityDetails(
                exercises: [
                    ActivityExercise(name: "Barbell bench press", sets: [175, 175, 175, 175].map { ActivitySet(reps: 8, weight: $0) }),
                    ActivityExercise(name: "Incline DB press", sets: [70, 70, 70, 70].map { ActivitySet(reps: 10, weight: $0) }),
                    ActivityExercise(name: "Weighted pull-up", sets: [25, 25, 25, 25].map { ActivitySet(reps: 8, weight: $0) }),
                    ActivityExercise(name: "Cable fly", sets: [30, 30, 30].map { ActivitySet(reps: 15, weight: $0) }),
                ],
                prs: [ActivityPR(exercise: "Incline DB press", kind: .weight, value: 70, unit: "lb", previous: 65)],
                planSessionId: "upper_a",
                burnMethod: .met
            ),
            inputText: "Upper A. Bench 175 for 4 sets of 8, incline 70s for ten, pull-ups plus 25, cable fly.",
            createdAt: at(19, 20),
            updatedAt: at(19, 20)
        )
    }

    // MARK: Coach thread

    static func messages() -> [CoachMessage] {
        let snack = SnackRec(
            headline: "Grab a Core Power and a Chobani",
            verdict: .grab,
            options: [
                SnackRec.Option(
                    storeRef: "p3f9a1c2b7d",
                    storeName: "7-Eleven",
                    walkMinutes: 4,
                    items: [
                        SnackRec.Item(name: "Core Power Elite", brand: "Fairlife", serving: "14 oz bottle", caloriesKcal: 230, proteinG: 42, carbsG: 8, fatG: 4.5, priceUsdEst: 4.49, nutritionSource: "label_known"),
                        SnackRec.Item(name: "Chobani Complete", brand: "Chobani", serving: "10 oz bottle", caloriesKcal: 180, proteinG: 25, carbsG: 14, fatG: 3, priceUsdEst: 3.79, nutritionSource: "web"),
                    ],
                    combined: CoachMacros(caloriesKcal: 410, proteinG: 67, carbsG: 22, fatG: 7.5),
                    remainingAfter: CoachMacros(caloriesKcal: 855, proteinG: 0, carbsG: 155, fatG: 25),
                    mapsQuery: "7-Eleven 2nd Ave"
                ),
            ],
            sources: ["https://fairlife.com", "https://www.chobani.com"]
        )
        var snackPayload = CoachJSON(encoding: snack).objectValue ?? [:]
        snackPayload["status"] = .string("logged")

        let recap = RecapCard(
            period: .day, kcal: 2_410, proteinG: 181, kcalTarget: 2_900, proteinTargetG: 175,
            headline: "Protein hit. Calories short again."
        )
        let plan = PlanCard(
            theme: "Eat big. Upper tonight.",
            remaining: nil,
            actions: [
                "3 meals + a shake · 2,900 kcal",
                "175g protein, front-load it",
                "Upper A at 6:15",
                "Lights out 11:30. Non-negotiable.",
            ]
        )
        let workout = WorkoutAckCard(
            activityId: upperAId,
            prs: [.init(exercise: "Incline DB press", kind: .weight, value: 70, unit: "lb", previous: 65)]
        )
        let checkIn = CheckInCard(kind: .weighInAck, localDay: today)
        let day = today

        func coach(_ id: String, _ kind: String, _ body: String, _ time: Date, payload: CoachJSON = .object([:]), slot: String? = nil) -> CoachMessage {
            CoachMessage(
                id: UUID(uuidString: "C0000000-0000-4000-8000-\(id)")!,
                role: .coach, kind: kind, body: body, rawPayload: payload,
                localDay: day, deliverAt: time, status: .delivered, slotKey: slot,
                readAt: time, createdAt: time, updatedAt: time
            )
        }
        func me(_ id: String, _ body: String, _ time: Date) -> CoachMessage {
            CoachMessage(
                id: UUID(uuidString: "D0000000-0000-4000-8000-\(id)")!,
                role: .user, kind: "text", body: body,
                localDay: day, deliverAt: time, status: .delivered,
                clientRequestId: UUID(uuidString: "E0000000-0000-4000-8000-\(id)"),
                createdAt: time, updatedAt: time
            )
        }

        let thread = [
            coach("000000000001", "recap", "Yesterday, scored.", at(6, 52), payload: CoachJSON(encoding: recap), slot: "wake"),
            coach("000000000002", "plan", "Morning. Liquid calories today — milk with every meal.", at(6, 58), payload: CoachJSON(encoding: plan), slot: "wake"),
            coach("000000000003", "weigh_in_ack", "Photo’s in. Same pose, same light. That’s how we see it move.", at(7, 14), payload: CoachJSON(encoding: checkIn)),
            coach("000000000004", "meal_ack", "38 grams before eight. Good start.", at(7, 42), payload: .object(["entry_id": .string("11111111-1111-4111-8111-0000000000e1")])),
            me("000000000005", "office day, slammed till 2", at(9, 47)),
            coach("000000000006", "text", "Then lunch is the anchor. Make it big — chicken, rice, the works.", at(9, 47)),
            coach("000000000007", "meal_ack", "58 grams in one sitting. That’s how it’s done.", at(12, 44), payload: .object(["entry_id": .string(chickenBowlId.uuidString.lowercased())])),
            coach("000000000008", "text", "1,565 still to eat. Don’t you dare skip dinner.", at(12, 44)),
            coach("000000000009", "checkpoint", "Slump o’clock. You’re 63g of protein short and the lift is in under three hours.", at(15, 28), slot: "afternoon"),
            coach("00000000000a", "snack_rec", "7-Eleven is four minutes out. Here’s the play.", at(15, 29), payload: .object(snackPayload)),
            me("00000000000b", "on my way", at(15, 31)),
            coach("00000000000c", "meal_ack", "Protein’s closed before you lift. Go get it.", at(15, 53), payload: .object(["entry_id": .string("11111111-1111-4111-8111-0000000000e4")])),
            coach("00000000000d", "workout_ack", "Incline PR. 70s for ten — that’s new territory.", at(19, 21), payload: CoachJSON(encoding: workout)),
            me("00000000000e", "dinner is steak and rice. anything else?", at(19, 34)),
            coach("00000000000f", "text", "855 left and the lift earned every one. Steak, two cups of rice, and a glass of milk closes the day.", at(19, 35)),
        ]
        if options.contains("empty") { return [] }
        if options.contains("quiet") {
            let quiet: Set<String> = ["000000000002", "000000000004", "000000000007"]
            return thread.filter { quiet.contains(String($0.id.uuidString.suffix(12)).lowercased()) }
        }
        return thread
    }

    /// Every other card kind, for `-shudoPolishPreview today-cards`.
    static func cardMessages() -> [CoachMessage] {
        let day = today
        func coach(_ id: String, _ kind: String, _ body: String, _ time: Date, payload: CoachJSON) -> CoachMessage {
            CoachMessage(
                id: UUID(uuidString: "F0000000-0000-4000-8000-\(id)")!,
                role: .coach, kind: kind, body: body, rawPayload: payload,
                localDay: day, deliverAt: time, status: .delivered,
                readAt: time, createdAt: time, updatedAt: time
            )
        }
        let goal = GoalChangeCard(
            changeId: UUID(uuidString: "F1000000-0000-4000-8000-000000000001")!,
            status: .needsConfirmation,
            before: GoalSnapshot(caloriesKcal: 2_650, proteinG: 165, carbsG: 320, fatG: 78, goalType: "gain", targetWeightKg: BodyUnits.kilograms(pounds: 175)),
            after: GoalSnapshot(caloriesKcal: 2_900, proteinG: 175, carbsG: 365, fatG: 82, goalType: "gain", targetWeightKg: BodyUnits.kilograms(pounds: 175), goalDate: "2027-04-15"),
            projectedGoalDate: "2027-04-15",
            warnings: []
        )
        let training = TrainingPlanCard(
            planId: UUID(uuidString: "F2000000-0000-4000-8000-000000000001")!,
            status: .draft,
            name: "Upper/Lower 4x",
            sessionsPerWeek: 4,
            summary: "Two upper, two lower. Bench and squat twice a week, double progression on everything.",
            sessions: [
                .init(id: "upper_a", name: "Upper A", estMinutes: 60, topExercises: ["Bench press", "Barbell row"]),
                .init(id: "lower_a", name: "Lower A", estMinutes: 55, topExercises: ["Back squat", "RDL"]),
                .init(id: "upper_b", name: "Upper B", estMinutes: 60, topExercises: ["Incline DB press", "Pull-up"]),
                .init(id: "lower_b", name: "Lower B", estMinutes: 50, topExercises: ["Deadlift", "Leg press"]),
            ]
        )
        let bio = ProfileUpdateCard(
            memoryVersion: 6,
            changes: [
                .init(section: "schedule", op: .replace, summary: "Lifts moved to 6:15 PM on Mon, Wed, Fri, Sat"),
                .init(section: "equipment", op: .add, summary: "Food scale arriving next week"),
            ],
            undoVersion: 5
        )
        let review = CheckInCard(
            kind: .photoFeedback,
            localDay: day,
            review: .init(
                headline: "Delts are filling out; waist hasn’t moved.",
                observations: ["Upper chest fuller than four weeks ago", "Same lighting and pose — good comparisons"],
                bulkQuality: "clean"
            )
        )
        let weighIn = CheckInCard(kind: .weighInAck, localDay: day, weightKg: BodyUnits.kilograms(pounds: 165.3))
        let weekly = RecapCard(period: .week, headline: "Four lifts, six days on target.", weekStart: LocalDayMath.adding(-7, to: day))
        return [
            coach("000000000001", "goal_change", "Ate to 2,650 all week and the scale barely moved. Bumping you to 2,900.", at(8, 5), payload: CoachJSON(encoding: goal)),
            coach("000000000002", "training_plan", "Your plan’s ready. Four days, built around the schedule you gave me.", at(9, 30), payload: CoachJSON(encoding: training)),
            coach("000000000003", "profile_update", "Got it. Updated your bio.", at(10, 2), payload: CoachJSON(encoding: bio)),
            coach("000000000004", "weigh_in_ack", "165.3. Trend’s climbing right on pace.", at(10, 40), payload: CoachJSON(encoding: weighIn)),
            coach("000000000005", "photo_feedback", "Monday photo review is in.", at(11, 10), payload: CoachJSON(encoding: review)),
            coach("000000000006", "recap", "Last week, scored.", at(11, 30), payload: CoachJSON(encoding: weekly)),
        ]
    }

    static let memory = CoachMemoryDocument(
        version: 6,
        document: "# Luke\n\nLean bulk 162.5 → 175 lb.",
        bio: CoachMemoryDocument.bioSections([
            "about": .string("Software engineer, 30s, New York. Coaches himself; wants a coach with opinions."),
            "goals": .string("Lean bulk from **162.5 → 175 lb** without losing his midsection.\n- Bench 225 for reps\n- Look like he lifts in a T-shirt"),
            "schedule": .string("- Office Tue–Thu, slammed until about 2\n- Lifts after work, **6:15 PM**, Mon/Wed/Fri/Sat\n- Lights out target 11:30"),
            "current_training": .string("Upper/Lower 4x. Bench and squat twice a week, double progression."),
            "nutrition": .string("Eats big lunches, under-eats on office mornings. Likes milk, rice, chicken, Chipotle."),
            "equipment": .string("Commercial gym. Food scale arriving next week."),
        ]),
        notes: [
            "protein": "Misses protein on office mornings; a shake at 10 fixes it.",
            "evenings": "Skips dinner after late lifts unless reminded by 7.",
        ],
        schedule: CoachSchedule(wake: "07:00", officeStart: "09:30", officeDays: ["tue", "wed", "thu"], liftDays: ["mon", "wed", "fri", "sat"], liftTime: "18:15", bed: "23:30", targetBed: "23:00"),
        equipment: ["commercial gym"],
        updatedSource: "bio_update",
        updatedAt: Date().addingTimeInterval(-2 * 3_600)
    )

    static var revisions: [CoachMemoryRevision] {
        let base = Date()
        return [
            CoachMemoryRevision(id: UUID(), version: 6, source: "bio_update", changeSummary: "Lifts moved to 6:15 PM; food scale coming", createdAt: base.addingTimeInterval(-2 * 3_600)),
            CoachMemoryRevision(id: UUID(), version: 5, source: "day_digest", changeSummary: "Noted: under-eats on office mornings", createdAt: base.addingTimeInterval(-20 * 3_600)),
            CoachMemoryRevision(id: UUID(), version: 4, source: "coach_reply", changeSummary: "Goal: bench 225 for reps", createdAt: base.addingTimeInterval(-3 * 86_400)),
            CoachMemoryRevision(id: UUID(), version: 1, source: "seed", changeSummary: nil, createdAt: base.addingTimeInterval(-34 * 86_400)),
        ]
    }

    static var settingsEnabled: CoachSettings {
        var settings = CoachSettings.defaults
        settings.enabled = true
        settings.locationRecsEnabled = true
        return settings
    }

    // MARK: Services

    static func coachService(cards: Bool, settings: CoachSettings = .defaults) -> FakeCoachService {
        let service = FakeCoachService(
            messages: cards ? cardMessages() : messages(),
            memory: memory,
            settings: settings,
            stepDelayMilliseconds: 90,
            now: { ShellPreviewFixtures.now() },
            script: FakeCoachService.replyScript(
                reply: ["Copy that. ", "Logging it now — ", "I’ll check the numbers when it lands."],
                statusLabel: "Checking your day…"
            )
        )
        if options.contains("typing") {
            service.script = { _, context in
                [
                    .event(.accepted(runId: context.runId, userMessage: context.userMessage, duplicate: false)),
                    .event(.status(label: "Checking what’s near you…")),
                    .pause(milliseconds: 600_000),
                ]
            }
        }
        return service
    }

    static func trainService() -> PreviewTrainService {
        let history = TrainPreviewFixtures.activities.filter { $0.localDay != today }
        let lifted = options.isDisjoint(with: ["quiet", "empty"])
        return PreviewTrainService(
            plans: TrainingPlanState(active: TrainPreviewFixtures.activePlan),
            activities: history + (lifted ? [upperA] : [])
        )
    }

    static func bodyService() -> ShellPreviewBodyService {
        let checkIns = BodyFixtures.checkIns(today: today, noScale: false, empty: options.contains("empty"))
        return ShellPreviewBodyService(
            base: FixtureBodyService(checkIns: checkIns, nutrition: BodyFixtures.nutrition(today: today)),
            goalStartedOn: LocalDayMath.adding(-34, to: today)
        )
    }

    @MainActor
    static func dependencies(
        variant: PolishPreviewScreen,
        makeToday: @escaping () -> TodayViewModel,
        entryDetail: SupabaseService.EntryDetail,
        composerSeedImages: [UIImage]
    ) -> ShellDependencies {
        let coach = coachService(cards: variant == .todayCards)
        let train = trainService()
        let body = bodyService()
        return ShellDependencies(
            loadsRemotely: false,
            makeToday: makeToday,
            makeCoach: {
                CoachViewModel(
                    service: coach,
                    localDay: today,
                    timeZone: { TimeZone(identifier: timezone) ?? .autoupdatingCurrent },
                    now: { ShellPreviewFixtures.now() }
                )
            },
            coachService: coach,
            trainService: train,
            bodyService: body,
            recordEvent: { _ in },
            bioRevisions: { revisions },
            coachMediaURL: { _ in nil },
            makeBodyScreen: { _, _ in AnyView(BodyScreen(previewModel: BodyFixtures.model())) },
            makeTrainViewModel: { _, logging in
                TrainViewModel(
                    profile: TrainPreviewFixtures.profile,
                    service: train,
                    logging: logging,
                    preloadedPlans: TrainingPlanState(active: TrainPreviewFixtures.activePlan),
                    preloadedActivities: TrainPreviewFixtures.activities.filter { $0.localDay != today } + [upperA]
                )
            },
            makeAccountView: { profile, hooks in
                AnyView(AccountView(previewProfile: profile, profilePhoto: UIImage(), hooks: hooks))
            },
            previewEntryDetail: entryDetail,
            composerSeedImages: composerSeedImages,
            now: { ShellPreviewFixtures.now() },
            initialTab: .today,
            initialHeaderExpanded: variant == .todayExpanded,
            onLaunch: { coach in
                guard options.contains("typing") else { return }
                coach.send(text: "anything else I should grab on the way home?", mode: .typed)
            }
        )
    }

    /// Settings sheet hooks with the fake coach (preview / UI tests).
    @MainActor
    static func accountHooks(settings: CoachSettings) -> AccountView.ShellHooks {
        let coach = coachService(cards: false, settings: settings)
        return AccountView.ShellHooks(
            coachService: coach,
            loadsRemotely: false,
            onProfileUpdated: { _ in },
            onSettingsChanged: { _ in },
            openBio: {},
            bioDestination: {
                AnyView(BioView(coachService: coach, loadRevisions: { revisions }, onSend: { _, _ in }))
            },
            onSignOut: {}
        )
    }
}

/// Body fixtures with the goal anchor set, so Today reads "Day 35 of the bulk".
struct ShellPreviewBodyService: BodyServicing {
    let base: FixtureBodyService
    let goalStartedOn: String?

    func checkIns(limit: Int) async throws -> [WeightCheckIn] { try await base.checkIns(limit: limit) }
    func goalSettings() async throws -> BodyGoalSettings {
        BodyGoalSettings(
            goalType: .gain,
            targetWeightKG: BodyUnits.kilograms(pounds: 175),
            selfReportedWeightKG: BodyUnits.kilograms(pounds: 162.5),
            goalStartedOn: goalStartedOn,
            goalStartWeightKG: BodyUnits.kilograms(pounds: 162.5)
        )
    }
    func nutrition(timezone: String) async throws -> BodyNutritionHistory { try await base.nutrition(timezone: timezone) }
    func weeklySummaries(limit: Int) async throws -> [WeeklyInsightSummary] { [] }
    func photoData(path: String) async throws -> Data { try await base.photoData(path: path) }
    func save(_ draft: BodyCheckInDraft, replacing existing: WeightCheckIn?, updatesProfileWeight: Bool) async throws -> WeightCheckIn {
        try await base.save(draft, replacing: existing, updatesProfileWeight: updatesProfileWeight)
    }
    func removePhoto(_ checkIn: WeightCheckIn) async throws -> WeightCheckIn? { try await base.removePhoto(checkIn) }
    func anchorGoal(startedOn: String, startWeightKG: Double) async throws {}
}
#endif
