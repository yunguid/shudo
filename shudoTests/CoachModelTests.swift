import Foundation
import Testing
@testable import shudo

struct CoachModelTests {
    private static let day = "2026-10-06"

    private func row(
        kind: String,
        role: String = "coach",
        payload: String = "{}",
        extra: String = ""
    ) -> String {
        """
        {"id":"5f0c7a52-1c1e-4d5e-9a63-1d2b3c4d5e6f","user_id":"11111111-2222-3333-4444-555555555555",
         "role":"\(role)","kind":"\(kind)","body":"Body text","payload":\(payload),
         "local_day":"\(Self.day)","deliver_at":"2026-10-06T14:05:00.123456+00:00",
         "status":"delivered","notify":false,"slot_key":null,"entry_id":null,"activity_id":null,
         "attachment_path":null,"client_request_id":null,"reply_to_id":null,"read_at":null,
         "created_at":"2026-10-06T14:04:59.5+00:00","updated_at":"2026-10-06T14:05:01Z"\(extra)}
        """
    }

    private func decode(_ json: String) throws -> CoachMessage {
        try JSONDecoder().decode(CoachMessage.self, from: Data(json.utf8))
    }

    // MARK: Message rows

    @Test func decodesAPostgRESTRowWithMicrosecondTimestamps() throws {
        let message = try decode(row(kind: "text"))
        #expect(message.id == UUID(uuidString: "5f0c7a52-1c1e-4d5e-9a63-1d2b3c4d5e6f"))
        #expect(message.role == .coach)
        #expect(message.kind == "text")
        #expect(message.payload == .none)
        #expect(message.localDay == Self.day)
        #expect(message.status == .delivered)
        let expected = try #require(CoachDateCoding.date(from: "2026-10-06T14:05:00.123Z"))
        #expect(abs(message.deliverAt.timeIntervalSince(expected)) < 0.001)
        #expect(message.updatedAt > message.deliverAt)
        #expect(!message.isStreaming)
        #expect(message.pushBody == nil)
    }

    @Test func toleratesUnknownRolesStatusesAndPostgresTextTimestamps() throws {
        let json = row(kind: "text").replacingOccurrences(of: "\"status\":\"delivered\"", with: "\"status\":\"weird\"")
            .replacingOccurrences(of: "\"role\":\"coach\"", with: "\"role\":\"robot\"")
        let message = try decode(json)
        #expect(message.role == .systemEvent)
        #expect(message.status == .delivered)
        #expect(CoachDateCoding.date(from: "2026-10-06 14:05:00.123456+00") != nil)
    }

