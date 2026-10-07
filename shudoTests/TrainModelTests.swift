import Foundation
import Testing
@testable import shudo

/// Decoding of `activities` / `training_plans` rows and the request shapes
/// sent to `log_activity` and `coach_chat`.
struct TrainModelTests {
    private let userId = "00000000-0000-4000-8000-000000000001"

    // MARK: Activities

    @Test func decodesAPostgRESTActivityRowWithStructuredDetails() throws {
        let json = """
        [{
          "id": "a0000000-0000-4000-8000-000000000001",
          "client_request_id": "c0000000-0000-4000-8000-000000000001",
          "local_day": "2026-10-05",
          "occurred_at": "2026-10-05T22:14:03.123456+00:00",
          "status": "complete",
          "source": "voice",
          "kind": "strength",
          "title": "Upper A",
          "duration_min": 52.0,
          "distance_km": null,
          "active_kcal": 310.5,
          "avg_heart_rate": 128,
          "intensity": "hard",
          "rpe": 8.5,
          "details": {
            "exercises": [
              {"name": "Barbell bench press", "key": "barbell_bench_press",
               "sets": [{"reps": 10, "weight": 95, "unit": "lb", "is_warmup": true},
                        {"reps": 8, "weight": 185, "unit": "lb"},
                        {"reps": 7, "weight": 185, "unit": "lb", "rpe": 9}]}
            ],
            "prs": [{"exercise": "Barbell bench press", "kind": "e1rm", "value": 234, "unit": "lb", "previous": 228}],
            "plan_session_id": "upper_a",
            "burn_method": "met",
            "met": 5.0,
            "weight_kg_used": 73.7,
            "analysis_preview": "Bench 185 for 8, 7"
          },
          "input_text": "bench 185 for 8 and 7",
          "image_path": null,
          "confidence": 0.82,
          "error_message": null,
          "created_at": "2026-10-05T22:14:03+00:00",
          "updated_at": "2026-10-05T22:15:10.5+00:00"
        }]
        """
        let rows = try SupabaseService.parseActivities(Data(json.utf8))
        let activity = try #require(rows.first)
        #expect(activity.id == UUID(uuidString: "A0000000-0000-4000-8000-000000000001"))
        #expect(activity.clientRequestId == UUID(uuidString: "C0000000-0000-4000-8000-000000000001"))
        #expect(activity.localDay == "2026-10-05")
        #expect(activity.status == .complete)
        #expect(activity.kind == .strength)
        #expect(activity.durationMin == 52)
        #expect(activity.activeKcal == 310.5)
        #expect(activity.avgHeartRate == 128)
        #expect(activity.intensity == .hard)
        #expect(activity.planSessionId == "upper_a")
        #expect(activity.details.burnMethod == .met)
        #expect(activity.details.weightKgUsed == 73.7)
        #expect(activity.analysisPreview == "Bench 185 for 8, 7")
        #expect(activity.exercises.count == 1)
        #expect(activity.exercises[0].sets.count == 3)
        #expect(activity.exercises[0].sets[0].isWarmup)
        #expect(activity.exercises[0].workingSets.map(\.reps) == [8, 7])
        #expect(activity.exercises[0].sets[2].rpe == 9)
        #expect(activity.prs == [ActivityPR(exercise: "Barbell bench press", kind: .e1rm, value: 234, unit: "lb", previous: 228)])
        #expect(abs(activity.occurredAt.timeIntervalSince1970 - 1_791_238_443.123) < 0.001)
        #expect(activity.updatedAt > activity.createdAt)
        #expect(activity.localState == nil)
    }

