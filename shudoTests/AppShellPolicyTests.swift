import Foundation
import Testing
@testable import shudo

// MARK: - Fixtures

private let base = Date(timeIntervalSince1970: 1_791_300_000)  // a fixed instant
private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
private let day = "2026-10-06"

private func coach(_ minutes: Double, _ body: String = "hey", kind: String = "text", id: UUID = UUID(), status: CoachMessageStatus = .delivered) -> CoachMessage {
    CoachMessage(id: id, role: .coach, kind: kind, body: body, localDay: day, deliverAt: at(minutes), status: status)
}

private func me(_ minutes: Double, _ body: String = "yo", request: UUID = UUID(), created: Double? = nil) -> CoachMessage {
    CoachMessage(
        role: .user, kind: "text", body: body, localDay: day, deliverAt: at(minutes),
        clientRequestId: request, createdAt: at(created ?? minutes)
    )
}

private func meal(_ minutes: Double, status: EntryStatus = .complete, kcal: Double = 500, protein: Double = 40) -> Entry {
    Entry(
        id: UUID(), createdAt: at(minutes), summary: "Meal", imageURL: nil,
        proteinG: protein, carbsG: 50, fatG: 10, caloriesKcal: kcal, localDay: day, status: status
    )
}

private func activity(_ minutes: Double) -> Activity {
    Activity(id: UUID(), localDay: day, occurredAt: at(minutes), kind: .strength, title: "Upper A")
}

private func pending(_ minutes: Double, request: UUID = UUID()) -> CoachPendingSend {
    CoachPendingSend(
        clientRequestId: request, text: "sending", inputMode: .typed, localDay: day,
        createdAt: at(minutes), attachmentJPEG: nil, hasAttachment: false, state: .sending
    )
}

// MARK: - Thread merge, grouping, timestamps

struct DayThreadPolicyTests {
    @Test func mergesEverySourceChronologically() {
        let checkIn = WeightCheckIn(
            id: UUID(), localDay: day, weightKG: nil, progressPhotoPath: "u/\(day)/progress-x.jpg",
            photoCapturedAt: at(12), createdAt: at(12), updatedAt: at(12)
        )
        let items = DayThreadPolicy.merge(
            messages: [coach(30, "plan"), coach(5, "recap")],
            pending: [pending(90)],
            entries: [meal(60)],
            activities: [activity(45)],
            checkIn: checkIn,
            typing: nil,
            now: at(100)
        )
        let kinds = items.map { item -> String in
            switch item {
            case .message(let message): return message.body
            case .pending: return "pending"
            case .meal: return "meal"
            case .activity: return "activity"
            case .checkIn: return "checkIn"
            case .typing: return "typing"
            }
        }
        #expect(kinds == ["recap", "checkIn", "plan", "activity", "meal", "pending"])
    }

    @Test func tiesPutLukesSideBeforeTheCoachsAnswer() {
        let reply = coach(10, "answer")
        let question = me(10, "question")
        let items = DayThreadPolicy.merge(
            messages: [reply, question], pending: [], entries: [], activities: [], checkIn: nil,
            typing: nil, now: at(11)
        )
        #expect(items.map(\.side) == [.me, .coach])
    }

    @Test func dropsSupersededHiddenAndAcceptedPendingRows() {
        let request = UUID()
        let accepted = me(20, "accepted", request: request)
        let doomed = meal(30)
        let items = DayThreadPolicy.merge(
            messages: [coach(10, status: .superseded), accepted],
            pending: [pending(20, request: request)],
            entries: [doomed],
            activities: [],
            checkIn: nil,
            typing: nil,
            now: at(40),
            hiddenIds: [DayThreadItem.meal(doomed).id]
        )
        #expect(items.count == 1)
        #expect(items.first?.id == DayThreadItem.message(accepted).id)
    }

    @Test func emptyCheckInsAreNotShown() {
        let empty = WeightCheckIn(id: UUID(), localDay: day, weightKG: nil, progressPhotoPath: nil, createdAt: at(1), updatedAt: at(1))
        let items = DayThreadPolicy.merge(
            messages: [], pending: [], entries: [], activities: [], checkIn: empty, typing: nil, now: at(2)
        )
        #expect(items.isEmpty)
    }

