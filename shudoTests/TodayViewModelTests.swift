//
//  TodayViewModelTests.swift
//  shudoTests
//
//  Tests for TodayViewModel processing and retry behavior
//

import Testing
import Foundation
@testable import shudo

struct TodayViewModelTests {

    @Test func testDayTotals_empty_hasZeroValues() {
        let totals = DayTotals.empty

        #expect(totals.proteinG == 0)
        #expect(totals.carbsG == 0)
        #expect(totals.fatG == 0)
        #expect(totals.caloriesKcal == 0)
    }

    @Test func processingStatusesRemainVisibleWhileWorkContinues() {
        #expect(EntryStatus.queued.isProcessing)
        #expect(EntryStatus.transcribing.isProcessing)
        #expect(EntryStatus.analyzing.isProcessing)
        #expect(!EntryStatus.deleting.isProcessing)
        #expect(!EntryStatus.complete.isProcessing)
        #expect(!EntryStatus.failed.isProcessing)
    }

    @Test func deletionStatesNeverOfferAnalysisRetry() {
        let deleting = Entry(
            id: UUID(),
            createdAt: Date(),
            summary: "Meal",
            imageURL: nil,
            proteinG: 0,
            carbsG: 0,
            fatG: 0,
            caloriesKcal: 0,
            status: .deleting,
            statusMessage: "Deleting"
        )
        let interrupted = Entry(
            id: UUID(),
            createdAt: Date(),
            summary: "Meal",
            imageURL: nil,
            proteinG: 0,
            carbsG: 0,
            fatG: 0,
            caloriesKcal: 0,
            status: .failed,
            statusMessage: "Delete interrupted"
        )

        #expect(!deleting.canRetry)
        #expect(deleting.displayStatusMessage == "Deleting")
        #expect(!interrupted.canRetry)
    }

    @MainActor
    @Test func staleProcessingEntryAutoResumesOncePerObservedAttemptAfterLeaseBuffer() {
        let now = Date()
        var entry = Entry(
            id: UUID(),
            createdAt: now.addingTimeInterval(-500),
            summary: "Stalled meal",
            imageURL: nil,
            proteinG: 0,
            carbsG: 0,
            fatG: 0,
            caloriesKcal: 0,
            status: .analyzing,
            statusUpdatedAt: now.addingTimeInterval(-145),
            processingAttempts: 0
        )

        var requestState: TodayViewModel.AutoResumeRequestState?
        for observedAttempt in 0...3 {
            entry.processingAttempts = observedAttempt
            #expect(TodayViewModel.shouldAutoResume(
                entry,
                at: now,
                requestState: requestState
            ))

