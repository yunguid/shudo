import Foundation
import Testing
import UIKit
@testable import shudo

struct CapturePipelineTests {
    @MainActor
    @Test func voiceCaptureHasAFifteenMinuteLimitAndClampedCountdown() {
        #expect(AudioRecorder.maximumDuration == 15 * 60)
        #expect(AudioRecorder.remainingTime(after: -1) == 15 * 60)
        #expect(AudioRecorder.remainingTime(after: 60) == 14 * 60)
        #expect(AudioRecorder.remainingTime(after: 15 * 60) == 0)
        #expect(AudioRecorder.remainingTime(after: 16 * 60) == 0)
    }

    @Test func resumeRequestUsesStableEntryIdAndSessionJWT() throws {
        let entryId = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let service = APIService(
            supabaseUrl: URL(string: "https://example.supabase.co")!,
            supabaseAnonKey: "sb_publishable_example",
            sessionJWTProvider: { "session-token" }
        )

        let request = try service.makeResumeRequest(entryId: entryId, jwt: "session-token")
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )

        #expect(request.url?.path == "/functions/v1/resume_entry")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_example")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(object == ["entry_id": "11111111-2222-3333-4444-555555555555"])
    }

    @Test func resumeResponseAcceptsAsyncSuccessAndSurfacesConflicts() throws {
        let acceptedBody = try JSONSerialization.data(withJSONObject: ["status": "analyzing"])
        let conflictBody = try JSONSerialization.data(withJSONObject: [
            "error": "Processing attempts exhausted"
        ])

        #expect(
            try APIService.parseResumeResponse(statusCode: 202, data: acceptedBody)
                == .accepted(status: .analyzing)
        )
        #expect(
            try APIService.parseResumeResponse(
                statusCode: 200,
                data: try JSONSerialization.data(withJSONObject: ["status": "complete"])
            ) == .accepted(status: .complete)
        )
        #expect(
            try APIService.parseResumeResponse(statusCode: 409, data: conflictBody)
                == .conflict(message: "Processing attempts exhausted")
        )
        let incompleteMediaBody = try JSONSerialization.data(withJSONObject: [
            "error": "This meal's photo never finished uploading. Delete it and log it again."
        ])
        #expect(
            try APIService.parseResumeResponse(statusCode: 409, data: incompleteMediaBody)
                == .conflict(
                    message: "This meal's photo never finished uploading. Delete it and log it again."
                )
        )
    }

    @Test func multipartCarriesStableRequestAndSelectedDay() throws {
        let requestId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let service = APIService(
            supabaseUrl: URL(string: "https://example.supabase.co")!,
            supabaseAnonKey: "anon",
            sessionJWTProvider: { "token" }
        )

        let body = try service.makeMultipart(
            boundary: "test-boundary",
            text: "  salmon and rice  ",
            audioData: Data([0x01, 0x02]),
            image: nil,
            timezone: "America/New_York",
            localDay: "2026-07-19",
            clientRequestId: requestId
        )
        let value = String(decoding: body, as: UTF8.self)

        #expect(value.contains("name=\"timezone\"\r\n\r\nAmerica/New_York"))
        #expect(value.contains("name=\"local_day\"\r\n\r\n2026-07-19"))
        #expect(value.contains("name=\"client_request_id\"\r\n\r\naaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        #expect(value.contains("salmon and rice"))
        #expect(value.contains("name=\"audio\"; filename=\"voice.m4a\""))
    }

    @Test func imageUploadIsBoundedTo1600Pixels() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2_400, height: 1_200))
        let original = renderer.image { context in
            UIColor.systemOrange.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2_400, height: 1_200))
        }

        let resized = ImageProcessor.resizedForUpload(original)
        let width = resized.cgImage?.width ?? 0
        let height = resized.cgImage?.height ?? 0

        #expect(max(width, height) <= 1_600)
        #expect(width == 1_600)
        #expect(height == 800)
        #expect(ImageProcessor.jpegData(from: original)?.isEmpty == false)
    }

    @Test func multiplePhotosBecomeOneBoundedUploadCollage() throws {
        func image(_ color: UIColor) -> UIImage {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400))
            return renderer.image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            }
        }

        let twoPhotoCollage = try #require(ImageProcessor.collageForUpload([
            image(.red), image(.green)
        ]))
        #expect(twoPhotoCollage.cgImage?.width == 1_600)
        #expect(twoPhotoCollage.cgImage?.height == 800)

        let collage = try #require(ImageProcessor.collageForUpload([
            image(.red), image(.green), image(.blue), image(.yellow), image(.purple)
        ]))
        #expect(ImageProcessor.maximumPhotoCount == 4)
        #expect(collage.cgImage?.width == 1_600)
        #expect(collage.cgImage?.height == 1_600)
        #expect(ImageProcessor.jpegData(from: collage)?.isEmpty == false)
    }

    @Test func localDayUsesProfileTimezoneAtUTCBoundary() {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: "2026-07-20T02:30:00Z")!
        let day = SupabaseService().localDayString(for: date, timezone: "America/New_York")
        #expect(day == "2026-07-19")
    }

    @Test func boundedConcurrentMapCapsFanoutAndPreservesInputOrder() async {
        let probe = BoundedConcurrencyProbe()
        let inputs = Array(0..<12)
        let output = await SupabaseService.boundedConcurrentMap(
            inputs,
            maximumConcurrentTasks: 3
        ) { value in
            await probe.begin()
            try? await Task.sleep(
                nanoseconds: UInt64(4 - value % 4) * 2_000_000
            )
            await probe.finish()
            return value * 10
        }
        let peak = await probe.peakConcurrency

        #expect(output == inputs.map { $0 * 10 })
        #expect(peak == 3)
        #expect(peak <= SupabaseService.signedImageConcurrencyLimit)
    }

    @Test func boundedConcurrentMapPreservesOptionalResultsAndClampsZeroLimit() async {
        let output: [Int?] = await SupabaseService.boundedConcurrentMap(
            [3, 1, 2],
            maximumConcurrentTasks: 0
        ) { value in
            value == 1 ? nil : value
        }

        #expect(output.count == 3)
        #expect(output[0] == 3)
        #expect(output[1] == nil)
        #expect(output[2] == 2)
    }

    @MainActor
    @Test func totalsIgnoreMealsThatAreStillProcessingOrFailed() {
        let complete = Entry(
            id: UUID(), createdAt: Date(), summary: "Ready", imageURL: nil,
            proteinG: 30, carbsG: 40, fatG: 10, caloriesKcal: 370,
            status: .complete
        )
        let processing = Entry(
            id: UUID(), createdAt: Date(), summary: "Working", imageURL: nil,
            proteinG: 99, carbsG: 99, fatG: 99, caloriesKcal: 999,
            status: .analyzing
        )
        let failed = Entry(
            id: UUID(), createdAt: Date(), summary: "Failed", imageURL: nil,
            proteinG: 99, carbsG: 99, fatG: 99, caloriesKcal: 999,
            status: .failed
        )

        let totals = TodayViewModel.totals(for: [complete, processing, failed])
        #expect(totals.proteinG == 30)
        #expect(totals.caloriesKcal == 370)
    }

    @Test func photoPreparationCannotRaceMealSubmission() {
        #expect(EntryComposerPolicy.canSubmit(
            isSubmitting: false,
            isPreparingImage: false,
            hasAudio: false,
            hasImage: false,
            note: "salmon and rice"
        ))
        #expect(!EntryComposerPolicy.canSubmit(
            isSubmitting: false,
            isPreparingImage: true,
            hasAudio: true,
            hasImage: false,
            note: "salmon and rice"
        ))
    }

    @Test func mealNoteIsBoundedToTheServerContractWithoutSplittingUnicode() {
        let exact = String(repeating: "a", count: EntryComposerPolicy.maximumNoteLength)
        #expect(EntryComposerPolicy.boundedNote(exact) == exact)

        let overLimit = String(repeating: "a", count: EntryComposerPolicy.maximumNoteLength - 1)
            + "🍕"
        let bounded = EntryComposerPolicy.boundedNote(overLimit)
        #expect(bounded.utf16.count <= EntryComposerPolicy.maximumNoteLength)
        #expect(!bounded.contains("�"))

        #expect(!EntryComposerPolicy.canSubmit(
            isSubmitting: false,
            isPreparingImage: false,
            hasAudio: false,
            hasImage: false,
            note: String(repeating: "b", count: EntryComposerPolicy.maximumNoteLength + 1)
        ))
    }

    @MainActor
    @Test func mealSubmissionSurfacesActionableServerErrors() {
        #expect(TodayViewModel.submissionErrorMessage(
            APIService.APIError.server(statusCode: 413, message: "Voice note is too large")
        ) == "Voice note is too large")
        #expect(TodayViewModel.submissionErrorMessage(
            URLError(.notConnectedToInternet)
        ) == "Couldn’t reach the server. Check your connection and try again.")
    }

    @Test func systemMediaPickerDoesNotDiscardFinishedVoiceNote() {
        #expect(!EntryComposerPolicy.shouldDiscardRecording(
            isSubmitting: false,
            isShowingCamera: true,
            isShowingPhotoPicker: false
        ))
        #expect(!EntryComposerPolicy.shouldDiscardRecording(
            isSubmitting: false,
            isShowingCamera: false,
            isShowingPhotoPicker: true
        ))
        #expect(EntryComposerPolicy.shouldDiscardRecording(
            isSubmitting: false,
            isShowingCamera: false,
            isShowingPhotoPicker: false
        ))
    }

    @MainActor
    @Test func sameDayRefreshFailureKeepsVisibleMealsButFailedDayChangeDoesNot() {
        let meal = Entry(
            id: UUID(), createdAt: Date(), summary: "Dinner", imageURL: nil,
            proteinG: 32, carbsG: 48, fatG: 14, caloriesKcal: 446,
            localDay: "2026-07-20", status: .complete
        )
        let totals = TodayViewModel.totals(for: [meal])

        let refresh = TodayViewModel.visibleStateAfterLoadFailure(
            previousEntries: [meal],
            previousTotals: totals,
            visibleLocalDay: "2026-07-20",
            requestedLocalDay: "2026-07-20"
        )
        #expect(refresh.entries == [meal])
        #expect(refresh.totals == totals)

        let dayChange = TodayViewModel.visibleStateAfterLoadFailure(
            previousEntries: [meal],
            previousTotals: totals,
            visibleLocalDay: "2026-07-20",
            requestedLocalDay: "2026-07-19"
        )
        #expect(dayChange.entries.isEmpty)
        #expect(dayChange.totals == .empty)
    }

    @Test func defaultDailyTargetsMatchTheDatabaseContract() {
        #expect(MacroTarget.defaultDaily == MacroTarget(
            caloriesKcal: 2_200,
            proteinG: 150,
            carbsG: 250,
            fatG: 70
        ))
        #expect(ProfileCache.fallback(userId: "test-user").dailyMacroTarget == .defaultDaily)
    }

    @Test func onlyCompleteAndFailedEntriesCanBeDeleted() {
        func entry(status: EntryStatus) -> Entry {
            Entry(
                id: UUID(),
                createdAt: Date(),
                summary: "Meal",
                imageURL: nil,
                proteinG: 0,
                carbsG: 0,
                fatG: 0,
                caloriesKcal: 0,
                status: status
            )
        }

        #expect(!entry(status: .queued).canDelete)
        #expect(!entry(status: .transcribing).canDelete)
        #expect(!entry(status: .analyzing).canDelete)
        #expect(entry(status: .complete).canDelete)
        #expect(entry(status: .failed).canDelete)
        #expect(!entry(status: .deleting).canDelete)
    }

    @MainActor
    @Test func captureURLCreatesConsumableQuickVoiceRequest() {
        let router = AppRouter.shared
        router.handle(url: URL(string: "shudo://capture")!)
        let request = router.captureRequest

        #expect(request?.autoStartRecording == true)
        if let request { router.consume(request) }
        #expect(router.captureRequest == nil)
    }
}

private actor BoundedConcurrencyProbe {
    private var active = 0
    private(set) var peakConcurrency = 0

    func begin() {
        active += 1
        peakConcurrency = max(peakConcurrency, active)
    }

    func finish() {
        active -= 1
    }
}
