//
//  EntryCorrectionFlowTests.swift
//  shudoTests
//
//  Regression coverage for the estimate-update flow: a correction is
//  accepted locally, the timeline card shows a truthful updating state while
//  the request runs, success replaces the meal in place, and failure rolls
//  back with the correction preserved for retry.
//

import Foundation
import Testing
@testable import shudo

@MainActor
private final class CorrectionServiceFake: EntryReanalysisServing {
    struct RecordedCorrection: Equatable {
        let entryId: UUID
        let text: String?
        let audioByteCount: Int?
        let imageByteCount: Int?
        let usesImageForEstimate: Bool
        let clientRequestId: UUID
    }

    enum Step {
        case succeed
        case fail(any Error)
        case block
    }

    private(set) var corrections: [RecordedCorrection] = []
    var script: [Step] = []
    private var blockedContinuations:
        [CheckedContinuation<APIService.ReanalysisResult, any Error>] = []
    private var pendingReleases: [Result<APIService.ReanalysisResult, any Error>] = []

    func reanalyzeEntry(id: UUID, context: String) async throws -> APIService.ReanalysisResult {
        APIService.ReanalysisResult(entryId: id, status: .complete)
    }

    func correctEntry(
        id: UUID,
        text: String?,
        audioData: Data?,
        imageJPEG: Data?,
        usesImageForEstimate: Bool,
        clientRequestId: UUID
    ) async throws -> APIService.ReanalysisResult {
        corrections.append(RecordedCorrection(
            entryId: id,
            text: text,
            audioByteCount: audioData?.count,
            imageByteCount: imageJPEG?.count,
            usesImageForEstimate: usesImageForEstimate,
            clientRequestId: clientRequestId
        ))
        let step = script.isEmpty ? Step.succeed : script.removeFirst()
        switch step {
        case .succeed:
            return APIService.ReanalysisResult(entryId: id, status: .complete)
        case .fail(let error):
            throw error
        case .block:
            if !pendingReleases.isEmpty {
                return try pendingReleases.removeFirst().get()
            }
            return try await withCheckedThrowingContinuation { continuation in
                blockedContinuations.append(continuation)
            }
        }
    }

    /// Order-independent: releases callers already blocked, or pre-arms the
    /// next `.block` step when the caller hasn't reached it yet.
    func releaseBlocked(_ result: Result<APIService.ReanalysisResult, any Error>) {
        guard !blockedContinuations.isEmpty else {
            pendingReleases.append(result)
            return
        }
        let continuations = blockedContinuations
        blockedContinuations = []
        for continuation in continuations {
            continuation.resume(with: result)
        }
    }

    /// Cooperatively waits until the service has seen `count` correction
    /// requests; both this test and the view model task share the main actor.
    /// Bounded so a regression fails assertions instead of hanging the suite.
    func waitForCorrections(count: Int) async {
        var patience = 10_000
        while corrections.count < count, patience > 0 {
            patience -= 1
            await Task.yield()
        }
    }
}

@MainActor
struct EntryCorrectionFlowTests {

    private static let profile = Profile(
        userId: "00000000-0000-4000-8000-000000000042",
        timezone: "America/New_York",
        dailyMacroTarget: MacroTarget(
            caloriesKcal: 2_400,
            proteinG: 170,
            carbsG: 260,
            fatG: 70
        )
    )

    private func makeEntry(
        id: UUID = UUID(),
        summary: String,
        calories: Double,
        protein: Double = 30,
        carbs: Double = 40,
        fat: Double = 10,
        status: EntryStatus = .complete,
        updatedAt: Date? = nil
    ) -> Entry {
        Entry(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            summary: summary,
            imageURL: nil,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat,
            caloriesKcal: calories,
            localDay: "2027-01-15",
            status: status,
            statusMessage: status == .complete ? "Ready" : nil,
            statusUpdatedAt: updatedAt
        )
    }

    private func makeViewModel(
        entries: [Entry],
        service: CorrectionServiceFake,
        fetchEntryById: @escaping (UUID) async throws -> Entry?
    ) -> TodayViewModel {
        TodayViewModel(
            profile: Self.profile,
            api: APIService(
                supabaseUrl: URL(string: "https://unit-test.invalid")!,
                supabaseAnonKey: "unit-test",
                sessionJWTProvider: { "unit-test" }
            ),
            reanalysis: service,
            fetchEntryById: fetchEntryById,
            preloadedEntries: entries
        )
    }

    private func typedSubmission(_ text: String) -> EntryCorrectionSubmission {
        EntryCorrectionSubmission(text: text, audioData: nil, clientRequestId: UUID())
    }