            requestState = TodayViewModel.AutoResumeRequestState(
                attempt: observedAttempt,
                retryAfter: nil
            )
            #expect(!TodayViewModel.shouldAutoResume(
                entry,
                at: now,
                requestState: requestState
            ))
        }

        var fresh = entry
        fresh.statusUpdatedAt = now.addingTimeInterval(-144)
        #expect(!TodayViewModel.shouldAutoResume(fresh, at: now, requestState: nil))

        var exhausted = entry
        exhausted.processingAttempts = 4
        #expect(!TodayViewModel.shouldAutoResume(exhausted, at: now, requestState: nil))

        exhausted.status = .failed
        exhausted.processingAttempts = 3
        #expect(!TodayViewModel.shouldAutoResume(exhausted, at: now, requestState: nil))
    }

    @MainActor
    @Test func transientAutoResumeFailureRetriesOnlyAfterBackoffDeadline() {
        let failureTime = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = Entry(
            id: UUID(),
            createdAt: failureTime.addingTimeInterval(-500),
            summary: "Stalled meal",
            imageURL: nil,
            proteinG: 0,
            carbsG: 0,
            fatG: 0,
            caloriesKcal: 0,
            status: .analyzing,
            statusUpdatedAt: failureTime.addingTimeInterval(-200),
            processingAttempts: 2
        )
        let retryState = TodayViewModel.autoResumeRetryState(
            forAttempt: entry.processingAttempts,
            scheduledAt: failureTime
        )

        #expect(TodayViewModel.autoResumeRetryInterval == 50)
        #expect(retryState.retryAfter == failureTime.addingTimeInterval(50))
        #expect(!TodayViewModel.shouldAutoResume(
            entry,
            at: failureTime.addingTimeInterval(49),
            requestState: retryState
        ))
        #expect(TodayViewModel.shouldAutoResume(
            entry,
            at: failureTime.addingTimeInterval(50),
            requestState: retryState
        ))

        let retryInFlight = TodayViewModel.AutoResumeRequestState(
            attempt: entry.processingAttempts,
            retryAfter: nil
        )
        #expect(!TodayViewModel.shouldAutoResume(
            entry,
            at: failureTime.addingTimeInterval(51),
            requestState: retryInFlight
        ))
    }

    @MainActor
    @Test func acceptedResumeWithoutAttemptProgressRedispatchesAtBoundedCadence() {
        let acceptedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = Entry(
            id: UUID(),
            createdAt: acceptedAt.addingTimeInterval(-500),
            summary: "Stalled meal",
            imageURL: nil,
            proteinG: 0,
            carbsG: 0,
            fatG: 0,
            caloriesKcal: 0,
            status: .analyzing,
            statusUpdatedAt: acceptedAt.addingTimeInterval(-200),
            processingAttempts: 2
        )

        let firstAcceptedState = TodayViewModel.autoResumeRetryState(
            forAttempt: entry.processingAttempts,
            scheduledAt: acceptedAt
        )
        #expect(!TodayViewModel.shouldAutoResume(
            entry,
            at: acceptedAt.addingTimeInterval(3),
            requestState: firstAcceptedState
        ))
        #expect(!TodayViewModel.shouldAutoResume(
            entry,
            at: acceptedAt.addingTimeInterval(49),
            requestState: firstAcceptedState
        ))
        #expect(TodayViewModel.shouldAutoResume(
            entry,
            at: acceptedAt.addingTimeInterval(50),
            requestState: firstAcceptedState
        ))

        // A second accepted redispatch replaces the deadline in the same state;
        // it does not create a competing retry task or a three-second loop.
        let secondAcceptedState = TodayViewModel.autoResumeRetryState(
            forAttempt: entry.processingAttempts,
            scheduledAt: acceptedAt.addingTimeInterval(50)
        )
        #expect(!TodayViewModel.shouldAutoResume(
            entry,
            at: acceptedAt.addingTimeInterval(99),
            requestState: secondAcceptedState
        ))
        #expect(TodayViewModel.shouldAutoResume(
            entry,
            at: acceptedAt.addingTimeInterval(100),
            requestState: secondAcceptedState
        ))
    }

    @Test func failedEntryExposesRetryUntilAttemptsAreExhausted() {
        var entry = Entry(
            id: UUID(),
            createdAt: Date(),
            summary: "Failed meal",
            imageURL: nil,
            proteinG: 0,
            carbsG: 0,
            fatG: 0,
            caloriesKcal: 0,
            status: .failed,
            processingAttempts: 2
        )

        #expect(entry.canRetry)
        entry.processingAttempts = 3
        #expect(!entry.canRetry)
        #expect(entry.displayStatusMessage == "Retry limit reached — log it again")
    }

    @MainActor
    @Test func targetHistoryFailureKeepsTheLastKnownTargets() {
        let current = [
            DailyMacroTargetSnapshot(
                targetDay: "2026-07-01",
                target: MacroTarget(
                    caloriesKcal: 2_200,
                    proteinG: 160,
                    carbsG: 230,
                    fatG: 70
                )
            )
        ]
        let refreshed = [
            DailyMacroTargetSnapshot(
                targetDay: "2026-07-20",
                target: MacroTarget(
                    caloriesKcal: 2_000,
                    proteinG: 170,
                    carbsG: 190,
                    fatG: 65
                )
            )
        ]

        #expect(TodayViewModel.targetHistoryAfterLoad(
            loaded: nil,
            current: current
        ) == current)
        #expect(TodayViewModel.targetHistoryAfterLoad(
            loaded: refreshed,
            current: current
        ) == refreshed)
    }

    @MainActor
    @Test func exhaustedResumeConflictBecomesUsefulRowStatus() {
        let message = TodayViewModel.resumeConflictMessage(
            "This meal could not be recovered. Delete it and log it again.",
            automatic: true
        )
        #expect(message == "Retry limit reached — log it again")
    }

    @MainActor
    @Test func incompleteMediaConflictIsNotMisreportedAsRetryExhaustion() {
        let message = TodayViewModel.resumeConflictMessage(
            "This meal's photo never finished uploading. Delete it and log it again.",
            automatic: true
        )
        #expect(message == "Attachment upload incomplete — delete and log it again")
    }

    @MainActor
    @Test func onlyProcessingToCompleteTransitionsRequestAProgressiveReveal() {
        #expect(TodayViewModel.shouldRevealCompletedAnalysis(
            previous: .queued,
            refreshed: .complete
        ))
        #expect(TodayViewModel.shouldRevealCompletedAnalysis(
            previous: .analyzing,
            refreshed: .complete
        ))
        #expect(!TodayViewModel.shouldRevealCompletedAnalysis(
            previous: .complete,
            refreshed: .complete
        ))
        #expect(!TodayViewModel.shouldRevealCompletedAnalysis(
            previous: .failed,
            refreshed: .complete
        ))
        #expect(!TodayViewModel.shouldRevealCompletedAnalysis(
            previous: nil,
            refreshed: .complete
        ))
    }

    @Test func completedAnalysisRevealPlanIsStagedAndReduceMotionIsImmediate() {
        #expect(CompletedAnalysisRevealPlan.phases(reduceMotion: false) == [
            .title,
            .protein,
            .carbs,
            .fat,
            .calories,
        ])
        #expect(CompletedAnalysisRevealPlan.phases(reduceMotion: true) == [.calories])
        #expect(
            CompletedAnalysisRevealPlan.delay(before: .title)
                < CompletedAnalysisRevealPlan.delay(before: .protein)
        )
    }

    @Test func analysisPreviewIsBoundedNormalizedAndOnlyVisibleDuringActiveAnalysis() {
        let normalized = AnalysisPreviewPresentation.text(
            "  Salmon\nwith\t rice   and broccoli.  ",
            status: .analyzing,
            isRetrying: false
        )
        #expect(normalized == "Salmon with rice and broccoli.")

        let unicodePreview = String(repeating: "🍜", count: 260)
        let bounded = AnalysisPreviewPresentation.text(
            unicodePreview,
            status: .analyzing,
            isRetrying: false
        )
        #expect(bounded?.count == AnalysisPreviewPresentation.maximumCharacterCount)
        #expect(bounded == String(unicodePreview.prefix(240)))

        #expect(AnalysisPreviewPresentation.text(
            "Analyzing salmon",
            status: .complete,
            isRetrying: false
        ) == nil)
        #expect(AnalysisPreviewPresentation.text(
            "Analyzing salmon",
            status: .analyzing,
            isRetrying: true
        ) == nil)
        #expect(AnalysisPreviewPresentation.text(
            " \n\t ",
            status: .analyzing,
            isRetrying: false
        ) == nil)
    }

    @Test func analysisPreviewFramesAdvanceSmoothlyAndRespectAccessibility() {
        let target = "Salmon, rice, broccoli, and a light sesame dressing"
        var rendered = ""
        var frameCount = 0

        while rendered != target {
            let next = AnalysisPreviewPresentation.nextFrame(
                from: rendered,
                toward: target,
                reduceMotion: false
            )
            #expect(target.hasPrefix(next))
            #expect(next.count > rendered.count)
            #expect(next.count - rendered.count <= 8)
            rendered = next
            frameCount += 1
        }

        #expect(frameCount > 1)
        #expect(AnalysisPreviewPresentation.nextFrame(
            from: "Old partial",
            toward: "Replacement partial",
            reduceMotion: false
        ) == "Replacement partial")
        #expect(AnalysisPreviewPresentation.nextFrame(
            from: "",
            toward: target,
            reduceMotion: true
        ) == target)
    }

    @MainActor
    @Test func analyzingPollingStaysFastWhileOtherStatesBackOffWithinBounds() {
        #expect(TodayViewModel.nextPollingDelay(
            current: TodayViewModel.maximumPollingInterval,
            status: .analyzing
        ) == TodayViewModel.streamingPreviewPollingInterval)
        #expect(TodayViewModel.nextPollingDelay(
            current: TodayViewModel.streamingPreviewPollingInterval,
            status: .transcribing
        ) == 975_000_000)
        #expect(TodayViewModel.nextPollingDelay(
            current: 2_500_000_000,
            status: .queued
        ) == TodayViewModel.maximumPollingInterval)
        #expect(TodayViewModel.nextPollingDelay(
            current: 2_500_000_000,
            status: nil
        ) == TodayViewModel.maximumPollingInterval)
    }

    @Test func entryPollingSelectsThePersistedAnalysisPreviewExactlyOnce() {
        let columns = SupabaseService.entryListColumns.split(separator: ",")
        #expect(columns.filter { $0 == "analysis_preview" }.count == 1)
        #expect(columns.contains("updated_at"))
        #expect(columns.contains("status"))
        #expect(columns.contains("processing_attempts"))
    }

    @MainActor
    @Test func pinnedTodayAdvancesAcrossMidnightButHistoricalDaysStaySelected() throws {
        let timezone = "America/New_York"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: timezone))
        let beforeMidnight = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 20, hour: 23, minute: 59)
        ))
        let afterMidnight = try #require(calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 21, hour: 0, minute: 1)
        ))

        #expect(TodayViewModel.shouldAdvancePinnedDay(
            currentDay: beforeMidnight,
            now: afterMidnight,
            timezone: timezone,
            wasPinnedToToday: true
        ))
        #expect(!TodayViewModel.shouldAdvancePinnedDay(
            currentDay: beforeMidnight,
            now: afterMidnight,
            timezone: timezone,
            wasPinnedToToday: false
        ))
        #expect(!TodayViewModel.shouldAdvancePinnedDay(
            currentDay: beforeMidnight,
            now: beforeMidnight.addingTimeInterval(30),
            timezone: timezone,
            wasPinnedToToday: true
        ))
    }
}