    @Test func thinkingAppendsATypingRowLastButStreamingDoesNot() {
        let messages = [coach(10), me(12)]
        let thinking = DayThreadPolicy.merge(
            messages: messages, pending: [], entries: [], activities: [], checkIn: nil,
            typing: .thinking(label: "Checking what's near you…"), now: at(13)
        )
        guard case .typing(let date)? = thinking.last else {
            Issue.record("expected a typing row")
            return
        }
        #expect(date == at(13), "dots only; the tool label stays behind the scenes")
        let streaming = DayThreadPolicy.merge(
            messages: messages, pending: [], entries: [], activities: [], checkIn: nil,
            typing: .streaming(messageId: UUID()), now: at(13)
        )
        #expect(streaming.count == 2)
    }

    @Test func groupsConsecutiveSameSenderRowsWithIMessagePositions() {
        let items = DayThreadPolicy.merge(
            messages: [coach(0, "a"), coach(1, "b"), coach(2, "c"), me(3), coach(4, "d")],
            pending: [], entries: [], activities: [], checkIn: nil, typing: nil, now: at(5)
        )
        let rows = DayThreadPolicy.rows(for: items)
        #expect(rows.map(\.position) == [.first, .middle, .last, .single, .single])
        #expect(rows.map(\.startsGroup) == [true, false, false, true, true])
    }

    @Test func timestampsOnTheFirstRowAndOnHourLongGaps() {
        let items = DayThreadPolicy.merge(
            messages: [coach(0), coach(45), coach(105), coach(170)],
            pending: [], entries: [], activities: [], checkIn: nil, typing: nil, now: at(180)
        )
        let rows = DayThreadPolicy.rows(for: items)
        #expect(rows.map { $0.timestamp != nil } == [true, false, true, true])
        // A timestamp breaks the group.
        #expect(rows.map(\.position) == [.first, .last, .single, .single])
    }

    @Test func centerPillsBreakGroupsAndTypingNeverGetsATimestamp() {
        let event = CoachMessage(role: .systemEvent, kind: "event", body: "Goals updated", localDay: day, deliverAt: at(1))
        let items = DayThreadPolicy.merge(
            messages: [coach(0), event, coach(2)],
            pending: [], entries: [], activities: [], checkIn: nil,
            typing: .thinking(label: nil), now: at(60)
        )
        let rows = DayThreadPolicy.rows(for: items)
        #expect(rows.map(\.item.side) == [.coach, .center, .coach, .coach])
        #expect(rows[1].startsGroup && rows[2].startsGroup)
        #expect(rows[3].timestamp == nil, "the typing bubble rides with the last group")
        #expect(rows[2].position == .first && rows[3].position == .last)
    }

    @Test func readReceiptSitsUnderLukesLatestTextUntilShudoAnswers() {
        let question = me(10, created: 10)
        let waiting = DayThreadPolicy.rows(for: DayThreadPolicy.merge(
            messages: [question], pending: [], entries: [], activities: [], checkIn: nil,
            typing: .thinking(label: nil), now: at(11)
        ))
        #expect(DayThreadPolicy.readReceiptRowId(for: waiting) == DayThreadItem.message(question).id)

        let answered = DayThreadPolicy.rows(for: DayThreadPolicy.merge(
            messages: [question, coach(11)],
            pending: [], entries: [], activities: [], checkIn: nil, typing: nil, now: at(12)
        ))
        #expect(DayThreadPolicy.readReceiptRowId(for: answered) == nil, "the reply is the receipt")

        let mealLast = DayThreadPolicy.rows(for: DayThreadPolicy.merge(
            messages: [question], pending: [], entries: [meal(20)], activities: [], checkIn: nil, typing: nil, now: at(21)
        ))
        #expect(DayThreadPolicy.readReceiptRowId(for: mealLast) == nil, "only texts get a receipt")

        let sending = DayThreadPolicy.rows(for: DayThreadPolicy.merge(
            messages: [], pending: [pending(5)], entries: [], activities: [], checkIn: nil, typing: nil, now: at(6)
        ))
        #expect(DayThreadPolicy.readReceiptRowId(for: sending) == nil)
    }