    @Test func submissionImmediatelyShowsUpdatingStateWithoutTouchingTotals() async throws {
        let meal = makeEntry(summary: "Chicken bowl", calories: 500)
        let other = makeEntry(summary: "Yogurt", calories: 300)
        let service = CorrectionServiceFake()
        service.script = [.block]
        let vm = makeViewModel(entries: [meal, other], service: service) { [meal] id in
            self.makeEntry(id: id, summary: meal.summary, calories: 420)
        }

        let accepted = vm.submitCorrection(
            entryId: meal.id,
            submission: typedSubmission("The rice was one cup, not two")
        )

        #expect(accepted)
        let visible = try #require(vm.entries.first { $0.id == meal.id })
        #expect(visible.status == .analyzing)
        #expect(visible.statusMessage == EntryCorrectionPresentation.processingMessage)
        // The previous estimate stays on the card and in the day's totals
        // while the update runs; nothing dips to zero.
        #expect(visible.caloriesKcal == 500)
        #expect(vm.todayTotals.caloriesKcal == 800)
        #expect(vm.activeCorrectionTask(entryId: meal.id) != nil)
        #expect(vm.failedCorrections[meal.id] == nil)

        // The request is genuinely in flight now and the card still shows
        // the updating state — a slow network cannot blank the timeline.
        await service.waitForCorrections(count: 1)
        #expect(vm.entries.first { $0.id == meal.id }?.status == .analyzing)
        #expect(vm.todayTotals.caloriesKcal == 800)

        let task = vm.activeCorrectionTask(entryId: meal.id)
        service.releaseBlocked(.success(
            APIService.ReanalysisResult(entryId: meal.id, status: .complete)
        ))
        await task?.value
        #expect(vm.entries.first { $0.id == meal.id }?.caloriesKcal == 420)
    }

