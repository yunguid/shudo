import AVFoundation
import Foundation
import os
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

    @MainActor
    @Test func recorderControlStateMakesEveryTapOutcomeObservable() {
        #expect(AudioRecorder.controlState(
            isStarting: false,
            isRecording: false,
            hasRecording: false,
            hasError: false
        ) == .idle)
        #expect(AudioRecorder.controlState(
            isStarting: true,
            isRecording: false,
            hasRecording: false,
            hasError: false
        ) == .starting)
        #expect(AudioRecorder.controlState(
            isStarting: false,
            isRecording: true,
            hasRecording: true,
            hasError: false
        ) == .recording)
        #expect(AudioRecorder.controlState(
            isStarting: false,
            isRecording: false,
            hasRecording: true,
            hasError: false
        ) == .ready)
        #expect(AudioRecorder.controlState(
            isStarting: false,
            isRecording: false,
            hasRecording: false,
            hasError: true
        ) == .error)
    }

    @Test func buildIdentityIsStableAndRejectsUnexpandedRevisions() throws {
        let identity = BuildIdentity(infoDictionary: [
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "2",
            BuildIdentity.revisionInfoKey: "1234567890abcdef"
        ])
        #expect(identity.revision == "1234567890ab")
        #expect(identity.displayText == "Shudo 1.0 (2) · 1234567890ab")
        #expect(BuildIdentity.normalizedRevision("$(SHUDO_BUILD_REVISION)") == "local")
        #expect(BuildIdentity.normalizedRevision("  ") == "local")
    }

    @Test func captureDiagnosticsPersistOnlyStaticStateAndBuildIdentity() throws {
        CaptureDiagnostics.beginSession()
        CaptureDiagnostics.record(.photoPickerDismissed, state: "idle")
        CaptureDiagnostics.record(.microphoneTapAcceptedStart, state: "idle")
        CaptureDiagnostics.flush()

        let fileURL = try #require(CaptureDiagnostics.fileURL)
        let trace = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(trace.contains("|app.launched|idle"))
        #expect(trace.contains("|photo_picker.dismissed|idle"))
        #expect(trace.contains("|mic.control.accepted_start|idle"))
        #expect(!trace.contains("meal"))
        #expect(!trace.contains("photo.jpg"))
    }

    private static func makeIdleRecorder() throws -> (AVAudioRecorder, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-test-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1
        ])
        return (recorder, url)
    }

    /// The post-camera handoff makes the first activation attempts fail
    /// transiently; the start must ride through them instead of reading as
    /// a dead microphone.
    @Test func microphoneStartRetriesTransientFailuresUntilOneSucceeds() async throws {
        struct TransientFailure: Error {}
        let attempts = OSAllocatedUnfairLock(initialState: 0)

        let (recorder, url) = try Self.makeIdleRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        let started = try await AudioRecorder.startRecorderRetryingWithinDeadline(
            deadline: 5,
            retryDelay: 0.02
        ) {
            let attempt = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            guard attempt >= 3 else { throw TransientFailure() }
            return recorder
        }

        #expect(started === recorder)
        #expect(attempts.withLock { $0 } == 3)
    }

    @Test func microphoneStartSurfacesTheRealErrorAfterBoundedRetries() async {
        struct PersistentFailure: Error {}
        let attempts = OSAllocatedUnfairLock(initialState: 0)

        do {
            _ = try await AudioRecorder.startRecorderRetryingWithinDeadline(
                deadline: 5,
                retryDelay: 0.01,
                maximumAttempts: 4
            ) {
                attempts.withLock { $0 += 1 }
                throw PersistentFailure()
            }
            Issue.record("Expected the start to fail")
        } catch {
            #expect(error is PersistentFailure)
        }
        #expect(attempts.withLock { $0 } == 4)
    }

    @Test func microphoneStartDeadlineStillFiresWhenAnAttemptWedges() async {
        struct WedgedFailure: Error {}
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await AudioRecorder.startRecorderRetryingWithinDeadline(
                deadline: 0.3,
                retryDelay: 0.01
            ) {
                Thread.sleep(forTimeInterval: 1.2)
                throw WedgedFailure()
            }
            Issue.record("Expected the deadline to fire")
        } catch {
            // The deadline's own error, not the wedged attempt's.
            #expect(!(error is WedgedFailure))
            #expect(clock.now - started < .seconds(1))
        }
    }

    @MainActor
    @Test func abortingAWarmUpClearsTheStartingStateWithoutTouchingANote() {
        let audio = AudioRecorder()
        audio.abortStartingRecording()
        #expect(!audio.isStartingRecording)
        #expect(!audio.isRecording)
        #expect(audio.recordedFileURL == nil)
    }

    @MainActor
    @Test func audioRouteChangesDoNotDisableAnIdleRecorder() {
        let audio = AudioRecorder()
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue
            ]
        )
        #expect(audio.controlState == .idle)
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

        let body = service.makeMultipart(
            boundary: "test-boundary",
            text: "  salmon and rice  ",
            audioData: Data([0x01, 0x02]),
            imageJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]),
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
        #expect(value.contains("name=\"image\"; filename=\"photo.jpg\""))
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
        #expect(ImageProcessor.uploadJPEGData(from: [original])?.isEmpty == false)
    }

    @Test func uploadEncodingProducesOneBoundedJPEGForOneOrSeveralPhotos() throws {
        func photo(_ color: UIColor, width: CGFloat, height: CGFloat) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
        }

        #expect(ImageProcessor.uploadJPEGData(from: []) == nil)

        let single = try #require(
            ImageProcessor.uploadJPEGData(from: [photo(.systemRed, width: 2_400, height: 1_200)])
        )
        let singleImage = try #require(UIImage(data: single))
        #expect(singleImage.cgImage?.width == 1_600)
        #expect(singleImage.cgImage?.height == 800)

        let collage = try #require(ImageProcessor.uploadJPEGData(from: [
            photo(.systemRed, width: 600, height: 400),
            photo(.systemGreen, width: 400, height: 600),
            photo(.systemBlue, width: 600, height: 600)
        ]))
        let collageImage = try #require(UIImage(data: collage))
        #expect(collageImage.cgImage?.width == 1_600)
        #expect(collageImage.cgImage?.height == 1_600)
    }

    @Test func orientedCameraPhotosAreNormalizedWithoutChangingTheirDisplayedAspect() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 600))
        let source = renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 600))
        }
        let cgImage = try #require(source.cgImage)
        let portrait = UIImage(cgImage: cgImage, scale: 1, orientation: .right)

        let normalized = ImageProcessor.normalizedForUpload(portrait)
        let resized = ImageProcessor.resizedForUpload(portrait)

        #expect(normalized.imageOrientation == .up)
        #expect(normalized.cgImage?.width == cgImage.height)
        #expect(normalized.cgImage?.height == cgImage.width)
        #expect(resized.cgImage?.width == 800)
        #expect(resized.cgImage?.height == 1_600)
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
        #expect(twoPhotoCollage.size.width / twoPhotoCollage.size.height == 2)

        let collage = try #require(ImageProcessor.collageForUpload([
            image(.red), image(.green), image(.blue), image(.yellow), image(.purple)
        ]))
        #expect(ImageProcessor.maximumPhotoCount == 4)
        #expect(collage.cgImage?.width == 1_600)
        #expect(collage.cgImage?.height == 1_600)
        #expect(ImageProcessor.uploadJPEGData(from: [collage])?.isEmpty == false)
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
            hasScannedFood: false,
            note: "salmon and rice"
        ))
        #expect(!EntryComposerPolicy.canSubmit(
            isSubmitting: false,
            isPreparingImage: true,
            hasAudio: true,
            hasImage: false,
            hasScannedFood: false,
            note: "salmon and rice"
        ))
        // A scanned label alone is a submittable capture.
        #expect(EntryComposerPolicy.canSubmit(
            isSubmitting: false,
            isPreparingImage: false,
            hasAudio: false,
            hasImage: false,
            hasScannedFood: true,
            note: ""
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
            hasScannedFood: false,
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