    @Test @MainActor func bubblesInARunSitTighterThanCardsAndNewSpeakers() {
        let card = CoachMessage(role: .coach, kind: "plan", body: "Morning.", rawPayload: CoachJSON(encoding: PlanCard(theme: "Eat big.", actions: [])), localDay: day, deliverAt: at(2))
        let rows = DayThreadPolicy.rows(for: DayThreadPolicy.merge(
            messages: [coach(0, "a"), coach(1, "b"), card, me(3)],
            pending: [], entries: [], activities: [], checkIn: nil, typing: nil, now: at(4)
        ))
        // The order is the invariant (tight run < card < new speaker), not
        // the exact points, which are a taste call.
        let run = TodayScreen.spacing(above: rows[1], after: rows[0])
        let cardRoom = TodayScreen.spacing(above: rows[2], after: rows[1])
        let newSpeaker = TodayScreen.spacing(above: rows[3], after: rows[2])
        #expect(TodayScreen.spacing(above: rows[0], after: nil) == 0)
        #expect(run > 0 && run < cardRoom, "a card in the run gets room")
        #expect(cardRoom < newSpeaker, "a new speaker")
    }

    @Test @MainActor func bubbleBeforeItsCardKeepsATightBottomCorner() {
        #expect(TodayScreen.positionBeforeCard(.single) == .first)
        #expect(TodayScreen.positionBeforeCard(.first) == .first)
        #expect(TodayScreen.positionBeforeCard(.middle) == .middle)
        #expect(TodayScreen.positionBeforeCard(.last) == .middle)
    }
}

// MARK: - Header math, week strip, day label

struct DayHeaderMathTests {
    private let target = MacroTarget(caloriesKcal: 2_900, proteinG: 175, carbsG: 365, fatG: 82)

    @Test func remainingAndOver() {
        let under = DayHeaderMath.numbers(
            totals: DayTotals(proteinG: 179, carbsG: 210, fatG: 57, caloriesKcal: 2_045), target: target)
        #expect(under.remainingKcal == 855)
        #expect(under.overKcal == 0 && !under.isOver)
        #expect(under.proteinProgress == 1, "protein past target fills the ring, never overdraws")
        #expect(abs(under.kcalProgress - 2_045.0 / 2_900.0) < 0.0001)

        let over = DayHeaderMath.numbers(
            totals: DayTotals(proteinG: 200, carbsG: 400, fatG: 90, caloriesKcal: 3_100.4), target: target)
        #expect(over.remainingKcal == 0)
        #expect(over.overKcal == 200)
        #expect(over.isOver)

        #expect(DayHeaderMath.remainingLabel(under, isPast: false) == "kcal left")
        #expect(DayHeaderMath.remainingLabel(under, isPast: true) == "kcal short", "a finished day ended short")
        #expect(DayHeaderMath.remainingLabel(over, isPast: true) == "kcal over")
    }

    @Test func zeroOrBrokenTargetsNeverProduceNaN() {
        let numbers = DayHeaderMath.numbers(
            totals: DayTotals(proteinG: .nan, carbsG: 10, fatG: 10, caloriesKcal: .infinity),
            target: MacroTarget(caloriesKcal: 0, proteinG: 0, carbsG: 0, fatG: 0)
        )
        #expect(numbers.kcalProgress == 0 && numbers.proteinProgress == 0)
        #expect(numbers.eatenKcal == 0)
        #expect(DayHeaderMath.progress(50, -10) == 0)
    }

    @Test func pendingDeletesLeaveTheTotalsImmediately() {
        let totals = DayTotals(proteinG: 100, carbsG: 100, fatG: 30, caloriesKcal: 1_200)
        let analyzed = meal(0, kcal: 500, protein: 40)
        let analyzing = meal(1, status: .analyzing, kcal: 0, protein: 0)
        let result = DayHeaderMath.totals(totals, excluding: [analyzed, analyzing])
        #expect(result == DayTotals(proteinG: 60, carbsG: 50, fatG: 20, caloriesKcal: 700))
        let clamped = DayHeaderMath.totals(DayTotals(proteinG: 10, carbsG: 10, fatG: 1, caloriesKcal: 100), excluding: [analyzed])
        #expect(clamped == DayTotals(proteinG: 0, carbsG: 0, fatG: 0, caloriesKcal: 0))
    }

