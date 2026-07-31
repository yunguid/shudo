import Foundation
import Testing

@testable import shudo

struct NativeExperienceTests {
    @Test func profilePhotoInputRejectsOversizedOrDecompressionHeavyImages() {
        #expect(
            ProfilePhotoInputPolicy.accepts(
                byteCount: 2_000_000,
                pixelWidth: 6_000,
                pixelHeight: 6_000
            ))
        #expect(
            !ProfilePhotoInputPolicy.accepts(
                byteCount: 25_000_001,
                pixelWidth: 512,
                pixelHeight: 512
            ))
        #expect(
            !ProfilePhotoInputPolicy.accepts(
                byteCount: 1_000_000,
                pixelWidth: 10_000,
                pixelHeight: 10_000
            ))
        #expect(
            !ProfilePhotoInputPolicy.accepts(
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
        #expect(
            summary.patterns == ["Breakfast improved", "Lunch was consistent", "Late meals increased"])
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
            ),
        ]
        let cells = NutritionProgressPolicy.heatmapCells(
            totals: totals,
            target: revised,
            targetHistory: [
                DailyMacroTargetSnapshot(targetDay: "2026-01-01", target: original),
                DailyMacroTargetSnapshot(targetDay: "2026-07-20", target: revised),
            ],
            endingOn: ending,
            timezone: "UTC",
            dayCount: 3
        )

        #expect(cells.first?.localDay == "2026-07-19")
        #expect(cells.first?.adherence == 1)
        #expect(cells.last?.localDay == "2026-07-21")
        #expect(cells.last?.adherence == 1)
        #expect(
            NutritionProgressPolicy.effectiveTarget(
                on: "2026-07-19",
                history: [
                    DailyMacroTargetSnapshot(targetDay: "2026-01-01", target: original),
                    DailyMacroTargetSnapshot(targetDay: "2026-07-20", target: revised),
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
            ),
        ]

        let week = try #require(
            NutritionProgressPolicy.nutrientTrendWeeks(
                totals: totals,
                target: revised,
                targetHistory: [
                    DailyMacroTargetSnapshot(targetDay: "2026-01-01", target: original),
                    DailyMacroTargetSnapshot(targetDay: "2026-07-20", target: revised),
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
        #expect(EntryCorrectionPolicy.canSubmit(text: "", hasAudio: false, hasImage: true))
        #expect(!EntryCorrectionPolicy.canSubmit(
            text: "",
            hasAudio: false,
            hasImage: true,
            isPreparingImage: true
        ))
        #expect(!EntryCorrectionPolicy.usesPhotoForEstimate(text: "", hasAudio: false))
        #expect(EntryCorrectionPolicy.usesPhotoForEstimate(text: "Half the rice", hasAudio: false))
        #expect(EntryCorrectionPolicy.usesPhotoForEstimate(text: "", hasAudio: true))
        #expect(EntryCorrectionPolicy.removingPhoto(at: 1, from: ["first", "second"]) == ["first"])
        #expect(EntryCorrectionPolicy.removingPhoto(at: 4, from: ["first"]) == ["first"])
        #expect(EntryCorrectionPolicy.audioIsWithinUploadLimit(1))
        #expect(!EntryCorrectionPolicy.audioIsWithinUploadLimit(0))
        #expect(
            !EntryCorrectionPolicy.audioIsWithinUploadLimit(
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
        #expect(
            EntryDetailPresentation.offersItemExpansion(
                name: String(repeating: "Very detailed ingredient ", count: 4),
                amount: "about one and a half restaurant portions"
            ))
    }

    @Test func entryDetailPhotoGalleryPreservesPrimaryAndAppendedMetadata() throws {
        let primary = try #require(URL(string: "https://example.test/original.jpg"))
        let appended = try #require(URL(string: "https://example.test/memory.jpg"))
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let detail = SupabaseService.EntryDetail(
            createdAt: createdAt,
            imageURL: primary,
            additionalPhotos: [
                SupabaseService.EntryDetailPhoto(
                    id: UUID(),
                    url: appended,
                    purpose: "memory",
                    createdAt: createdAt.addingTimeInterval(60)
                )
            ],
            title: "Birthday dinner",
            rawText: nil,
            transcript: nil,
            proteinG: 40,
            carbsG: 80,
            fatG: 25,
            caloriesKcal: 705,
            items: [],
            analysisNotes: nil,
            confidence: 0.8
        )

        #expect(detail.imageURLs == [primary, appended])
        #expect(detail.additionalPhotos.first?.purpose == "memory")
        #expect(detail.additionalPhotos.first?.createdAt == createdAt.addingTimeInterval(60))
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

        #expect(
            DayEdgeSwipePolicy.dayDelta(
                startX: 8,
                translation: CGSize(width: 80, height: 12),
                predictedEndTranslation: CGSize(width: 96, height: 14),
                containerWidth: width
            ) == -1)
        #expect(
            DayEdgeSwipePolicy.dayDelta(
                startX: 382,
                translation: CGSize(width: -80, height: 9),
                predictedEndTranslation: CGSize(width: -94, height: 10),
                containerWidth: width
            ) == 1)

        #expect(
            DayEdgeSwipePolicy.dayDelta(
                startX: 60,
                translation: CGSize(width: 110, height: 4),
                predictedEndTranslation: CGSize(width: 150, height: 5),
                containerWidth: width
            ) == nil)
        #expect(
            DayEdgeSwipePolicy.dayDelta(
                startX: 8,
                translation: CGSize(width: -90, height: 4),
                predictedEndTranslation: CGSize(width: -140, height: 5),
                containerWidth: width
            ) == nil)
        #expect(
            DayEdgeSwipePolicy.dayDelta(
                startX: 382,
                translation: CGSize(width: 90, height: 4),
                predictedEndTranslation: CGSize(width: 140, height: 5),
                containerWidth: width
            ) == nil)
        #expect(
            DayEdgeSwipePolicy.dayDelta(
                startX: 8,
                translation: CGSize(width: 45, height: 48),
                predictedEndTranslation: CGSize(width: 160, height: 150),
                containerWidth: width
            ) == nil)
        #expect(
            DayEdgeSwipePolicy.dayDelta(
                startX: 8,
                translation: CGSize(width: 27, height: 1),
                predictedEndTranslation: CGSize(width: 180, height: 3),
                containerWidth: width
            ) == nil)
        #expect(
            DayEdgeSwipePolicy.dayDelta(
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
        #expect(
            !SupabaseService.profilePhotoPathBelongsToUser(
                path,
                userId: "00000000-0000-4000-8000-000000000002"
            ))
        #expect(
            !SupabaseService.profilePhotoPathBelongsToUser(
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

    @Test func weightCheckInConvertsUnitsAndUsesStrictPrivatePhotoPaths() throws {
        let userID = "00000000-0000-4000-8000-000000000001"
        let fileID = try #require(UUID(uuidString: "11111111-2222-4333-8444-555555555555"))
        let path = try SupabaseService.weightPhotoPath(
            userId: userID,
            localDay: "2026-07-30",
            fileId: fileID
        )
        #expect(
            path
                == "00000000-0000-4000-8000-000000000001/2026-07-30/progress-11111111-2222-4333-8444-555555555555.jpg"
        )
        #expect(SupabaseService.weightPhotoPathBelongsToUser(path, userId: userID))
        #expect(
            !SupabaseService.weightPhotoPathBelongsToUser(
                path,
                userId: "00000000-0000-4000-8000-000000000002"
            ))
        #expect(
            !SupabaseService.weightPhotoPathBelongsToUser(
                "\(userID)/2026-07-30/../private.jpg",
                userId: userID
            ))
        #expect(WeightCheckInPolicy.kilograms(from: 220.462, units: "imperial") == 100)
        #expect(WeightCheckInPolicy.kilograms(from: 100, units: "metric") == 100)
        #expect(WeightCheckInPolicy.kilograms(from: 2, units: "metric") == nil)
    }

    @Test func weightCheckInParserAcceptsPostgRESTNumbers() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            [
                "id": "11111111-2222-4333-8444-555555555555",
                "local_day": "2026-07-30",
                "weight_kg": "82.45",
                "progress_photo_path":
                    "00000000-0000-4000-8000-000000000001/2026-07-30/progress-11111111-2222-4333-8444-555555555555.jpg",
                "created_at": "2026-07-30T12:00:00.000Z",
                "updated_at": "2026-07-30T12:05:00.000Z",
            ]
        ])
        let parsed = try SupabaseService.parseWeightCheckIns(data)
        #expect(parsed.count == 1)
        #expect(parsed.first?.weightKG == 82.45)
        #expect(parsed.first?.hasPhoto == true)
    }

    @Test func weightUtteranceParsingFindsTheLastPlausibleSpokenNumber() {
        // Dictation renders numbers as digits; the latest plausible one wins
        // so self-corrections ("183 — no, 182.6") land on the correction.
        #expect(WeightUtterancePolicy.parsedWeight(transcript: "182.4", units: "imperial") == 182.4)
        #expect(
            WeightUtterancePolicy.parsedWeight(
                transcript: "I think 183 no wait 182.6",
                units: "imperial"
            ) == 182.6)
        // Low-confidence dictation artifacts: spaced decimals and commas.
        #expect(
            WeightUtterancePolicy.parsedWeight(transcript: "182 point 4", units: "imperial") == 182.4)
        #expect(WeightUtterancePolicy.parsedWeight(transcript: "82,6", units: "metric") == 82.6)
        // A trailing fragment ("182 4") is implausible as a weight on its own,
        // so the utterance still resolves to the full number before it.
        #expect(WeightUtterancePolicy.parsedWeight(transcript: "182 4", units: "imperial") == 182)
        // Nothing plausible: out-of-range values and word-only utterances.
        #expect(WeightUtterancePolicy.parsedWeight(transcript: "5", units: "imperial") == nil)
        #expect(WeightUtterancePolicy.parsedWeight(transcript: "1000", units: "metric") == nil)
        #expect(
            WeightUtterancePolicy.parsedWeight(transcript: "about the same as yesterday", units: "metric")
                == nil)
    }

    @Test func weeklySummariesRetryDropsOnlyTheMicronutrientColumnOnSchemaDrift() {
        // An app shipped ahead of the migration gets a 400 for the unknown
        // column; only that status retries with the base projection.
        #expect(SupabaseService.weeklySummariesShouldRetryWithBaseColumns(statusCode: 400))
        #expect(!SupabaseService.weeklySummariesShouldRetryWithBaseColumns(statusCode: 401))
        #expect(!SupabaseService.weeklySummariesShouldRetryWithBaseColumns(statusCode: 500))
        #expect(
            SupabaseService.weeklySummaryColumnsWithMicronutrients
                == SupabaseService.weeklySummaryColumns + ",micronutrient_report")
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
        #expect(
            object == [
                "entry_id": "11111111-2222-3333-4444-555555555555",
                "context": "The rice was one cup, not two.",
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
            imageJPEG: nil,
            usesImageForEstimate: false,
            clientRequestId: requestID,
            jwt: "session-token"
        )
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)

        #expect(request.url?.path == "/functions/v1/correct_entry")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 130)
        #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_example")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=")
                == true)
        #expect(body.contains("name=\"entry_id\"\r\n\r\n11111111-2222-3333-4444-555555555555"))
        #expect(body.contains("name=\"client_request_id\"\r\n\r\naaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"))
        #expect(body.contains("The bowl also had steak."))
        #expect(body.contains("name=\"audio\"; filename=\"correction.m4a\""))
        #expect(body.contains("Content-Type: audio/m4a"))
    }

    @Test func existingMealPhotoMultipartMakesMemoryIntentExplicit() throws {
        let entryID = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let requestID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
        let service = APIService(
            supabaseUrl: try #require(URL(string: "https://example.supabase.co")),
            supabaseAnonKey: "sb_publishable_example",
            sessionJWTProvider: { "session-token" }
        )

        let request = try service.makeCorrectionRequest(
            entryId: entryID,
            text: nil,
            audioData: nil,
            imageJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            usesImageForEstimate: false,
            clientRequestId: requestID,
            jwt: "session-token"
        )
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)

        #expect(body.contains("name=\"photo_intent\"\r\n\r\nmemory"))
        #expect(body.contains("name=\"image\"; filename=\"meal-update.jpg\""))
        #expect(body.contains("Content-Type: image/jpeg"))
        #expect(!body.contains("name=\"text\""))
        #expect(!body.contains("name=\"audio\""))
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
        let data = try JSONSerialization.data(withJSONObject: [
            [
                "week_start": "2026-07-13",
                "week_end": "2026-07-19",
                "headline": "Protein consistency improved",
                "narrative": "Four logged days were close to the protein target.",
                "repeated_foods": [["name": "Eggs", "count": 4]],
                "patterns": ["Breakfast was steadier", "Dinner ran late", "Fiber increased", "Extra"],
                "suggestions": ["Prep breakfast", "Move dinner earlier"],
                "micronutrient_report": [
                    "coverage": ["days_logged": 4, "meals_logged": 12],
                    "nutrients": [
                        [
                            "id": "vitamin_c",
                            "name": "Vitamin C",
                            "category": "vitamin",
                            "unit": "mg",
                            "estimated_daily_amount": 72.5,
                            "reference_daily_amount": 90,
                            "percent_reference": 81,
                            "status": "on_track",
                            "confidence": "medium",
                            "evidence": ["oranges", "broccoli"],
                        ]
                    ],
                    "highlights": ["Vitamin C looked steady."],
                    "suggestions": ["Add beans to one lunch."],
                    "caveat": "Estimates depend on logged foods and portions.",
                ],
            ]
        ])
        let parsed = try SupabaseService.parseWeeklySummary(data)

        #expect(parsed?.headline == "Protein consistency improved")
        #expect(parsed?.narrative == "Four logged days were close to the protein target.")
        #expect(parsed?.repeatedFoods == [WeeklyRepeatedFood(name: "Eggs", count: 4)])
        #expect(parsed?.patterns == ["Breakfast was steadier", "Dinner ran late", "Fiber increased"])
        #expect(parsed?.suggestions == ["Prep breakfast", "Move dinner earlier"])
        #expect(parsed?.micronutrientReport?.daysLogged == 4)
        #expect(parsed?.micronutrientReport?.nutrients.first?.percentReference == 81)
        #expect(try SupabaseService.parseWeeklySummary(Data("[]".utf8)) == nil)
    }

    @Test func dailyTotalsParserAcceptsPostgRESTNumericStrings() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            [
                "local_day": "2026-07-21",
                "protein_g": "150.0",
                "carbs_g": 250,
                "fat_g": 70.0,
                "calories_kcal": "2200.0",
                "entry_count": 3,
            ]
        ])
        let parsed = try SupabaseService.parseDailyNutritionTotals(data)
        #expect(
            parsed == [
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
                "fat_g": 75,
            ],
            [
                "target_day": "2026-01-01",
                "calories_kcal": 2_000,
                "protein_g": "100.0",
                "carbs_g": 200,
                "fat_g": "60.0",
            ],
        ])

        let parsed = try SupabaseService.parseDailyMacroTargetHistory(data)
        #expect(parsed.map(\.targetDay) == ["2026-01-01", "2026-07-20"])
        #expect(parsed.last?.target.proteinG == 150)
    }
}