    @Test func duplicateSubmissionsWhileInFlightAreIgnored() async throws {
        let meal = makeEntry(summary: "Chicken bowl", calories: 500)
        let service = CorrectionServiceFake()
        service.script = [.block]
        let vm = makeViewModel(entries: [meal], service: service) { id in
            self.makeEntry(id: id, summary: "Chicken bowl", calories: 420)
        }

        #expect(vm.submitCorrection(
            entryId: meal.id,
            submission: typedSubmission("First correction")
        ))
        #expect(!vm.submitCorrection(
            entryId: meal.id,
            submission: typedSubmission("Second tap")
        ))
        await service.waitForCorrections(count: 1)
        #expect(service.corrections.count == 1)
        #expect(service.corrections.first?.text == "First correction")

        let task = vm.activeCorrectionTask(entryId: meal.id)
        service.releaseBlocked(.success(
            APIService.ReanalysisResult(entryId: meal.id, status: .complete)
        ))
        await task?.value
        #expect(service.corrections.count == 1)
    }

    @Test func typedAndSpokenCorrectionsFollowTheSamePath() async throws {
        for submission in [
            EntryCorrectionSubmission(
                text: "Half the rice",
                audioData: nil,
                clientRequestId: UUID()
            ),
            EntryCorrectionSubmission(
                text: nil,
                audioData: Data([0x01, 0x02, 0x03]),
                clientRequestId: UUID()
            ),
        ] {
            let meal = makeEntry(summary: "Chicken bowl", calories: 500)
            let service = CorrectionServiceFake()
            let corrected = makeEntry(
                id: meal.id,
                summary: "Chicken bowl",
                calories: 420,
                updatedAt: Date()
            )
            let vm = makeViewModel(entries: [meal], service: service) { _ in corrected }

            #expect(vm.submitCorrection(entryId: meal.id, submission: submission))
            #expect(vm.entries.first?.status == .analyzing)

            await vm.activeCorrectionTask(entryId: meal.id)?.value

            let recorded = try #require(service.corrections.first)
            #expect(recorded.text == submission.text)
            #expect(recorded.audioByteCount == submission.audioData?.count)
            #expect(recorded.clientRequestId == submission.clientRequestId)
            #expect(vm.entries.first?.status == .complete)
            #expect(vm.entries.first?.caloriesKcal == 420)
        }
    }

    @Test func memoryPhotoKeepsNutritionAndRetriesThePreservedPayload() async throws {
        let meal = makeEntry(summary: "Birthday dinner", calories: 695)
        let service = CorrectionServiceFake()
        service.script = [.fail(URLError(.notConnectedToInternet)), .succeed]
        let refreshed = makeEntry(
            id: meal.id,
            summary: meal.summary,
            calories: meal.caloriesKcal,
            updatedAt: Date()
        )
        let vm = makeViewModel(entries: [meal], service: service) { _ in refreshed }
        let requestID = UUID()
        let photo = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let submission = EntryCorrectionSubmission(
            text: nil,
            audioData: nil,
            imageJPEG: photo,
            clientRequestId: requestID
        )

        #expect(!submission.updatesEstimate)
        #expect(vm.submitCorrection(entryId: meal.id, submission: submission))
        #expect(vm.entries.first?.statusMessage == EntryCorrectionPresentation.savingPhotoMessage)
        await vm.activeCorrectionTask(entryId: meal.id)?.value
        #expect(vm.entries.first?.caloriesKcal == 695)
        #expect(vm.failedCorrections[meal.id] != nil)

        vm.retryCorrection(entryId: meal.id)
        await vm.activeCorrectionTask(entryId: meal.id)?.value

        #expect(service.corrections.count == 2)
        #expect(service.corrections.allSatisfy { $0.clientRequestId == requestID })
        #expect(service.corrections.allSatisfy { $0.imageByteCount == photo.count })
        #expect(service.corrections.allSatisfy { !$0.usesImageForEstimate })
        #expect(vm.entries.first?.caloriesKcal == 695)
        #expect(vm.entries.first?.status == .complete)
    }

    @Test func photoAndCorrectionAreRetriedTogetherAsEstimateEvidence() async throws {
        let meal = makeEntry(summary: "Chicken bowl", calories: 500)
        let service = CorrectionServiceFake()
        service.script = [.fail(URLError(.networkConnectionLost)), .succeed]
        let corrected = makeEntry(
            id: meal.id,
            summary: meal.summary,
            calories: 420,
            updatedAt: Date()
        )
        let vm = makeViewModel(entries: [meal], service: service) { _ in corrected }
        let requestID = UUID()
        let submission = EntryCorrectionSubmission(
            text: "The photo shows half the rice",
            audioData: Data([0x01, 0x02]),
            imageJPEG: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            clientRequestId: requestID
        )

        #expect(submission.updatesEstimate)
        #expect(vm.submitCorrection(entryId: meal.id, submission: submission))
        await vm.activeCorrectionTask(entryId: meal.id)?.value
        vm.retryCorrection(entryId: meal.id)
        await vm.activeCorrectionTask(entryId: meal.id)?.value

        #expect(service.corrections.count == 2)
        #expect(service.corrections.allSatisfy { $0.text == submission.text })
        #expect(service.corrections.allSatisfy { $0.audioByteCount == 2 })
        #expect(service.corrections.allSatisfy { $0.imageByteCount == 4 })
        #expect(service.corrections.allSatisfy { $0.usesImageForEstimate })
        #expect(vm.entries.first?.caloriesKcal == 420)
    }

    @Test func successReplacesTheMealRevealsItAndUpdatesTotals() async throws {
        let meal = makeEntry(summary: "Chicken bowl", calories: 500)
        let other = makeEntry(summary: "Yogurt", calories: 300)
        let corrected = makeEntry(
            id: meal.id,
            summary: "Chicken bowl, one cup rice",
            calories: 420,
            updatedAt: Date()
        )
        let service = CorrectionServiceFake()
        let vm = makeViewModel(entries: [meal, other], service: service) { _ in corrected }

        vm.submitCorrection(entryId: meal.id, submission: typedSubmission("One cup of rice"))
        await vm.activeCorrectionTask(entryId: meal.id)?.value

        let visible = try #require(vm.entries.first { $0.id == meal.id })
        #expect(visible.status == .complete)
        #expect(visible.summary == "Chicken bowl, one cup rice")
        #expect(visible.caloriesKcal == 420)
        #expect(vm.completionRevealEntryIds.contains(meal.id))
        #expect(vm.todayTotals.caloriesKcal == 720)
        #expect(vm.failedCorrections[meal.id] == nil)
        #expect(vm.activeCorrectionTask(entryId: meal.id) == nil)

        // The payload is consumed on success: retrying cannot double-apply.
        vm.retryCorrection(entryId: meal.id)
        #expect(service.corrections.count == 1)
    }

    @Test func failureRollsBackPreservesTheCorrectionAndRetriesIdempotently() async throws {
        let meal = makeEntry(summary: "Chicken bowl", calories: 500)
        let corrected = makeEntry(
            id: meal.id,
            summary: "Chicken bowl",
            calories: 420,
            updatedAt: Date()
        )
        let service = CorrectionServiceFake()
        let failureMessage = "You’ve reached today’s correction limit. Try again tomorrow."
        service.script = [
            .fail(APIService.APIError.server(statusCode: 429, message: failureMessage)),
        ]
        let vm = makeViewModel(entries: [meal], service: service) { _ in corrected }

        vm.submitCorrection(entryId: meal.id, submission: typedSubmission("One cup of rice"))
        await vm.activeCorrectionTask(entryId: meal.id)?.value

        // Rollback: the previous estimate is back, the failure is visible,
        // and the typed correction survives for retry.
        let rolledBack = try #require(vm.entries.first { $0.id == meal.id })
        #expect(rolledBack.status == .complete)
        #expect(rolledBack.caloriesKcal == 500)
        #expect(vm.failedCorrections[meal.id] == failureMessage)
        #expect(vm.todayTotals.caloriesKcal == 500)

        vm.retryCorrection(entryId: meal.id)
        #expect(vm.failedCorrections[meal.id] == nil)
        #expect(vm.entries.first?.status == .analyzing)
        await vm.activeCorrectionTask(entryId: meal.id)?.value

        #expect(service.corrections.count == 2)
        #expect(
            service.corrections[0].clientRequestId == service.corrections[1].clientRequestId
        )
        #expect(service.corrections[0].text == service.corrections[1].text)
        #expect(vm.entries.first?.caloriesKcal == 420)
        #expect(vm.failedCorrections[meal.id] == nil)
    }

    @Test func dismissingAFailedCorrectionDiscardsTheRetryPath() async throws {
        let meal = makeEntry(summary: "Chicken bowl", calories: 500)
        let service = CorrectionServiceFake()
        service.script = [.fail(URLError(.notConnectedToInternet))]
        let vm = makeViewModel(entries: [meal], service: service) { id in
            self.makeEntry(id: id, summary: "Chicken bowl", calories: 420)
        }

        vm.submitCorrection(entryId: meal.id, submission: typedSubmission("One cup of rice"))
        await vm.activeCorrectionTask(entryId: meal.id)?.value
        #expect(vm.failedCorrections[meal.id] != nil)

        vm.dismissFailedCorrection(entryId: meal.id)
        #expect(vm.failedCorrections[meal.id] == nil)
        vm.retryCorrection(entryId: meal.id)
        #expect(service.corrections.count == 1)
        #expect(vm.entries.first?.status == .complete)
    }

    @Test func reloadWhileACorrectionRunsRestoresTheUpdatingPresentation() {
        let inFlightId = UUID()
        let fetched = [
            makeEntry(id: inFlightId, summary: "Chicken bowl", calories: 500),
            makeEntry(summary: "Yogurt", calories: 300),
        ]

        let merge = TodayViewModel.mergedEntriesAfterLoad(
            fetched: fetched,
            inFlightCorrectionIds: [inFlightId],
            correctionResults: [:]
        )

        #expect(merge.entries[0].status == .analyzing)
        #expect(merge.entries[0].statusMessage == EntryCorrectionPresentation.processingMessage)
        #expect(merge.entries[0].caloriesKcal == 500)
        #expect(merge.refreshedSnapshots[inFlightId]?.status == .complete)
        #expect(merge.entries[1].status == .complete)
        #expect(merge.reflectedResultIds.isEmpty)
    }

    @Test func staleReloadRowsKeepCorrectedValuesUntilTheServerCatchesUp() {
        let correctedAt = Date(timeIntervalSince1970: 1_800_000_500)
        let mealId = UUID()
        let staleRow = makeEntry(
            id: mealId,
            summary: "Chicken bowl",
            calories: 500,
            updatedAt: correctedAt.addingTimeInterval(-30)
        )
        let corrected = makeEntry(
            id: mealId,
            summary: "Chicken bowl, one cup rice",
            calories: 420,
            updatedAt: correctedAt
        )

        let staleMerge = TodayViewModel.mergedEntriesAfterLoad(
            fetched: [staleRow],
            inFlightCorrectionIds: [],
            correctionResults: [mealId: corrected]
        )
        #expect(staleMerge.entries[0].caloriesKcal == 420)
        #expect(staleMerge.reflectedResultIds.isEmpty)

        let caughtUpRow = makeEntry(
            id: mealId,
            summary: "Chicken bowl, one cup rice",
            calories: 420,
            updatedAt: correctedAt.addingTimeInterval(5)
        )
        let caughtUpMerge = TodayViewModel.mergedEntriesAfterLoad(
            fetched: [caughtUpRow],
            inFlightCorrectionIds: [],
            correctionResults: [mealId: corrected]
        )
        #expect(caughtUpMerge.entries[0].caloriesKcal == 420)
        #expect(caughtUpMerge.reflectedResultIds == [mealId])
    }

    @Test func dailyTotalsKeepMealsBeingCorrectedCounted() {
        let updating = makeEntry(summary: "Chicken bowl", calories: 500, status: .analyzing)
        let processing = makeEntry(summary: "New meal", calories: 0, status: .analyzing)
        let complete = makeEntry(summary: "Yogurt", calories: 300)

        let withCorrection = TodayViewModel.totals(
            for: [updating, processing, complete],
            correctionsInFlight: [updating.id]
        )
        #expect(withCorrection.caloriesKcal == 800)

        // Default behavior is unchanged for the initial-log flow: only
        // completed meals count.
        let defaultTotals = TodayViewModel.totals(for: [updating, processing, complete])
        #expect(defaultTotals.caloriesKcal == 300)
    }
}