    @Test func toleratesSchemaDriftWithoutDroppingTheRow() throws {
        let json = """
        [{
          "id": "a0000000-0000-4000-8000-000000000002",
          "local_day": "2026-10-05",
          "occurred_at": "2026-10-05 07:10:00+00",
          "status": "processing",
          "kind": "pickleball",
          "title": "  ",
          "duration_min": "12.5",
          "active_kcal": -4,
          "details": {
            "exercises": [
              {"display_name": "Pull-up", "exercise_key": "pull_up",
               "sets": [{"reps": "12"}, "garbage", {"reps": 10, "weight": null, "unit": "kgs"}]},
              {"sets": []}
            ],
            "prs": [{"kind": "e1rm"}]
          },
          "created_at": "2026-10-05T07:10:00Z",
          "updated_at": "2026-10-05T07:10:00Z"
        },
        {"id": "not-a-uuid", "local_day": "2026-10-05", "title": "x"},
        {"id": "a0000000-0000-4000-8000-000000000003", "local_day": "Oct 5", "title": "bad day"}]
        """
        let rows = try SupabaseService.parseActivities(Data(json.utf8))
        #expect(rows.count == 1)
        let activity = try #require(rows.first)
        #expect(activity.kind == .other)
        #expect(activity.title == "Workout")
        #expect(activity.status == .processing)
        #expect(activity.durationMin == 12.5)
        #expect(activity.activeKcal == nil)
        #expect(activity.exercises.map(\.name) == ["Pull-up"])
        #expect(activity.exercises[0].key == "pull_up")
        #expect(activity.exercises[0].sets.map(\.reps) == [12, 10])
        #expect(activity.exercises[0].sets[1].unit == .kg)
        #expect(activity.prs.isEmpty)
        #expect(activity.details.burnMethod == nil)
        #expect(activity.isProcessing)
    }

    @Test func missingDetailsDecodeAsEmpty() throws {
        let json = """
        [{"id": "a0000000-0000-4000-8000-000000000004", "local_day": "2026-10-05",
          "occurred_at": "2026-10-05T12:00:00Z", "status": "failed", "kind": "run", "title": "Run",
          "error_message": "Couldn't read the screenshot",
          "created_at": "2026-10-05T12:00:00Z", "updated_at": "2026-10-05T12:00:00Z"}]
        """
        let activity = try #require(try SupabaseService.parseActivities(Data(json.utf8)).first)
        #expect(activity.details == .empty)
        #expect(activity.status == .failed)
        #expect(!activity.countsTowardHistory)
        #expect(!activity.isProcessing)
    }