    @Test func weekStripIsMondayFirstWithLiveTotalsForTheSelectedDay() {
        // 2026-10-06 is a Tuesday.
        #expect(WeekStripPolicy.monday(of: "2026-10-06") == "2026-10-05")
        #expect(WeekStripPolicy.monday(of: "2026-10-05") == "2026-10-05")
        #expect(WeekStripPolicy.monday(of: "2026-10-11") == "2026-10-05", "Sunday closes the ISO week")
        let days = WeekStripPolicy.days(
            selectedDay: "2026-10-06",
            today: "2026-10-07",
            totals: [
                DailyNutritionTotal(localDay: "2026-10-05", proteinG: 175, carbsG: 300, fatG: 80, caloriesKcal: 1_450, entryCount: 3),
                DailyNutritionTotal(localDay: "2026-10-06", proteinG: 1, carbsG: 1, fatG: 1, caloriesKcal: 1, entryCount: 1),
            ],
            targetHistory: [],
            fallbackTarget: target,
            selectedTotals: DayTotals(proteinG: 87.5, carbsG: 0, fatG: 0, caloriesKcal: 2_900)
        )
        #expect(days.map(\.letter) == ["M", "T", "W", "T", "F", "S", "S"])
        #expect(days[0].kcalProgress == 0.5 && days[0].proteinProgress == 1 && days[0].hasLog)
        #expect(days[1].isSelected && days[1].kcalProgress == 1 && days[1].proteinProgress == 0.5)
        #expect(days[2].isToday && !days[2].isFuture && !days[2].hasLog)
        #expect(days[3].isFuture)
    }

    @Test func phaseDayCountsFromTheGoalAnchor() {
        #expect(DayLabelPolicy.phaseDay(localDay: "2026-10-06", goalStartedOn: "2026-09-02", goalType: .gain) == "Day 35 of the bulk")
        #expect(DayLabelPolicy.phaseDay(localDay: "2026-10-06", goalStartedOn: "2026-10-06", goalType: .lose) == "Day 1 of the cut")
        #expect(DayLabelPolicy.phaseDay(localDay: "2026-10-01", goalStartedOn: "2026-10-06", goalType: .gain) == nil)
        #expect(DayLabelPolicy.phaseDay(localDay: "2026-10-06", goalStartedOn: nil, goalType: .gain) == nil)
        #expect(DayLabelPolicy.phaseDay(localDay: "2026-10-06", goalStartedOn: "2026-09-02", goalType: .maintain) == nil)
    }

    @Test func threadNamesDaysLikeMessages() {
        #expect(DayLabelPolicy.threadDay(localDay: "2026-10-06", today: "2026-10-06") == "Today")
        #expect(DayLabelPolicy.threadDay(localDay: "2026-10-05", today: "2026-10-06") == "Yesterday")
        #expect(DayLabelPolicy.threadDay(localDay: "2026-10-01", today: "2026-10-06") == "Thursday")
        #expect(DayLabelPolicy.threadDay(localDay: "2026-09-28", today: "2026-10-06") == "Mon, Sep 28")
    }

    @Test func emptyDayGreetsByTheHour() {
        #expect(DayLabelPolicy.greeting(hour: 7, name: "Luke") == "Morning, Luke.")
        #expect(DayLabelPolicy.greeting(hour: 13, name: "Luke Y") == "Afternoon, Luke.")
        #expect(DayLabelPolicy.greeting(hour: 21, name: nil) == "Evening.")
        #expect(DayLabelPolicy.greeting(hour: 2, name: "") == "Evening.")
    }
}

// MARK: - Card copy

struct ThreadCardCopyTests {
    private func option(ref: String = "p3f9", walk: Int = 4, items: [SnackRec.Item]? = nil, query: String = "7-Eleven 2nd Ave") -> SnackRec.Option {
        SnackRec.Option(
            storeRef: ref, storeName: ref == "home" ? "Your kitchen" : "7-Eleven", walkMinutes: walk,
            items: items ?? [
                SnackRec.Item(name: "Core Power Elite", serving: "14 oz", quantity: 2, caloriesKcal: 230, proteinG: 42, carbsG: 8, fatG: 4.5, priceUsdEst: 4.49),
                SnackRec.Item(name: "Chobani Complete", serving: "10 oz", caloriesKcal: 180, proteinG: 25, carbsG: 14, fatG: 3),
            ],
            combined: CoachMacros(caloriesKcal: 640, proteinG: 109, carbsG: 30, fatG: 12),
            remainingAfter: CoachMacros(caloriesKcal: 300, proteinG: 0, carbsG: 50, fatG: 10),
            mapsQuery: query
        )
    }