    @Test func readsStreamingInterruptedAndPushBodyFromPayload() throws {
        let streaming = try decode(row(kind: "text", payload: #"{"streaming":true,"push_body":"  Eat.  "}"#))
        #expect(streaming.isStreaming)
        #expect(!streaming.isInterrupted)
        #expect(streaming.pushBody == "Eat.")
        #expect(streaming.notificationText == "Eat.")

        let interrupted = try decode(row(kind: "text", payload: #"{"streaming":true,"interrupted":true}"#))
        #expect(interrupted.isInterrupted)
        #expect(!interrupted.isStreaming)

        let nullPush = try decode(row(kind: "text", payload: #"{"push_body":null}"#))
        #expect(nullPush.pushBody == nil)
        #expect(nullPush.notificationText == "Body text")
    }

    @Test func payloadSentAsAJSONStringIsParsed() throws {
        let message = try decode(row(kind: "meal_ack", payload: #""{\"entry_id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\"}""#))
        #expect(message.payload == .mealAck(entryId: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!))
    }

    @Test func roundTripsThroughItsOwnEncoding() throws {
        let original = try decode(row(kind: "plan", payload: #"{"theme":"Protein early","actions":["40 g by 10"]}"#))
        let data = try JSONEncoder().encode(original)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["id"] as? String == "5f0c7a52-1c1e-4d5e-9a63-1d2b3c4d5e6f")
        #expect(object["local_day"] as? String == Self.day)
        let decoded = try JSONDecoder().decode(CoachMessage.self, from: data)
        #expect(decoded.payload == original.payload)
        #expect(decoded.id == original.id)
        #expect(abs(decoded.deliverAt.timeIntervalSince(original.deliverAt)) < 0.001)
    }

    @Test func visibilityAndUnreadFollowTheServerRule() throws {
        let now = Date()
        var message = CoachMessage(role: .coach, kind: "text", body: "Hi", localDay: Self.day, deliverAt: now.addingTimeInterval(-60))
        #expect(message.isVisible(at: now))
        #expect(message.isUnread(at: now))
        message.readAt = now
        #expect(!message.isUnread(at: now))
        message.status = .superseded
        #expect(!message.isVisible(at: now))
        let future = CoachMessage(role: .coach, kind: "text", body: "Later", localDay: Self.day, deliverAt: now.addingTimeInterval(600), status: .scheduled)
        #expect(!future.isVisible(at: now))
    }

    // MARK: Card payloads

    @Test func decodesSnackRecommendations() throws {
        let payload = #"""
        {"headline":"Grab a Chobani","verdict":"grab","push_body":"7-Eleven, 4 min.",
         "options":[{"store_ref":"p1","store_name":"7-Eleven","walk_minutes":4.0,
           "items":[{"name":"Chobani Complete","brand":"Chobani","serving":"10 oz","quantity":"2",
                     "calories_kcal":180,"protein_g":25,"carbs_g":14,"fat_g":3,"price_usd_est":3.79,
                     "source_url":"https://chobani.com","nutrition_source":"web"},
                    {"brand":"nameless"}],
           "combined":{"calories_kcal":360,"protein_g":50,"carbs_g":28,"fat_g":6},
           "remaining_after":{"calories_kcal":540,"protein_g":12,"carbs_g":100,"fat_g":30},
           "maps_query":"7-Eleven 2nd Ave"}],
         "sources":["https://chobani.com"]}
        """#
        let message = try decode(row(kind: "snack_rec", payload: payload))
        guard case .snackRec(let card) = message.payload else {
            Issue.record("expected snack card, got \(message.payload)")
            return
        }
        #expect(card.headline == "Grab a Chobani")
        #expect(card.verdict == .grab)
        #expect(card.options.count == 1)
        let option = try #require(card.options.first)
        #expect(option.walkMinutes == 4)
        #expect(option.items.count == 1, "an item without a name is skipped, not fatal")
        #expect(option.items.first?.quantity == 2)
        #expect(option.combined.proteinG == 50)
        #expect(option.remainingAfter.caloriesKcal == 540)
        #expect(option.mapsQuery == "7-Eleven 2nd Ave")
        #expect(card.sources == ["https://chobani.com"])
        #expect(message.pushBody == "7-Eleven, 4 min.")

        let noSnack = try decode(row(kind: "snack_rec", payload: #"{"headline":"You're done for today","verdict":"no_snack_needed","options":[]}"#))
        guard case .snackRec(let quiet) = noSnack.payload else {
            Issue.record("expected no-snack card")
            return
        }
        #expect(quiet.verdict == .noSnackNeeded)
    }

    @Test func decodesTrainingPlanCards() throws {
        let payload = #"""
        {"plan_id":"0b6a1d6e-0000-4000-8000-000000000001","status":"draft","name":"Upper/Lower 4x",
         "sessions_per_week":4,"summary":"Two upper, two lower.",
         "sessions":[{"id":"upper_a","name":"Upper A","est_minutes":60,"top_exercises":["Bench","Row"]},
                     {"id":"lower_a","name":"Lower A"}]}
        """#
        let message = try decode(row(kind: "training_plan", payload: payload))
        guard case .trainingPlan(let card) = message.payload else {
            Issue.record("expected training plan, got \(message.payload)")
            return
        }
        #expect(card.planId == UUID(uuidString: "0b6a1d6e-0000-4000-8000-000000000001"))
        #expect(card.status == .draft)
        #expect(!card.isActive)
        #expect(card.sessionsPerWeek == 4)
        #expect(card.sessions.map(\.id) == ["upper_a", "lower_a"])
        #expect(card.sessions.first?.topExercises == ["Bench", "Row"])
        #expect(card.sessions.last?.estMinutes == nil)

        let missingId = try decode(row(kind: "training_plan", payload: #"{"name":"No id"}"#))
        #expect(missingId.payload == .unknown(type: "training_plan"))
    }

    @Test func decodesGoalChangesFlatOrNested() throws {
        let flat = #"""
        {"change_id":"0b6a1d6e-0000-4000-8000-000000000002","status":"needs_confirmation",
         "before":{"calories_kcal":2450,"protein_g":150,"carbs_g":280,"fat_g":75,"goal_type":"maintain"},
         "after":{"calories_kcal":2850,"protein_g":170,"carbs_g":330,"fat_g":85,"goal_type":"gain",
                  "target_weight_kg":79.4,"goal_date":"2027-05-01"},
         "projected_goal_date":"2027-05-01","warnings":["Gain is clamped to 0.5%/wk"]}
        """#
        guard case .goalChange(let card) = try decode(row(kind: "goal_change", payload: flat)).payload else {
            Issue.record("expected goal change")
            return
        }
        #expect(card.needsConfirmation)
        #expect(card.before.caloriesKcal == 2450)
        #expect(card.after.goalType == "gain")
        #expect(card.after.targetWeightKg == 79.4)
        #expect(card.projectedGoalDate == "2027-05-01")
        #expect(card.warnings.count == 1)

        let nested = #"""
        {"change_id":"0b6a1d6e-0000-4000-8000-000000000003","status":"applied",
         "before":{"targets":{"calories_kcal":2450,"protein_g":150,"carbs_g":280,"fat_g":75},"goal":"maintain"},
         "after":{"targets":{"calories_kcal":2850,"protein_g":170,"carbs_g":330,"fat_g":85},
                  "goal":{"goal_type":"gain","target_weight_kg":79.4}}}
        """#
        guard case .goalChange(let nestedCard) = try decode(row(kind: "goal_change", payload: nested)).payload else {
            Issue.record("expected nested goal change")
            return
        }
        #expect(nestedCard.status == .applied)
        #expect(nestedCard.before.goalType == "maintain")
        #expect(nestedCard.after.caloriesKcal == 2850)
        #expect(nestedCard.after.targetWeightKg == 79.4)
        #expect(nestedCard.warnings.isEmpty)
    }

    @Test func decodesProfileUpdates() throws {
        let payload = #"""
        {"memory_version":4,"undo_version":3,
         "changes":[{"section":"schedule","op":"replace","summary":"Lifts at 6:15"},
                    {"section":"role_models","op":"add","summary":"Reg Park"}]}
        """#
        guard case .profileUpdate(let card) = try decode(row(kind: "profile_update", payload: payload)).payload else {
            Issue.record("expected profile update")
            return
        }
        #expect(card.memoryVersion == 4)
        #expect(card.undoVersion == 3)
        #expect(card.changes.map(\.op) == [.replace, .add])
        #expect(card.changes.last?.sectionTitle == "Role models")
        #expect(!card.isUndone)

        let missingVersion = try decode(row(kind: "profile_update", payload: #"{"changes":[]}"#))
        #expect(missingVersion.payload == .unknown(type: "profile_update"))
    }

    @Test func mealAndWorkoutAcksFallBackToRowColumns() throws {
        let entryId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        let activityId = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
        let mealFromPayload = try decode(row(kind: "meal_ack", payload: #"{"entry_id":"\#(entryId)"}"#))
        #expect(mealFromPayload.payload == .mealAck(entryId: UUID(uuidString: entryId)!))

        let mealFromColumn = try decode(
            row(kind: "meal_ack").replacingOccurrences(of: "\"entry_id\":null", with: "\"entry_id\":\"\(entryId)\"")
        )
        #expect(mealFromColumn.payload == .mealAck(entryId: UUID(uuidString: entryId)!))

        let mealWithoutId = try decode(row(kind: "meal_ack"))
        #expect(mealWithoutId.payload == .unknown(type: "meal_ack"))

        let workout = try decode(
            row(kind: "workout_ack", payload: #"{"prs":[{"exercise":"Bench press","kind":"e1rm","value":215,"unit":"lb","previous":205},{"kind":"weight"}]}"#)
                .replacingOccurrences(of: "\"activity_id\":null", with: "\"activity_id\":\"\(activityId)\"")
        )
        guard case .workoutAck(let card) = workout.payload else {
            Issue.record("expected workout ack")
            return
        }
        #expect(card.activityId == UUID(uuidString: activityId))
        #expect(card.prs.count == 1)
        #expect(card.prs.first?.kind == .e1rm)
        #expect(card.prs.first?.previous == 205)
    }

    @Test func decodesCheckInCardsForWeighInsAndPhotoFeedback() throws {
        let weighIn = try decode(row(kind: "weigh_in_ack", payload: #"{"weight_kg":"74.2"}"#))
        guard case .checkIn(let card) = weighIn.payload else {
            Issue.record("expected check-in")
            return
        }
        #expect(card.kind == .weighInAck)
        #expect(card.localDay == Self.day, "falls back to the row's local day")
        #expect(card.weightKg == 74.2)

        let photo = try decode(row(kind: "photo_feedback", payload: #"""
        {"local_day":"2026-10-05","photo_path":"u/2026-10-05/progress-x.jpg",
         "review":{"headline":"Shoulders filling out","observations":["Delts rounder"],"bulk_quality":"on_track"}}
        """#))
        guard case .checkIn(let feedback) = photo.payload else {
            Issue.record("expected photo feedback")
            return
        }
        #expect(feedback.kind == .photoFeedback)
        #expect(feedback.localDay == "2026-10-05")
        #expect(feedback.review?.observations == ["Delts rounder"])
        #expect(feedback.review?.bulkQuality == "on_track")
    }

    @Test func recapAndPlanCardsAreOptionalOnPlainSlots() throws {
        let dayRecap = try decode(row(kind: "recap", payload: #"{"kind":"day","kcal":2710,"protein_g":164,"kcal_target":2850,"protein_target_g":170,"headline":"Solid","score":86}"#))
        guard case .recap(let recap) = dayRecap.payload else {
            Issue.record("expected recap")
            return
        }
        #expect(recap.period == .day)
        #expect(recap.proteinTargetG == 170)
        #expect(recap.score == 86)

        let weekly = try decode(row(kind: "recap", payload: #"{"summary_id":"0b6a1d6e-0000-4000-8000-000000000009","week_start":"2026-09-28"}"#))
        guard case .recap(let week) = weekly.payload else {
            Issue.record("expected weekly recap pointer")
            return
        }
        #expect(week.period == .week)
        #expect(week.weekStart == "2026-09-28")

        #expect(try decode(row(kind: "recap", payload: #"{"push_body":"Night."}"#)).payload == .none)
        #expect(try decode(row(kind: "plan", payload: #"{"push_body":"Morning."}"#)).payload == .none)

        let plan = try decode(row(kind: "plan", payload: #"{"theme":"Protein early","remaining":{"calories_kcal":2850,"protein_g":170},"actions":["40 g by 10"]}"#))
        guard case .plan(let card) = plan.payload else {
            Issue.record("expected plan")
            return
        }
        #expect(card.theme == "Protein early")
        #expect(card.remaining?.proteinG == 170)
        #expect(card.remaining?.carbsG == 0)
        #expect(card.actions == ["40 g by 10"])
    }

    @Test func plainKindsHaveNoCardAndUnknownKindsSurvive() throws {
        #expect(try decode(row(kind: "text")).payload == .none)
        #expect(try decode(row(kind: "checkpoint", payload: #"{"push_body":"Lunch?"}"#)).payload == .none)
        #expect(try decode(row(kind: "photo", role: "user")).payload == .none)
        let future = try decode(row(kind: "grab_plan", payload: #"{"anything":1}"#))
        #expect(future.payload == .unknown(type: "grab_plan"))
        #expect(!future.payload.hasCard)
        #expect(future.body == "Body text")
        #expect(future.rawPayload["anything"]?.doubleValue == 1)
    }

    @Test func fixturesCoverEveryCardKind() {
        let messages = CoachFixtures.day(Self.day, now: Date())
        let payloads = messages.map(\.payload)
        #expect(payloads.contains { if case .plan = $0 { return true }; return false })
        #expect(payloads.contains { if case .mealAck = $0 { return true }; return false })
        #expect(payloads.contains { if case .goalChange = $0 { return true }; return false })
        #expect(payloads.contains { if case .profileUpdate = $0 { return true }; return false })
        #expect(payloads.contains { if case .snackRec = $0 { return true }; return false })
        #expect(payloads.contains { if case .trainingPlan = $0 { return true }; return false })
        #expect(payloads.contains { if case .workoutAck = $0 { return true }; return false })
        #expect(payloads.contains { if case .checkIn = $0 { return true }; return false })
        #expect(payloads.contains { if case .recap = $0 { return true }; return false })
        #expect(!payloads.contains { if case .unknown = $0 { return true }; return false })
    }

    // MARK: Requests

    @Test func sendRequestEncodesLowercaseIdsAndExplicitNulls() throws {
        let id = try #require(UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789"))
        let request = CoachSendRequest(
            clientRequestId: id,
            text: "Ate a burrito",
            inputMode: .dictated,
            speechEngine: "apple.speech_transcriber",
            localDay: Self.day,
            timezone: "America/New_York"
        )
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(object["client_request_id"] as? String == "abcdef01-2345-6789-abcd-ef0123456789")
        #expect(object["input_mode"] as? String == "dictated")
        #expect(object["speech_engine"] as? String == "apple.speech_transcriber")
        #expect(object["local_day"] as? String == Self.day)
        for key in ["attachment_path", "location", "context_hint"] {
            #expect(object.keys.contains(key), "\(key) must be present")
            #expect(object[key] is NSNull, "\(key) must be null")
        }

        let decoded = try JSONDecoder().decode(CoachSendRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded == request)
    }

    @Test func cardActionEncodesTheNestedActionShape() throws {
        let card = GoalChangeCard(
            changeId: UUID(uuidString: "0B6A1D6E-0000-4000-8000-000000000002")!,
            status: .needsConfirmation,
            before: GoalSnapshot(),
            after: GoalSnapshot()
        )
        let action = CoachCardAction.goalChange(card, decision: .apply)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(action)) as? [String: Any])
        let nested = try #require(object["action"] as? [String: Any])
        #expect(nested["kind"] as? String == "goal_change")
        #expect(nested["id"] as? String == "0b6a1d6e-0000-4000-8000-000000000002")
        #expect(nested["decision"] as? String == "apply")
        #expect((object["client_request_id"] as? String)?.lowercased() == object["client_request_id"] as? String)
        #expect(action.dedupeKey == "goal_change:0b6a1d6e-0000-4000-8000-000000000002:apply")
    }

    @Test func syncRequestMatchesTheEndpointShape() throws {
        let request = CoachSyncRequest(
            trigger: .mealComplete,
            localDay: Self.day,
            timezone: "America/New_York",
            entryId: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
            activityId: nil,
            device: .init(
                deviceId: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                appVersion: "2.0 (1)",
                osVersion: "26.5",
                notificationStatus: .notDetermined,
                locationStatus: .whenInUse
            ),
            location: nil,
            wait: true
        )
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(object["trigger"] as? String == "meal_complete")
        #expect(object["entry_id"] as? String == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(object["activity_id"] is NSNull)
        #expect(object["location"] is NSNull)
        #expect(object["wait"] as? Bool == true)
        let device = try #require(object["device"] as? [String: Any])
        #expect(device["notification_status"] as? String == "not_determined")
        #expect(device["location_status"] as? String == "when_in_use")

        let response = try JSONDecoder().decode(
            CoachSyncResponse.self,
            from: Data(#"{"plan_run_id":null,"generated":true,"server_time":"2026-10-06T14:05:00.5Z"}"#.utf8)
        )
        #expect(response.generated)
        #expect(response.planRunId == nil)
        #expect(response.serverTime != nil)
    }

    @Test func streamEventsDecodeEveryType() throws {
        func event(_ json: String) throws -> CoachStreamEvent {
            try JSONDecoder().decode(CoachStreamEvent.self, from: Data(json.utf8))
        }
        let messageId = "0b6a1d6e-0000-4000-8000-00000000000a"
        #expect(try event(#"{"type":"status","label":"Checking what’s near you…"}"#) == .status(label: "Checking what’s near you…"))
        #expect(try event(#"{"type":"delta","message_id":"\#(messageId)","text":"Hey"}"#) == .delta(messageId: UUID(uuidString: messageId)!, text: "Hey"))
        #expect(try event(#"{"type":"done","run_id":null,"message_ids":["\#(messageId)"]}"#) == .done(runId: nil, messageIds: [UUID(uuidString: messageId)!]))
        #expect(try event(#"{"type":"error","code":"quota","message":"Shudo is tapped out.","retryable":false}"#)
            == .error(CoachStreamFailure(code: "quota", message: "Shudo is tapped out.", retryable: false)))
        #expect(throws: (any Error).self) { try event(#"{"type":"mystery"}"#) }
        #expect(throws: (any Error).self) { try event(#"{"type":"delta","message_id":"nope"}"#) }
    }

    // MARK: Location

    @Test func locationContextNeverEncodesCoordinates() throws {
        let context = LocationContext(
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            quality: .precise,
            locality: .init(city: "New York", region: "NY", country: "US", timezone: "America/New_York"),
            stores: [
                NearbyStore(ref: "p0011223344", name: "7-Eleven", category: "convenience", distanceM: 250, walkMinutes: 4, walkMinutesSource: .mapkitETA, addressShort: "212 2nd Ave"),
                NearbyStore(ref: "p5566778899", name: "Duane Reade", category: "pharmacy", distanceM: 400, walkMinutes: 7, walkMinutesSource: .estimate),
            ]
        )
        let data = try JSONEncoder().encode(context)
        let json = try #require(String(data: data, encoding: .utf8))
        // The same rule the database enforces on device_snapshots.nearby.
        let coordinateKey = try Regex(#"(?i)"(lat|lng|lon|latitude|longitude|coordinates?|geohash)"\s*:"#)
        #expect(json.firstMatch(of: coordinateKey) == nil)

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["captured_at", "quality", "locality", "stores"])
        let locality = try #require(object["locality"] as? [String: Any])
        #expect(locality["neighborhood"] is NSNull)
        #expect(locality["timezone"] as? String == "America/New_York")
        let store = try #require((object["stores"] as? [[String: Any]])?.first)
        #expect(Set(store.keys) == ["ref", "name", "category", "distance_m", "walk_minutes", "walk_minutes_source", "address_short"])
        #expect(store["walk_minutes_source"] as? String == "mapkit_eta")

        let decoded = try JSONDecoder().decode(LocationContext.self, from: data)
        #expect(decoded == context)
    }

    // MARK: Settings, memory, days

    @Test func settingsMapToProfileColumns() throws {
        let row = #"""
        [{"coach_enabled":true,"coach_intensity":"drill_sergeant","coach_profanity":"salty",
          "quiet_hours_start":"22:30:00","quiet_hours_end":"06:45:00",
          "location_recs_enabled":true,"physique_ai_review_enabled":false}]
        """#
        let settings = try #require(try JSONDecoder().decode([CoachSettings].self, from: Data(row.utf8)).first)
        #expect(settings.enabled)
        #expect(settings.intensity == .drillSergeant)
        #expect(settings.profanity == .salty)
        #expect(settings.quietHoursStart == CoachClockTime(hour: 22, minute: 30))
        #expect(settings.quietHoursEnd.string == "06:45")
        #expect(settings.locationRecsEnabled)

        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(object["quiet_hours_start"] as? String == "22:30")
        #expect(object["coach_intensity"] as? String == "drill_sergeant")
        #expect(Set(object.keys) == Set(CoachSettings.profileColumns.split(separator: ",").map(String.init)))

        let defaults = try JSONDecoder().decode(CoachSettings.self, from: Data("{}".utf8))
        #expect(defaults == .defaults)
        #expect(defaults.quietHoursStart.string == "23:00")
    }

    @Test func quietHoursWrapPastMidnight() throws {
        let start = CoachClockTime(hour: 23, minute: 0)
        let end = CoachClockTime(hour: 7, minute: 0)
        #expect(CoachClockTime.isWithin(23 * 60, start: start, end: end))
        #expect(CoachClockTime.isWithin(3 * 60, start: start, end: end))
        #expect(!CoachClockTime.isWithin(7 * 60, start: start, end: end))
        #expect(!CoachClockTime.isWithin(12 * 60, start: start, end: end))
        let daytime = CoachClockTime(hour: 13, minute: 0)
        #expect(CoachClockTime.isWithin(13 * 60 + 30, start: daytime, end: CoachClockTime(hour: 14, minute: 0)))
        #expect(CoachClockTime(string: "25:00") == nil)
    }

    @Test func memoryDocumentOrdersBioSectionsAndReadsStructure() throws {
        let row = #"""
        [{"version":5,"document":"# Luke","updated_source":"bio_update","updated_at":"2026-10-06T12:00:00Z",
          "sections":{"bio":{"goals":"Lean bulk to 175.","about":"Engineer in NYC.","zz_custom":"Extra","sleep":"  "},
                      "notes":{"protein":"Misses protein on office days."},
                      "schedule":{"wake":"07:00","lift_days":["mon","wed"],"lift_time":"18:15"},
                      "equipment":["commercial gym"]}}]
        """#
        let memory = try #require(try JSONDecoder().decode([CoachMemoryDocument].self, from: Data(row.utf8)).first)
        #expect(memory.version == 5)
        #expect(memory.bio.map(\.key) == ["about", "goals", "zz_custom"])
        #expect(memory.section(.goals)?.markdown == "Lean bulk to 175.")
        #expect(memory.section(.about)?.title == "About")
        #expect(memory.notes["protein"] != nil)
        #expect(memory.schedule?.liftDays == ["mon", "wed"])
        #expect(memory.schedule?.officeDays == [])
        #expect(memory.equipment == ["commercial gym"])
        #expect(!memory.isEmpty)
        #expect(CoachMemoryDocument.empty.isEmpty)
    }

    @Test func localDaysAreRealCalendarDates() throws {
        #expect(CoachLocalDay.isValid("2026-10-06"))
        #expect(CoachLocalDay.isValid("2028-02-29"))
        #expect(!CoachLocalDay.isValid("2026-02-30"))
        #expect(!CoachLocalDay.isValid("2026-13-01"))
        #expect(!CoachLocalDay.isValid("2026-1-01"))
        #expect(!CoachLocalDay.isValid("tomorrow"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let instant = Date(timeIntervalSince1970: 1_791_302_400) // 2026-10-06T16:00:00Z
        #expect(CoachLocalDay.string(for: instant, timeZone: tokyo) == "2026-10-07")
        #expect(CoachLocalDay.string(for: instant, timeZone: TimeZone(identifier: "UTC")!) == "2026-10-06")
    }

    @Test func attachmentPathsAreLowercaseAndDated() throws {
        let path = try CoachService.attachmentPath(
            userId: "ABCDEF01-2345-6789-ABCD-EF0123456789",
            localDay: Self.day,
            fileId: UUID(uuidString: "0B6A1D6E-0000-4000-8000-000000000002")!
        )
        #expect(path == "abcdef01-2345-6789-abcd-ef0123456789/2026-10-06/chat-0b6a1d6e-0000-4000-8000-000000000002.jpg")
        #expect(throws: (any Error).self) {
            try CoachService.attachmentPath(userId: "not-a-uuid", localDay: Self.day)
        }
        #expect(CoachService.isJPEG(Data([0xFF, 0xD8, 0x00, 0xFF, 0xD9])))
        #expect(!CoachService.isJPEG(Data([0x89, 0x50, 0x4E, 0x47])))
    }

    @Test func restQueriesEscapePlusSigns() throws {
        let service = CoachService(jwtProvider: { "jwt" }, userIdProvider: { nil })
        let url = service.restURL("coach_messages", query: [URLQueryItem(name: "deliver_at", value: "lte.2026-10-06T10:00:00+02:00")])
        #expect(url.absoluteString.contains("%2B02:00"))
        #expect(!url.absoluteString.contains("+"))
    }
}
