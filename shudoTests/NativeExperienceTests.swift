import Foundation
import Testing
@testable import shudo

struct NativeExperienceTests {
    @Test func profilePhotoInputRejectsOversizedOrDecompressionHeavyImages() {
        #expect(ProfilePhotoInputPolicy.accepts(
            byteCount: 2_000_000,
            pixelWidth: 6_000,
            pixelHeight: 6_000
        ))
        #expect(!ProfilePhotoInputPolicy.accepts(
            byteCount: 25_000_001,
            pixelWidth: 512,
            pixelHeight: 512
        ))
        #expect(!ProfilePhotoInputPolicy.accepts(
            byteCount: 1_000_000,
            pixelWidth: 10_000,
            pixelHeight: 10_000
        ))
        #expect(!ProfilePhotoInputPolicy.accepts(
            byteCount: 1_000_000,
            pixelWidth: .infinity,
            pixelHeight: 512
        ))
    }

    @Test func weeklySummaryKeepsTwoToThreeUsefulItemsAndSupportsEmptyProviders() async throws {
        let start = Date(timeIntervalSince1970: 100)
        let summary = WeeklyInsightSummary(
            weekStart: start,
            weekEnd: start.addingTimeInterval(6 * 86_400),
            headline: "  Protein was steady  ",
            narrative: "  Breakfast carried most of the week.  ",
            repeatedFoods: [WeeklyRepeatedFood(name: "Eggs", count: 4)],
            patterns: [" Breakfast improved ", "", "Lunch was consistent", "Late meals increased"],
            suggestions: ["Prep breakfast", "Add vegetables", "Keep water nearby", "Ignored fourth"]
        )

        #expect(summary.headline == "Protein was steady")
        #expect(summary.narrative == "Breakfast carried most of the week.")
        #expect(summary.repeatedFoods == [WeeklyRepeatedFood(name: "Eggs", count: 4)])
        #expect(summary.patterns == ["Breakfast improved", "Lunch was consistent", "Late meals increased"])
        #expect(summary.suggestions == ["Prep breakfast", "Add vegetables", "Keep water nearby"])
        #expect(try await EmptyWeeklySummaryProvider().fetchLatestWeeklySummary() == nil)
    }

    @Test func dailyProgressShowsCurrentAgainstGoalWithoutOverflow() {
        #expect(NutritionProgressPolicy.progress(current: 1_100, goal: 2_200) == 0.5)
        #expect(NutritionProgressPolicy.progress(current: 2_500, goal: 2_200) == 1)
        #expect(NutritionProgressPolicy.progress(current: -10, goal: 2_200) == 0)
        #expect(NutritionProgressPolicy.progress(current: 100, goal: 0) == 0)
    }

    @Test func adherenceRewardsTotalsNearAllFourTargets() throws {
        let exact = DailyNutritionTotal(
            localDay: "2026-07-21",
            proteinG: 150,
            carbsG: 250,
            fatG: 70,
            caloriesKcal: 2_200,
            entryCount: 3
        )
        let distant = DailyNutritionTotal(
            localDay: "2026-07-20",
            proteinG: 50,
            carbsG: 80,
            fatG: 20,
            caloriesKcal: 700,
            entryCount: 1
        )

        #expect(NutritionProgressPolicy.adherence(total: exact, target: .defaultDaily) == 1)
        let distantScore = try #require(
            NutritionProgressPolicy.adherence(total: distant, target: .defaultDaily)
        )
        #expect(distantScore < 0.5)
    }

    @Test func heatmapBuildsTwelveBoundedWeeksIncludingMissingDays() throws {
        let ending = try #require(ISO8601DateFormatter().date(from: "2026-07-21T16:00:00Z"))
        let totals = [
            DailyNutritionTotal(
                localDay: "2026-07-21",
                proteinG: 150,
                carbsG: 250,
                fatG: 70,
                caloriesKcal: 2_200,
                entryCount: 2
            )
        ]
        let cells = NutritionProgressPolicy.heatmapCells(
            totals: totals,
            target: .defaultDaily,
            endingOn: ending,
            timezone: "UTC"
        )

        #expect(cells.count == 84)
        #expect(cells.last?.localDay == "2026-07-21")
        #expect(cells.last?.adherence == 1)
        #expect(cells.dropLast().allSatisfy { $0.adherence == nil })
    }

    @Test func heatmapUsesTargetEffectiveOnEachHistoricalDay() throws {
        let ending = try #require(ISO8601DateFormatter().date(from: "2026-07-21T16:00:00Z"))
        let original = MacroTarget(
            caloriesKcal: 2_000,
            proteinG: 100,
            carbsG: 200,
            fatG: 60
        )
        let revised = MacroTarget(
            caloriesKcal: 2_400,
            proteinG: 150,
            carbsG: 260,
            fatG: 75
        )
        let totals = [
            DailyNutritionTotal(
                localDay: "2026-07-19",
                proteinG: original.proteinG,
                carbsG: original.carbsG,
                fatG: original.fatG,
                caloriesKcal: original.caloriesKcal,
                entryCount: 2
            ),
            DailyNutritionTotal(
                localDay: "2026-07-21",
                proteinG: revised.proteinG,
                carbsG: revised.carbsG,
                fatG: revised.fatG,
                caloriesKcal: revised.caloriesKcal,
                entryCount: 3
            )
        ]
        let cells = NutritionProgressPolicy.heatmapCells(
            totals: totals,
            target: revised,
            targetHistory: [
                DailyMacroTargetSnapshot(targetDay: "2026-01-01", target: original),
                DailyMacroTargetSnapshot(targetDay: "2026-07-20", target: revised)
            ],
            endingOn: ending,
            timezone: "UTC",
            dayCount: 3
        )

        #expect(cells.first?.localDay == "2026-07-19")
        #expect(cells.first?.adherence == 1)
        #expect(cells.last?.localDay == "2026-07-21")
        #expect(cells.last?.adherence == 1)
        #expect(NutritionProgressPolicy.effectiveTarget(
            on: "2026-07-19",
            history: [
                DailyMacroTargetSnapshot(targetDay: "2026-01-01", target: original),
                DailyMacroTargetSnapshot(targetDay: "2026-07-20", target: revised)
            ],
            fallback: revised
        ) == original)
    }

    @Test func nutrientTrendsBuildTwelveWeeksAndKeepEmptyWeeksVisible() throws {
        let ending = try #require(ISO8601DateFormatter().date(from: "2026-07-21T16:00:00Z"))
        let totals = [
            DailyNutritionTotal(
                localDay: "2026-07-21",
                proteinG: 150,
                carbsG: 250,
                fatG: 70,
                caloriesKcal: 2_200,
                entryCount: 2
            )
        ]

        let weeks = NutritionProgressPolicy.nutrientTrendWeeks(
            totals: totals,
            target: .defaultDaily,
            endingOn: ending,
            timezone: "UTC"
        )

        #expect(weeks.count == 12)
        #expect(weeks.first?.startLocalDay == "2026-04-29")
        #expect(weeks.last?.endLocalDay == "2026-07-21")
        #expect(weeks.dropLast().allSatisfy { $0.loggedDayCount == 0 })
        #expect(weeks.last?.loggedDayCount == 1)
        #expect(weeks.last?.ratio(for: .calories) == 1)
        #expect(weeks.last?.ratio(for: .protein) == 1)
    }

    @Test func nutrientTrendsAverageLoggedDaysAgainstTheirHistoricalTargets() throws {
        let ending = try #require(ISO8601DateFormatter().date(from: "2026-07-21T16:00:00Z"))
        let original = MacroTarget(
            caloriesKcal: 2_000,
            proteinG: 100,
            carbsG: 200,
            fatG: 60
        )
        let revised = MacroTarget(
            caloriesKcal: 2_400,
            proteinG: 150,
            carbsG: 260,
            fatG: 75
        )
        let totals = [
            DailyNutritionTotal(
                localDay: "2026-07-19",
                proteinG: 100,
                carbsG: 200,
                fatG: 60,
                caloriesKcal: 2_000,
                entryCount: 3
            ),
            DailyNutritionTotal(
                localDay: "2026-07-21",
                proteinG: 75,
                carbsG: 130,
                fatG: 37.5,
                caloriesKcal: 1_200,
                entryCount: 2
            ),
            DailyNutritionTotal(
                localDay: "2026-07-20",
                proteinG: 9_999,
                carbsG: 9_999,
                fatG: 9_999,
                caloriesKcal: 9_999,
                entryCount: 0
            )
        ]

        let week = try #require(NutritionProgressPolicy.nutrientTrendWeeks(
            totals: totals,
            target: revised,
            targetHistory: [
                DailyMacroTargetSnapshot(targetDay: "2026-01-01", target: original),
                DailyMacroTargetSnapshot(targetDay: "2026-07-20", target: revised)
            ],
            endingOn: ending,
            timezone: "UTC",
            weekCount: 1
        ).first)

        #expect(week.loggedDayCount == 2)
        #expect(week.average?.caloriesKcal == 1_600)
        #expect(week.averageTarget?.caloriesKcal == 2_200)
        #expect(week.ratio(for: .calories) == 1_600.0 / 2_200.0)
        #expect(week.ratio(for: .protein) == 175.0 / 250.0)
    }

    @Test func correctionPolicyTrimsBoundsAndRejectsEmptyContext() {
        #expect(!EntryCorrectionPolicy.canSubmit("   \n"))
        #expect(EntryCorrectionPolicy.canSubmit("The rice was one cup"))
        #expect(EntryCorrectionPolicy.canSubmit(text: "", hasAudio: true))
        #expect(!EntryCorrectionPolicy.canSubmit(text: "", hasAudio: false))
        #expect(EntryCorrectionPolicy.audioIsWithinUploadLimit(1))
        #expect(!EntryCorrectionPolicy.audioIsWithinUploadLimit(0))
        #expect(!EntryCorrectionPolicy.audioIsWithinUploadLimit(
            EntryCorrectionPolicy.maximumAudioBytes + 1
        ))
        let oversized = "🍚" + String(repeating: "x", count: 4_100)
        let normalized = EntryCorrectionPolicy.normalized("  \(oversized)  ")
        #expect(normalized.count == EntryCorrectionPolicy.maximumCharacters)
        #expect(!EntryCorrectionPolicy.canSubmit(oversized))
    }

    @Test func longDetailCopyGetsAnExpandableTreatment() {
        #expect(!EntryDetailPresentation.offersExpansion(for: "A short note."))
        #expect(EntryDetailPresentation.offersExpansion(for: String(repeating: "detail ", count: 40)))
        #expect(EntryDetailPresentation.offersItemExpansion(
            name: String(repeating: "Very detailed ingredient ", count: 4),
            amount: "about one and a half restaurant portions"
        ))
    }

    @Test func detailViewportStaysBoundedAndMacroCardsStackBeforeOverflow() {
        #expect(EntryDetailLayoutPolicy.contentWidth(for: 393) == 353)
        #expect(EntryDetailLayoutPolicy.contentWidth(for: 320) == 280)
        #expect(EntryDetailLayoutPolicy.contentWidth(for: 20) == 0)
        #expect(!EntryDetailLayoutPolicy.stacksMacroCards(for: .large))
        #expect(!EntryDetailLayoutPolicy.stacksMacroCards(for: .xLarge))
        #expect(EntryDetailLayoutPolicy.stacksMacroCards(for: .xxLarge))
        #expect(EntryDetailLayoutPolicy.stacksMacroCards(for: .accessibility1))
    }

    @Test func daySwipeRequiresTheCorrectScreenEdgeDirectionAndDistance() {
        let width: CGFloat = 390

        #expect(DayEdgeSwipePolicy.dayDelta(
            startX: 8,
            translation: CGSize(width: 80, height: 12),
            predictedEndTranslation: CGSize(width: 96, height: 14),
            containerWidth: width
        ) == -1)
        #expect(DayEdgeSwipePolicy.dayDelta(
            startX: 382,
            translation: CGSize(width: -80, height: 9),
            predictedEndTranslation: CGSize(width: -94, height: 10),
            containerWidth: width
        ) == 1)

        #expect(DayEdgeSwipePolicy.dayDelta(
            startX: 60,
            translation: CGSize(width: 110, height: 4),
            predictedEndTranslation: CGSize(width: 150, height: 5),
            containerWidth: width
        ) == nil)
        #expect(DayEdgeSwipePolicy.dayDelta(
            startX: 8,
            translation: CGSize(width: -90, height: 4),
            predictedEndTranslation: CGSize(width: -140, height: 5),
            containerWidth: width
        ) == nil)
        #expect(DayEdgeSwipePolicy.dayDelta(
            startX: 382,
            translation: CGSize(width: 90, height: 4),
            predictedEndTranslation: CGSize(width: 140, height: 5),
            containerWidth: width
        ) == nil)
        #expect(DayEdgeSwipePolicy.dayDelta(
            startX: 8,
            translation: CGSize(width: 45, height: 48),
            predictedEndTranslation: CGSize(width: 160, height: 150),
            containerWidth: width
        ) == nil)
        #expect(DayEdgeSwipePolicy.dayDelta(
            startX: 8,
            translation: CGSize(width: 27, height: 1),
            predictedEndTranslation: CGSize(width: 180, height: 3),
            containerWidth: width
        ) == nil)
        #expect(DayEdgeSwipePolicy.dayDelta(
            startX: 8,
            translation: CGSize(width: 40, height: 2),
            predictedEndTranslation: CGSize(width: 150, height: 3),
            containerWidth: width
        ) == -1)
    }

    @Test func macroDraftRequiresSensibleValuesAndDetectsChanges() {
        var draft = MacroTargetDraft(target: .defaultDaily)
        #expect(draft.validatedTarget == .defaultDaily)
        #expect(!draft.differs(from: .defaultDaily))

        draft.protein = "175"
        #expect(draft.validatedTarget?.proteinG == 175)
        #expect(draft.differs(from: .defaultDaily))

        draft.calories = "100"
        #expect(draft.validatedTarget == nil)
    }

    @Test func profilePhotoPathsAreVersionedAndStrictlyUserScoped() throws {
        let userID = "00000000-0000-4000-8000-000000000001"
        let fileID = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
        let path = try SupabaseService.profilePhotoPath(userId: userID, fileId: fileID)

        #expect(path == "00000000-0000-4000-8000-000000000001/11111111-2222-4333-8444-555555555555.jpg")
        #expect(SupabaseService.profilePhotoPathBelongsToUser(path, userId: userID))
        #expect(!SupabaseService.profilePhotoPathBelongsToUser(
            path,
            userId: "00000000-0000-4000-8000-000000000002"
        ))
        #expect(!SupabaseService.profilePhotoPathBelongsToUser(
            "\(userID)/../private.jpg",
            userId: userID
        ))
        #expect(throws: SupabaseService.ServiceError.self) {
            try SupabaseService.profilePhotoPath(userId: "not-a-user", fileId: fileID)
        }

        #expect(SupabaseService.profilePhotoDataIsJPEG(Data([0xFF, 0xD8, 0x00, 0xFF, 0xD9])))
        #expect(!SupabaseService.profilePhotoDataIsJPEG(Data([0x89, 0x50, 0x4E, 0x47])))
        #expect(!SupabaseService.profilePhotoDataIsJPEG(Data([0xFF, 0xD8, 0x00, 0x00])))
    }

    @Test func reanalysisRequestUsesInjectableSessionAndBoundedContext() throws {
        let id = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let service = APIService(
            supabaseUrl: try #require(URL(string: "https://example.supabase.co")),
            supabaseAnonKey: "sb_publishable_example",
            sessionJWTProvider: { "session-token" }
        )
        let request = try service.makeReanalysisRequest(
            entryId: id,
            context: "  The rice was one cup, not two.  ",
            jwt: "session-token"
        )
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )

        #expect(request.url?.path == "/functions/v1/reanalyze_entry")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(object == [
            "entry_id": "11111111-2222-3333-4444-555555555555",
            "context": "The rice was one cup, not two."
        ])

        let result = try APIService.parseReanalysisResponse(
            statusCode: 202,
            data: try JSONSerialization.data(withJSONObject: ["status": "analyzing"]),
            fallbackEntryId: id
        )
        #expect(result == APIService.ReanalysisResult(entryId: id, status: .analyzing))
    }

    @Test func voiceCorrectionUsesAuthenticatedBoundedMultipartContract() throws {
        let entryID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let requestID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
        let service = APIService(
            supabaseUrl: try #require(URL(string: "https://example.supabase.co")),
            supabaseAnonKey: "sb_publishable_example",
            sessionJWTProvider: { "session-token" }
        )

        let request = try service.makeCorrectionRequest(
            entryId: entryID,
            text: "  The bowl also had steak.  ",
            audioData: Data([0x01, 0x02, 0x03]),
            clientRequestId: requestID,
            jwt: "session-token"
        )
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)

        #expect(request.url?.path == "/functions/v1/correct_entry")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 130)
        #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_example")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(body.contains("name=\"entry_id\"\r\n\r\n11111111-2222-3333-4444-555555555555"))
        #expect(body.contains("name=\"client_request_id\"\r\n\r\naaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
        #expect(body.contains("The bowl also had steak."))
        #expect(body.contains("name=\"audio\"; filename=\"correction.m4a\""))
        #expect(body.contains("Content-Type: audio/m4a"))
    }

    @Test func accountDeletionRequiresExactConfirmationAndBuildsAuthenticatedRequest() throws {
        #expect(AccountDeletionPolicy.isConfirmed("DELETE"))
        #expect(!AccountDeletionPolicy.isConfirmed("delete"))
        #expect(!AccountDeletionPolicy.isConfirmed(" DELETE "))

        let service = APIService(
            supabaseUrl: try #require(URL(string: "https://example.supabase.co")),
            supabaseAnonKey: "sb_publishable_example",
            sessionJWTProvider: { "unused-in-request-builder" }
        )
        let request = try service.makeDeleteAccountRequest(
            confirmation: "DELETE",
            jwt: "session-token"
        )
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )

        #expect(request.url?.path == "/functions/v1/delete_account")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(object == ["confirmation": "DELETE"])
        #expect(throws: APIService.APIError.self) {
            try service.makeDeleteAccountRequest(confirmation: "delete", jwt: "session-token")
        }
    }

    @Test func weeklySummaryParserUsesLatestSummaryShapeAndGracefullySupportsEmptyRows() throws {
        let data = try JSONSerialization.data(withJSONObject: [[
            "week_start": "2026-07-13",
            "week_end": "2026-07-19",
            "headline": "Protein consistency improved",
            "narrative": "Four logged days were close to the protein target.",
            "repeated_foods": [["name": "Eggs", "count": 4]],
            "patterns": ["Breakfast was steadier", "Dinner ran late", "Fiber increased", "Extra"],
            "suggestions": ["Prep breakfast", "Move dinner earlier"]
        ]])
        let parsed = try SupabaseService.parseWeeklySummary(data)

        #expect(parsed?.headline == "Protein consistency improved")
        #expect(parsed?.narrative == "Four logged days were close to the protein target.")
        #expect(parsed?.repeatedFoods == [WeeklyRepeatedFood(name: "Eggs", count: 4)])
        #expect(parsed?.patterns == ["Breakfast was steadier", "Dinner ran late", "Fiber increased"])
        #expect(parsed?.suggestions == ["Prep breakfast", "Move dinner earlier"])
        #expect(try SupabaseService.parseWeeklySummary(Data("[]".utf8)) == nil)
    }

    @Test func dailyTotalsParserAcceptsPostgRESTNumericStrings() throws {
        let data = try JSONSerialization.data(withJSONObject: [[
            "local_day": "2026-07-21",
            "protein_g": "150.0",
            "carbs_g": 250,
            "fat_g": 70.0,
            "calories_kcal": "2200.0",
            "entry_count": 3
        ]])
        let parsed = try SupabaseService.parseDailyNutritionTotals(data)
        #expect(parsed == [
            DailyNutritionTotal(
                localDay: "2026-07-21",
                proteinG: 150,
                carbsG: 250,
                fatG: 70,
                caloriesKcal: 2_200,
                entryCount: 3
            )
        ])
    }

    @Test func targetHistoryParserAcceptsPostgRESTNumbersAndOrdersSnapshots() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            [
                "target_day": "2026-07-20",
                "calories_kcal": "2400.0",
                "protein_g": 150,
                "carbs_g": "260.0",
                "fat_g": 75
            ],
            [
                "target_day": "2026-01-01",
                "calories_kcal": 2_000,
                "protein_g": "100.0",
                "carbs_g": 200,
                "fat_g": "60.0"
            ]
        ])

        let parsed = try SupabaseService.parseDailyMacroTargetHistory(data)
        #expect(parsed.map(\.targetDay) == ["2026-01-01", "2026-07-20"])
        #expect(parsed.last?.target.proteinG == 150)
    }
}