// MARK: - Heatmap presentation policy

extension NativeExperienceTests {
    @Test func adherenceLevelsBucketScoresIntoFiveDistinctSteps() {
        #expect(NutritionProgressPolicy.adherenceLevel(nil) == 0)
        #expect(NutritionProgressPolicy.adherenceLevel(0.0) == 1)
        #expect(NutritionProgressPolicy.adherenceLevel(0.54) == 1)
        #expect(NutritionProgressPolicy.adherenceLevel(0.55) == 2)
        #expect(NutritionProgressPolicy.adherenceLevel(0.74) == 2)
        #expect(NutritionProgressPolicy.adherenceLevel(0.75) == 3)
        #expect(NutritionProgressPolicy.adherenceLevel(0.89) == 3)
        #expect(NutritionProgressPolicy.adherenceLevel(0.9) == 4)
        #expect(NutritionProgressPolicy.adherenceLevel(1.0) == 4)
    }

    @Test func weekdayRowsAlignToTheCalendarsFirstWeekday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        // 2026-07-20 is a Monday.
        let monday = try #require(
            ISO8601DateFormatter().date(from: "2026-07-20T12:00:00Z")
        )

        calendar.firstWeekday = 1  // Sunday-first: Monday sits on row 1.
        #expect(NutritionProgressPolicy.weekdayRow(for: monday, calendar: calendar) == 1)

        calendar.firstWeekday = 2  // Monday-first: Monday sits on row 0.
        #expect(NutritionProgressPolicy.weekdayRow(for: monday, calendar: calendar) == 0)
    }

    @Test func heatmapCellsCarryTheDaysTotalsAndEffectiveTargetForTheReadout() throws {
        let ending = try #require(ISO8601DateFormatter().date(from: "2026-07-21T16:00:00Z"))
        let total = DailyNutritionTotal(
            localDay: "2026-07-21",
            proteinG: 150,
            carbsG: 250,
            fatG: 70,
            caloriesKcal: 2_200,
            entryCount: 2
        )
        let cells = NutritionProgressPolicy.heatmapCells(
            totals: [total],
            target: .defaultDaily,
            endingOn: ending,
            timezone: "UTC",
            dayCount: 2
        )

        #expect(cells.last?.total == total)
        #expect(cells.last?.effectiveTarget == .defaultDaily)
        #expect(cells.first?.total == nil)
    }
}