    @Test func gamePlanLinesGetMatchingIcons() {
        #expect(ThreadCardCopy.planSymbol(for: "175g protein, front-load it") == "bolt.fill")
        #expect(ThreadCardCopy.planSymbol(for: "Upper A at 6:15") == "dumbbell.fill")
        #expect(ThreadCardCopy.planSymbol(for: "Lights out 11:30. Non-negotiable.") == "moon.zzz.fill")
        #expect(ThreadCardCopy.planSymbol(for: "3 meals + a shake · 2,900 kcal") == "fork.knife")
        #expect(ThreadCardCopy.planSymbol(for: "Brown rice with dinner tomorrow") == "fork.knife", "no substring false positives (row, run)")
        #expect(ThreadCardCopy.planSymbol(for: "Call your mom") == "checkmark.circle.fill")
    }

    @Test func recapEyebrowNamesTheDayItCovers() {
        let dayRecap = RecapCard(period: .day, kcal: 2_400)
        #expect(ThreadCardCopy.recapEyebrow(card: dayRecap, localDay: "2026-10-06", deliveredHour: 7) == "Monday recap")
        #expect(ThreadCardCopy.recapEyebrow(card: dayRecap, localDay: "2026-10-06", deliveredHour: 22) == "Tuesday recap")
        #expect(ThreadCardCopy.recapEyebrow(card: RecapCard(period: .week, weekStart: "2026-09-28"), localDay: "2026-10-06", deliveredHour: 9) == "Weekly recap")
        #expect(ThreadCardCopy.proteinVerdict(protein: 181, target: 175) == "protein · hit")
        #expect(ThreadCardCopy.proteinVerdict(protein: 150, target: 175) == "protein · 25g short")
    }

    @Test func snackCardCopy() {
        let store = option()
        #expect(ThreadCardCopy.snackTitle(store) == "Core Power Elite ×2 + Chobani Complete")
        #expect(ThreadCardCopy.snackEyebrow(store) == "7-Eleven · 4 min walk", "the store is the label")
        #expect(ThreadCardCopy.snackEyebrow(option(walk: 2)) == "7-Eleven · 1 block")
        #expect(ThreadCardCopy.snackEyebrow(option(walk: 0)) == "7-Eleven")
        #expect(ThreadCardCopy.snackEyebrow(option(ref: "home")) == "Your kitchen")
        #expect(ThreadCardCopy.snackEyebrow(nil) == "Nearby")
        #expect(ThreadCardCopy.hasDirections(store))
        #expect(!ThreadCardCopy.hasDirections(option(ref: "home")), "home has no route")
        #expect(!ThreadCardCopy.hasDirections(option(ref: "any")), "any store has no route")
        #expect(ThreadCardCopy.snackPayoff(remainingAfter: store.remainingAfter, beforeLift: true) == "Protein closed before you lift.")
        #expect(ThreadCardCopy.snackPayoff(remainingAfter: CoachMacros(caloriesKcal: 0, proteinG: 21.6, carbsG: 0, fatG: 0), beforeLift: false)
            == "22g protein still to go after this.")
    }

    @Test func personalRecordCopy() {
        let weight = WorkoutAckCard.PersonalRecord(exercise: "Incline DB press", kind: .weight, value: 70, unit: "lb", previous: 65)
        #expect(ThreadCardCopy.prValue(weight) == "70 lb")
        #expect(ThreadCardCopy.prDelta(weight) == "+5")
        let e1rm = WorkoutAckCard.PersonalRecord(exercise: "Bench", kind: .e1rm, value: 214.6, unit: "lb")
        #expect(ThreadCardCopy.prValue(e1rm) == "e1RM 214.6 lb")
        #expect(ThreadCardCopy.prDelta(e1rm) == nil)
        let reps = WorkoutAckCard.PersonalRecord(exercise: "Pull-up", kind: .reps, value: 12, unit: "reps", previous: 12)
        #expect(ThreadCardCopy.prValue(reps) == "12 reps")
        #expect(ThreadCardCopy.prDelta(reps) == nil, "a tie isn't a delta")
    }

    @Test func goalLabels() {
        #expect(ThreadCardCopy.goalLabel("gain") == "Lean bulk")
        #expect(ThreadCardCopy.goalLabel("lose") == "Cut")
        #expect(ThreadCardCopy.goalLabel("maintain") == "Maintain")
        #expect(ThreadCardCopy.goalLabel("recomp_phase") == "Recomp Phase")
        #expect(ThreadCardCopy.goalLabel(nil) == nil)
    }
}