    @Test func activityRoundTripsThroughItsOwnEncoding() throws {
        let original = Activity(
            id: UUID(),
            clientRequestId: UUID(),
            localDay: "2026-10-05",
            occurredAt: Date(timeIntervalSince1970: 1_791_200_000),
            status: .complete,
            kind: .strength,
            title: "Lower A",
            durationMin: 60,
            activeKcal: 340,
            details: ActivityDetails(
                exercises: [ActivityExercise(name: "Back squat", key: "back_squat",
                                             sets: [ActivitySet(reps: 5, weight: 225)])],
                prs: [ActivityPR(exercise: "Back squat", kind: .e1rm, value: 262, unit: "lb")],
                planSessionId: "lower_a",
                burnMethod: .met),
            createdAt: Date(timeIntervalSince1970: 1_791_200_000),
            updatedAt: Date(timeIntervalSince1970: 1_791_200_100))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(TrainDateParser.string(from: date))
        }
        let data = try encoder.encode([original])
        let decoded = try SupabaseService.parseActivities(data)
        #expect(decoded == [original])
    }

    @Test func dateParserHandlesPostgresTimestampShapes() {
        let expected = Date(timeIntervalSince1970: 1_791_238_443)
        #expect(TrainDateParser.parse("2026-10-05T22:14:03+00:00") == expected)
        #expect(TrainDateParser.parse("2026-10-05T22:14:03Z") == expected)
        #expect(TrainDateParser.parse("2026-10-05 22:14:03+00") == expected)
        let fractional = TrainDateParser.parse("2026-10-05T22:14:03.123456+00:00")?.timeIntervalSince1970 ?? 0
        #expect(abs(fractional - 1_791_238_443.123) < 0.001)
        #expect(TrainDateParser.parse("2026-10-05T18:14:03-04:00") == expected)
        #expect(TrainDateParser.parse("yesterday") == nil)
    }

    // MARK: Plans

    @Test func decodesTheSpecTrainingPlanDocument() throws {
        let json = """
        [{"id": "b0000000-0000-4000-8000-000000000001", "status": "active",
          "rationale": "Fits a six-day work week.", "change_summary": null, "source": "coach",
          "created_at": "2026-10-01T12:00:00Z", "activated_at": "2026-10-01T12:05:00Z",
          "plan": {"version": 1, "name": "Upper/Lower 4x", "phase": "lean_bulk", "sessions_per_week": 4,
            "rotation": ["upper_a", "lower_a", "upper_b", "lower_b"],
            "sessions": [
              {"id": "upper_a", "name": "Upper A", "focus": "chest/back", "est_minutes": 60,
               "exercises": [{"name": "Barbell bench press", "sets": 4, "rep_min": 6, "rep_max": 8,
                              "rest_sec": 150, "progression": "double", "increment_lb": 5, "cue": "pause on chest"}]},
              {"id": "lower_a", "name": "Lower A", "exercises": [{"name": "Back squat", "sets": 4, "rep_min": 5, "rep_max": 7, "increment_lb": 10}]},
              {"id": "upper_b", "name": "Upper B", "exercises": []},
              {"id": "lower_b", "name": "Lower B", "exercises": []}
            ],
            "conditioning": {"kind": "bike", "minutes": 10, "when": "morning", "optional": true},
            "equipment_assumed": ["commercial gym"], "notes": "Eat big."}}]
        """
        let plans = try SupabaseService.parseTrainingPlans(Data(json.utf8))
        let plan = try #require(plans.first)
        #expect(plan.status == .active)
        #expect(plan.rationale == "Fits a six-day work week.")
        #expect(plan.activatedAt != nil)
        #expect(plan.plan.name == "Upper/Lower 4x")
        #expect(plan.plan.sessionsPerWeek == 4)
        #expect(plan.plan.rotation == ["upper_a", "lower_a", "upper_b", "lower_b"])
        let bench = try #require(plan.plan.session(id: "upper_a")?.exercises.first)
        #expect(bench.sets == 4)
        #expect(bench.repMin == 6)
        #expect(bench.repMax == 8)
        #expect(bench.restSec == 150)
        #expect(bench.progression == "double")
        #expect(bench.incrementLb == 5)
        #expect(bench.cue == "pause on chest")
        #expect(bench.prescription == "4×6–8")
        #expect(plan.plan.session(id: "upper_a")?.estMinutes == 60)
        #expect(plan.plan.conditioning?.summary == "Bike · 10 min · mornings · optional")
        #expect(plan.plan.equipmentAssumed == ["commercial gym"])
    }

    @Test func decodesReportVariantsAndRepairsTheRotation() throws {
        let json = """
        {"name": "Full body", "sessions_per_week_target": 3,
         "rotation": ["fb_a", "ghost", "fb_b"],
         "sessions": [
           {"id": "fb_a", "name": "Full Body A", "exercises": [
             {"exercise_key": "back_squat", "display_name": "Back squat", "sets": "3", "rep_min": 10, "rep_max": 6,
              "progression": {"rule": "double_progression", "increment_lb": 10}},
             {"display_name": "", "sets": 3},
             {"name": "Plank", "reps": 1}
           ]},
           {"id": "fb_b", "exercises": []},
           {"name": "No id"}
         ]}
        """
        let doc = try JSONDecoder().decode(TrainingPlanDoc.self, from: Data(json.utf8))
        #expect(doc.sessionsPerWeek == 3)
        #expect(doc.rotation == ["fb_a", "fb_b"])
        #expect(doc.sessions.map(\.id) == ["fb_a", "fb_b"])
        #expect(doc.session(id: "fb_b")?.name == "Fb B")
        let squat = try #require(doc.session(id: "fb_a")?.exercises.first)
        #expect(squat.key == "back_squat")
        #expect(squat.name == "Back squat")
        #expect(squat.sets == 3)
        #expect(squat.repMin == 6)
        #expect(squat.repMax == 10)
        #expect(squat.progression == "double")
        #expect(squat.incrementLb == 10)
        #expect(doc.session(id: "fb_a")?.exercises.count == 2)
        #expect(doc.session(id: "fb_a")?.exercises.last?.prescription == "3×1")

        let emptyRotation = try JSONDecoder().decode(
            TrainingPlanDoc.self,
            from: Data(#"{"name":"X","sessions_per_week":12,"sessions":[{"id":"a"},{"id":"b"}]}"#.utf8))
        #expect(emptyRotation.rotation == ["a", "b"])
        #expect(emptyRotation.sessionsPerWeek == 2)
    }

    @Test func planRowsTolerateStringJSONAndSkipUnknownStatuses() throws {
        let json = """
        [{"id": "b0000000-0000-4000-8000-000000000002", "status": "draft",
          "plan": "{\\"name\\":\\"Draft\\",\\"sessions\\":[{\\"id\\":\\"a\\",\\"name\\":\\"A\\"}]}",
          "created_at": "2026-10-06T12:00:00Z"},
         {"id": "b0000000-0000-4000-8000-000000000003", "status": "archived", "plan": {"sessions": [{"id": "a"}]},
          "created_at": "2026-10-06T12:00:00Z"},
         {"id": "b0000000-0000-4000-8000-000000000004", "status": "active", "plan": {"sessions": []},
          "created_at": "2026-10-06T12:00:00Z"}]
        """
        let rows = try SupabaseService.parseTrainingPlans(Data(json.utf8))
        #expect(rows.map(\.status) == [.draft])
        #expect(rows.first?.plan.name == "Draft")
    }

    @Test func planStatePicksTheNewestActiveAndDraft() {
        func plan(_ status: TrainingPlanStatus, _ seconds: TimeInterval) -> TrainingPlan {
            TrainingPlan(
                id: UUID(), status: status,
                plan: TrainingPlanDoc(name: "P", sessionsPerWeek: 3, rotation: [], sessions: [
                    TrainingSession(id: "a", name: "A", exercises: [])]),
                createdAt: Date(timeIntervalSince1970: seconds))
        }
        let oldActive = plan(.active, 100)
        let newActive = plan(.active, 200)
        let draft = plan(.draft, 150)
        let state = TrainingPlanState(rows: [oldActive, draft, newActive, plan(.superseded, 300)])
        #expect(state.active?.id == newActive.id)
        #expect(state.draft?.id == draft.id)
    }

    // MARK: log_activity request

    @Test func logActivityMultipartCarriesEveryField() throws {
        let jpeg = Data([0xFF, 0xD8, 0x01, 0x02, 0xFF, 0xD9])
        let request = ActivityLogRequest(
            clientRequestId: UUID(uuidString: "C0000000-0000-4000-8000-0000000000AB")!,
            localDay: "2026-10-06",
            timezone: "America/New_York",
            text: "  Bench 185 for 8, 8, 7  ",
            speechEngine: "apple.speech_transcriber",
            occurredAt: Date(timeIntervalSince1970: 1_791_238_443),
            planSessionId: "upper_a",
            imageJPEG: jpeg,
            kindHint: .strength)
        try SupabaseService.validate(request)
        let body = SupabaseService.makeLogActivityMultipart(boundary: "B", request: request)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("name=\"client_request_id\"\r\n\r\nc0000000-0000-4000-8000-0000000000ab\r\n"))
        #expect(text.contains("name=\"local_day\"\r\n\r\n2026-10-06\r\n"))
        #expect(text.contains("name=\"timezone\"\r\n\r\nAmerica/New_York\r\n"))
        #expect(text.contains("name=\"text\"\r\n\r\nBench 185 for 8, 8, 7\r\n"))
        #expect(text.contains("name=\"speech_engine\"\r\n\r\napple.speech_transcriber\r\n"))
        #expect(text.contains("name=\"occurred_at\"\r\n\r\n2026-10-05T22:14:03.000Z\r\n"))
        #expect(text.contains("name=\"plan_session_id\"\r\n\r\nupper_a\r\n"))
        #expect(text.contains("name=\"kind_hint\"\r\n\r\nstrength\r\n"))
        #expect(text.contains("name=\"image\"; filename=\"workout.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"))
        #expect(body.range(of: jpeg) != nil)
        #expect(text.hasSuffix("--B--\r\n"))
    }

    @Test func photoOnlyLogsSendAPlaceholderTextAndOptionalFieldsAreOmitted() throws {
        let request = ActivityLogRequest(
            localDay: "2026-10-06", timezone: "America/New_York", text: " ",
            imageJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        try SupabaseService.validate(request)
        let text = String(decoding: SupabaseService.makeLogActivityMultipart(boundary: "B", request: request), as: UTF8.self)
        #expect(text.contains("name=\"text\"\r\n\r\n\(SupabaseService.photoOnlyActivityText)\r\n"))
        #expect(!text.contains("speech_engine"))
        #expect(!text.contains("plan_session_id"))
        #expect(!text.contains("occurred_at"))
        #expect(!text.contains("kind_hint"))
    }

    @Test func logActivityValidationRejectsBadPayloads() {
        func rejects(_ request: ActivityLogRequest) -> Bool {
            (try? SupabaseService.validate(request)) == nil
        }
        let base = ActivityLogRequest(localDay: "2026-10-06", timezone: "America/New_York", text: "ran 3 miles")
        var empty = base
        empty.text = "   "
        var long = base
        long.text = String(repeating: "a", count: 4_001)
        var notJPEG = base
        notJPEG.imageJPEG = Data([0x89, 0x50, 0x4E, 0x47])
        var huge = base
        huge.imageJPEG = Data([0xFF, 0xD8]) + Data(count: SupabaseService.maximumActivityPhotoBytes) + Data([0xFF, 0xD9])
        var badDay = base
        badDay.localDay = "10/06/2026"
        var badZone = base
        badZone.timezone = "Mars/Olympus"
        #expect(!rejects(base))
        #expect(rejects(empty))
        #expect(rejects(long))
        #expect(rejects(notJPEG))
        #expect(rejects(huge))
        #expect(rejects(badDay))
        #expect(rejects(badZone))
    }

    @Test func parsesLogActivityResponses() throws {
        let accepted = try SupabaseService.parseLogActivityResponse(
            statusCode: 202,
            data: Data(#"{"activity_id":"a0000000-0000-4000-8000-000000000009","status":"processing","duplicate":false}"#.utf8))
        #expect(accepted == ActivityLogResult(
            activityId: UUID(uuidString: "A0000000-0000-4000-8000-000000000009")!, status: .processing, duplicate: false))

        let duplicate = try SupabaseService.parseLogActivityResponse(
            statusCode: 200,
            data: Data(#"{"activity_id":"a0000000-0000-4000-8000-000000000009","status":"complete","duplicate":true}"#.utf8))
        #expect(duplicate.duplicate)
        #expect(duplicate.status == .complete)

        #expect(throws: TrainServiceError.server(statusCode: 429, message: "Daily workout limit reached")) {
            try SupabaseService.parseLogActivityResponse(
                statusCode: 429, data: Data(#"{"error":"Daily workout limit reached"}"#.utf8))
        }
        #expect(throws: TrainServiceError.invalidResponse) {
            try SupabaseService.parseLogActivityResponse(statusCode: 202, data: Data("{}".utf8))
        }
    }

    @Test func planActivationUsesTheCoachChatCardActionShape() throws {
        let body = try SupabaseService.trainingPlanActionBody(
            planId: UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!,
            decision: "activate",
            clientRequestId: UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["client_request_id"] as? String == "c0000000-0000-4000-8000-000000000001")
        let action = try #require(object["action"] as? [String: String])
        #expect(action == ["kind": "training_plan", "id": "b0000000-0000-4000-8000-000000000001", "decision": "activate"])
    }

    @Test func activityPhotosMustLiveUnderTheOwnersCoachMediaFolder() {
        let mine = "\(userId)/2026-10-06/activity-0f8fad5b-d9cb-469f-a165-70867728950e.jpg"
        #expect(SupabaseService.activityImagePathBelongsToUser(mine, userId: userId))
        #expect(SupabaseService.activityImagePathBelongsToUser(
            "\(userId)/2026-10-06/chat-0f8fad5b-d9cb-469f-a165-70867728950e.jpg", userId: userId))
        #expect(!SupabaseService.activityImagePathBelongsToUser(
            "00000000-0000-4000-8000-000000000002/2026-10-06/activity-0f8fad5b-d9cb-469f-a165-70867728950e.jpg",
            userId: userId))
        #expect(!SupabaseService.activityImagePathBelongsToUser("\(userId)/../secrets.jpg", userId: userId))
        #expect(!SupabaseService.activityImagePathBelongsToUser(mine, userId: "nope"))
    }
}