// MARK: - Weekly insight history

extension NativeExperienceTests {
    @Test func weeklyBreakdownAveragesTheSummaryPeriodOverLoggedDaysOnly() throws {
        let formatter = ISO8601DateFormatter()
        let summary = WeeklyInsightSummary(
            weekStart: try #require(formatter.date(from: "2026-07-13T00:00:00Z")),
            weekEnd: try #require(formatter.date(from: "2026-07-19T00:00:00Z")),
            headline: "Week",
            patterns: [],
            suggestions: []
        )
        let totals = [
            DailyNutritionTotal(
                localDay: "2026-07-13",
                proteinG: 150,
                carbsG: 250,
                fatG: 70,
                caloriesKcal: 2_000,
                entryCount: 2
            ),
            DailyNutritionTotal(
                localDay: "2026-07-18",
                proteinG: 170,
                carbsG: 270,
                fatG: 80,
                caloriesKcal: 2_400,
                entryCount: 3
            ),
            // Outside the summary period; must not count.
            DailyNutritionTotal(
                localDay: "2026-07-20",
                proteinG: 999,
                carbsG: 999,
                fatG: 999,
                caloriesKcal: 9_999,
                entryCount: 1
            ),
        ]

        let week = try #require(
            NutritionProgressPolicy.weeklyBreakdown(
                for: summary,
                totals: totals,
                fallbackTarget: .defaultDaily,
                targetHistory: []
            ))