// MARK: - Shell policies

struct ShellPolicyTests {
    @Test func mealCompletionFiresOncePerFinishedAnalysis() {
        var tracker = MealCompletionTracker()
        var entry = meal(0, status: .analyzing)
        let done = meal(1)
        #expect(tracker.observe([entry, done]).isEmpty, "already-complete meals are not news")
        entry.status = .analyzing
        #expect(tracker.observe([entry, done]).isEmpty)
        entry.status = .complete
        #expect(tracker.observe([entry, done]) == [entry.id])
        #expect(tracker.observe([entry, done]).isEmpty, "only once")
        var failing = meal(2, status: .queued)
        _ = tracker.observe([failing])
        failing.status = .failed
        #expect(tracker.observe([failing]).isEmpty)
    }

    @Test func threadPresenceNeedsTodayActiveAndNothingOnTop() {
        #expect(CoachPresencePolicy.isThreadVisible(tab: .today, sceneActive: true, isPresentingOverThread: false))
        #expect(!CoachPresencePolicy.isThreadVisible(tab: .body, sceneActive: true, isPresentingOverThread: false))
        #expect(!CoachPresencePolicy.isThreadVisible(tab: .today, sceneActive: false, isPresentingOverThread: false))
        #expect(!CoachPresencePolicy.isThreadVisible(tab: .today, sceneActive: true, isPresentingOverThread: true))
    }

    @Test func captureDraftTracksDictationAndSubmits() {
        var draft = CaptureDraft()
        #expect(draft.submission == nil)
        draft.text = "  had a bar  "
        #expect(draft.submission?.text == "had a bar")
        #expect(draft.submission?.mode == .typed)
        draft.append(VoiceTake(text: "and a coffee", engine: .speechTranscriber, duration: 2))
        #expect(draft.text == "  had a bar  and a coffee" || draft.text.hasSuffix("and a coffee"))
        #expect(draft.submission?.mode == .dictated)
        #expect(draft.submission?.speechEngine == "apple.speech_transcriber")
        draft.append(VoiceTake(text: "   ", engine: .dictationTranscriber, duration: 1))
        #expect(draft.speechEngine == "apple.speech_transcriber", "an empty take changes nothing")
        draft.clear()
        #expect(draft == CaptureDraft())
    }
}

// MARK: - Bio

struct BioPresentationTests {
    @Test func linesTurnBulletsIntoDotsAndKeepParagraphs() {
        let lines = BioPresentation.lines("Lean bulk.\n\n- Bench 225\n* Squat 315\n• Sleep 8h\n## Heading")
        #expect(lines.map(\.isBullet) == [false, true, true, true, false])
        #expect(lines.map(\.text) == ["Lean bulk.", "Bench 225", "Squat 315", "Sleep 8h", "Heading"])
    }

    @Test func revisionsParseAndLabelTheirSource() throws {
        let json = """
        [{"id":"0b6a1d6e-0000-4000-8000-00000000000a","version":6,"source":"bio_update","change_summary":" Lifts moved ","created_at":"2026-10-06T18:00:00.123456+00:00"},
         {"id":"0b6a1d6e-0000-4000-8000-00000000000b","version":1,"source":"seed","change_summary":"","created_at":"2026-09-02T12:00:00Z"},
         {"id":"nope","version":2,"source":"seed","created_at":"2026-09-02T12:00:00Z"}]
        """
        let revisions = try CoachMemoryRevision.parse(Data(json.utf8))
        #expect(revisions.count == 2)
        #expect(revisions[0].version == 6 && revisions[0].changeSummary == "Lifts moved")
        #expect(revisions[0].sourceLabel == "You, by voice")
        #expect(revisions[1].changeSummary == nil && revisions[1].sourceLabel == "Starting bio")
    }
}