        #expect(week.loggedDayCount == 2)
        #expect(week.average?.caloriesKcal == 2_200)
        #expect(week.average?.proteinG == 160)
        #expect(week.averageTarget?.caloriesKcal == MacroTarget.defaultDaily.caloriesKcal)
    }

    @Test func latestWeeklySummaryIsTheFirstOfTheStoredList() async throws {
        let formatter = ISO8601DateFormatter()
        let newest = WeeklyInsightSummary(
            weekStart: try #require(formatter.date(from: "2026-07-13T00:00:00Z")),
            weekEnd: try #require(formatter.date(from: "2026-07-19T00:00:00Z")),
            headline: "Newest",
            patterns: [],
            suggestions: []
        )
        let older = WeeklyInsightSummary(
            weekStart: try #require(formatter.date(from: "2026-07-06T00:00:00Z")),
            weekEnd: try #require(formatter.date(from: "2026-07-12T00:00:00Z")),
            headline: "Older",
            patterns: [],
            suggestions: []
        )
        let provider = StaticWeeklySummaryProvider(summaries: [newest, older])

        let latest = try await provider.fetchLatestWeeklySummary()
        #expect(latest == newest)

        let all = try await provider.fetchWeeklySummaries(limit: 12)
        #expect(all.count == 2)
    }
}
