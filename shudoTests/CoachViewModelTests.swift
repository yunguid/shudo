import Foundation
import Testing
@testable import shudo

@MainActor
final class RecordingThreadNotifier: CoachThreadNotifying {
    var isAppActive = true
    private(set) var removedDelivered: [UUID] = []
    private(set) var badges: [Int] = []
    private(set) var presented: [[CoachMessage]] = []

    func removeDelivered(messageIds: [UUID]) { removedDelivered += messageIds }
    func setBadge(_ count: Int) { badges.append(count) }
    func presentReplies(_ messages: [CoachMessage], unreadCount: Int) { presented.append(messages) }
}

@MainActor
final class RecordingBackgroundTasks: CoachBackgroundTasking {
    private(set) var begun = 0
    private(set) var ended = 0
    func begin(_ name: String) -> Int? {
        begun += 1
        return begun
    }
    func end(_ token: Int?) { ended += 1 }
}

@MainActor
struct CoachViewModelTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let today = "2026-10-06"
    private let now = Date(timeIntervalSince1970: 1_791_302_400) // 2026-10-06T16:00:00Z

    private func makeViewModel(
        service: FakeCoachService,
        notifier: RecordingThreadNotifier? = nil,
        background: RecordingBackgroundTasks? = nil,
        localDay: String? = nil
    ) -> CoachViewModel {
        let utc = utc
        let fixedNow = now
        return CoachViewModel(
            service: service,
            localDay: localDay,
            timeZone: { utc },
            now: { fixedNow },
            notifier: notifier,
            backgroundTasks: background,
            autoResumeDelays: [1_000_000]
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }

    // MARK: Send

    @Test func sendShowsAnOptimisticBubbleThenTheStreamedReply() async {
        let service = FakeCoachService(now: { [now] in now })
        let background = RecordingBackgroundTasks()
        let vm = makeViewModel(service: service, background: background)

        let id = vm.send(text: "  What should I eat?  ", mode: .dictated, speechEngine: "apple.speech_transcriber")
        let clientRequestId = try? #require(id)
        #expect(vm.pendingSends.map(\.clientRequestId) == [clientRequestId])
        #expect(vm.pendingSends.first?.text == "What should I eat?")
        #expect(vm.pendingSends.first?.state == .sending)
        #expect(vm.items.count == 1)

        #expect(await waitUntil { !vm.isSending })
        #expect(vm.pendingSends.isEmpty)
        #expect(vm.typing == nil)
        #expect(vm.messages.map(\.role) == [.user, .coach])
        #expect(vm.messages.first?.clientRequestId == clientRequestId)
        #expect(vm.messages.last?.body == "Copy that. Protein first, then we talk dessert.")
        #expect(vm.messages.last?.isStreaming == false)

        let sent = service.sentRequests
        #expect(sent.count == 1)
        #expect(sent.first?.clientRequestId == clientRequestId)
        #expect(sent.first?.inputMode == .dictated)
        #expect(sent.first?.speechEngine == "apple.speech_transcriber")
        #expect(sent.first?.localDay == today)
        #expect(sent.first?.timezone == "UTC")
        #expect(background.begun == 1 && background.ended == 1)
    }

    @Test func emptyAndOversizedMessagesAreNotSent() {
        let vm = makeViewModel(service: FakeCoachService(now: { [now] in now }))
        #expect(vm.send(text: "   ") == nil)
        #expect(vm.send(text: String(repeating: "a", count: CoachSendRequest.maximumTextLength + 1)) == nil)
        #expect(vm.errorMessage != nil)
        #expect(vm.pendingSends.isEmpty)
    }

    @Test func typingShowsStatusLabelsThenStreamingText() async {
        let service = FakeCoachService(now: { [now] in now })
        let replyId = UUID()
        let fixedNow = now
        service.script = { request, context in
            [
                .event(.accepted(runId: context.runId, userMessage: context.userMessage, duplicate: false)),
                .event(.status(label: "Checking what’s near you…")),
                .pause(milliseconds: 150),
                .event(.delta(messageId: replyId, text: "There’s a ")),
                .pause(milliseconds: 150),
                .event(.delta(messageId: replyId, text: "7-Eleven.")),
                .event(.message(CoachMessage(id: replyId, role: .coach, kind: "text", body: "There’s a 7-Eleven.", localDay: request.localDay, deliverAt: fixedNow))),
                .event(.done(runId: context.runId, messageIds: [replyId])),
            ]
        }
        let vm = makeViewModel(service: service)
        vm.send(text: "Snack?")
        #expect(await waitUntil { vm.typing == .thinking(label: "Checking what’s near you…") })
        #expect(vm.pendingSends.isEmpty, "accepted removes the optimistic bubble")
        #expect(await waitUntil { vm.typing == .streaming(messageId: replyId) })
        #expect(vm.messages.last?.body == "There’s a ")
        #expect(vm.messages.last?.isStreaming == true)
        #expect(await waitUntil { !vm.isSending })
        #expect(vm.typing == nil)
        #expect(vm.messages.last?.body == "There’s a 7-Eleven.")
    }

    @Test func failureBeforeAcceptanceKeepsTheBubbleAndRetriesWithTheSameId() async throws {
        let service = FakeCoachService(now: { [now] in now })
        service.enqueueOverride([.fail(.server(statusCode: 503, code: nil, message: "Shudo is down."))])
        let vm = makeViewModel(service: service)

        let id = try #require(vm.send(text: "Log a banana"))
        #expect(await waitUntil { vm.pendingSends.first?.isFailed == true })
        #expect(vm.pendingSends.first?.state == .failed(message: "Shudo is down.", retryable: true))
        #expect(vm.messages.isEmpty)

        vm.retry(id)
        #expect(vm.pendingSends.first?.state == .sending)
        #expect(await waitUntil { !vm.isSending && vm.pendingSends.isEmpty })
        #expect(service.sentRequests.map(\.clientRequestId) == [id, id])
        #expect(vm.messages.filter { $0.role == .user }.count == 1)
        #expect(vm.messages.last?.role == .coach)
    }

    @Test func serverErrorEventBeforeAcceptanceFailsTheBubble() async throws {
        let service = FakeCoachService(now: { [now] in now })
        service.enqueueOverride([
            .event(.error(CoachStreamFailure(code: "quota", message: "Shudo’s tapped out for today.", retryable: false))),
        ])
        let vm = makeViewModel(service: service)
        _ = try #require(vm.send(text: "Hey"))
        #expect(await waitUntil { vm.pendingSends.first?.isFailed == true })
        #expect(vm.pendingSends.first?.state == .failed(message: "Shudo’s tapped out for today.", retryable: false))
    }

    @Test func aDroppedStreamAfterAcceptanceResumesWithoutDuplicatingText() async throws {
        let service = FakeCoachService(now: { [now] in now })
        let user = CoachMessage(role: .user, kind: "text", body: "Plan my lunch", localDay: today, deliverAt: now)
        let replyId = UUID()
        // First attempt: accepted, one delta, then the connection drops.
        service.enqueueOverride([
            .event(.accepted(runId: UUID(), userMessage: user, duplicate: false)),
            .event(.delta(messageId: replyId, text: "Copy that. ")),
            .fail(.streamEndedEarly),
        ])
        // The automatic resend tails the run, restating the text so far.
        service.enqueueOverride([
            .event(.accepted(runId: UUID(), userMessage: user, duplicate: true)),
            .event(.delta(messageId: replyId, text: "Copy that. ")),
            .event(.delta(messageId: replyId, text: "Protein first.")),
            .event(.done(runId: nil, messageIds: [replyId])),
        ])
        let vm = makeViewModel(service: service)
        let id = try #require(vm.send(text: "Plan my lunch"))
        #expect(await waitUntil { !vm.isSending })
        #expect(service.sentRequests.map(\.clientRequestId) == [id, id])
        #expect(vm.interruptions.isEmpty)
        #expect(vm.messages.filter { $0.role == .user }.count == 1)
        let reply = try #require(vm.message(id: replyId))
        #expect(reply.body == "Copy that. Protein first.")
        #expect(!reply.isStreaming)
    }

    @Test func aStreamThatKeepsDroppingBecomesARetryableInterruption() async throws {
        let service = FakeCoachService(now: { [now] in now })
        let user = CoachMessage(role: .user, kind: "text", body: "Hey", localDay: today, deliverAt: now)
        let replyId = UUID()
        for _ in 0..<2 {
            service.enqueueOverride([
                .event(.accepted(runId: UUID(), userMessage: user, duplicate: false)),
                .event(.delta(messageId: replyId, text: "Half a")),
                .fail(.streamEndedEarly),
            ])
        }
        let vm = makeViewModel(service: service)
        let id = try #require(vm.send(text: "Hey"))
        #expect(await waitUntil { vm.interruptions[id] != nil })
        let interruption = try #require(vm.interruptions[id])
        #expect(interruption.retryable)
        #expect(interruption.userMessageId == user.id)
        #expect(vm.interruption(forUserMessage: user.id) == interruption)
        #expect(vm.message(id: replyId)?.isStreaming == false)
        #expect(vm.message(id: replyId)?.body == "Half a")

        // Retry resends the same id; the fake now completes it.
        service.enqueueOverride([
            .event(.accepted(runId: UUID(), userMessage: user, duplicate: true)),
            .event(.delta(messageId: replyId, text: "Half a")),
            .event(.delta(messageId: replyId, text: " sandwich.")),
            .event(.done(runId: nil, messageIds: [replyId])),
        ])
        vm.retry(id)
        #expect(await waitUntil { !vm.isSending && vm.interruptions.isEmpty })
        #expect(vm.message(id: replyId)?.body == "Half a sandwich.")
        #expect(service.sentRequests.allSatisfy { $0.clientRequestId == id })
    }

    @Test func repliesFinishedWhileInactiveArePostedAsNotifications() async {
        let service = FakeCoachService(now: { [now] in now })
        let notifier = RecordingThreadNotifier()
        notifier.isAppActive = false
        let vm = makeViewModel(service: service, notifier: notifier)
        vm.send(text: "Back in 5")
        #expect(await waitUntil { !vm.isSending })
        #expect(notifier.presented.count == 1)
        #expect(notifier.presented.first?.map(\.role) == [.coach])
    }

    @Test func sendingFromAPastDayJumpsBackToToday() async {
        let service = FakeCoachService(now: { [now] in now })
        let vm = makeViewModel(service: service, localDay: "2026-10-01")
        #expect(!vm.isShowingToday)
        vm.send(text: "Morning")
        #expect(vm.localDay == today)
        #expect(vm.isShowingToday)
        #expect(await waitUntil { !vm.isSending })
        #expect(service.sentRequests.first?.localDay == today)
    }

    @Test func photoAttachmentsUploadBeforeSending() async {
        let service = FakeCoachService(now: { [now] in now })
        let vm = makeViewModel(service: service)
        let jpeg = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        vm.send(text: "", attachment: .jpeg(jpeg))
        #expect(vm.pendingSends.first?.hasAttachment == true)
        #expect(vm.pendingSends.first?.attachmentJPEG == jpeg)
        #expect(await waitUntil { !vm.isSending })
        #expect(service.uploadedPaths.count == 1)
        #expect(service.sentRequests.first?.attachmentPath == service.uploadedPaths.first)
        #expect(vm.messages.first?.kind == "photo")
    }

    // MARK: Refresh and merge

    @Test func refreshLoadsTheDayInOrderAndCountsUnread() async {
        let fixtures = CoachFixtures.day(today, now: now)
        let service = FakeCoachService(messages: fixtures.shuffled(), now: { [now] in now })
        let notifier = RecordingThreadNotifier()
        let vm = makeViewModel(service: service, notifier: notifier)
        await vm.refresh()
        #expect(vm.messages.count == fixtures.count)
        #expect(vm.messages.map(\.id) == CoachThreadOrdering.sorted(fixtures).map(\.id))
        #expect(vm.unreadCount == fixtures.filter { $0.role == .coach }.count)
        #expect(notifier.badges.last == vm.unreadCount)
        #expect(!vm.isLoading)
        #expect(vm.errorMessage == nil)
    }

    @Test func refreshFailureKeepsTheThreadAndShowsAnError() async {
        let fixtures = CoachFixtures.day(today, now: now)
        let service = FakeCoachService(messages: fixtures, now: { [now] in now })
        let vm = makeViewModel(service: service)
        await vm.refresh()
        service.setFetchDayError(URLError(.notConnectedToInternet))
        await vm.refresh()
        #expect(vm.messages.count == fixtures.count)
        #expect(vm.errorMessage == "You’re offline. Shudo will get it when you’re back.")
    }

    @Test func refreshSwitchesDays() async {
        let yesterday = "2026-10-05"
        let old = CoachMessage(role: .coach, kind: "recap", body: "Solid day.", localDay: yesterday, deliverAt: now.addingTimeInterval(-86_000))
        let service = FakeCoachService(messages: [old] + CoachFixtures.day(today, now: now), now: { [now] in now })
        let vm = makeViewModel(service: service)
        await vm.refresh(day: yesterday)
        #expect(vm.localDay == yesterday)
        #expect(vm.messages.map(\.id) == [old.id])
        await vm.refresh(day: today)
        #expect(vm.messages.count == CoachFixtures.day(today, now: now).count)
    }

    @Test func mergeKeepsLocalStreamingTextAheadOfTheDatabase() {
        let id = UUID()
        func message(_ body: String, streaming: Bool, readAt: Date? = nil) -> CoachMessage {
            CoachMessage(
                id: id,
                role: .coach,
                kind: "text",
                body: body,
                rawPayload: .object(["streaming": .bool(streaming)]),
                localDay: today,
                deliverAt: now,
                readAt: readAt
            )
        }
        let local = message("Copy that. Protein", streaming: true, readAt: now)
        let behind = message("Copy that.", streaming: true)
        let merged = CoachThreadMerge.merge(local: [local], fetched: [behind], keepingLocal: [])
        #expect(merged.first?.body == "Copy that. Protein")
        #expect(merged.first?.readAt == now, "a local read survives a racing fetch")

        let final = message("Copy that. Different final copy.", streaming: false)
        #expect(CoachThreadMerge.merge(local: [local], fetched: [final], keepingLocal: []).first?.body
            == "Copy that. Different final copy.", "the finished server row always wins")

        let orphan = CoachMessage(role: .coach, kind: "text", body: "Streaming", localDay: today, deliverAt: now)
        #expect(CoachThreadMerge.merge(local: [orphan], fetched: [], keepingLocal: []).isEmpty)
        #expect(CoachThreadMerge.merge(local: [orphan], fetched: [], keepingLocal: [orphan.id]).map(\.id) == [orphan.id])
    }

    @Test func resumedDeltasReplaceOrAppend() {
        #expect(CoachThreadMerge.resumedBody(existing: "Copy", delta: "Copy that.", mayRestate: true) == "Copy that.")
        #expect(CoachThreadMerge.resumedBody(existing: "Copy", delta: " that.", mayRestate: true) == "Copy that.")
        #expect(CoachThreadMerge.resumedBody(existing: "Copy", delta: "Copy that.", mayRestate: false) == "CopyCopy that.")
        #expect(CoachThreadMerge.resumedBody(existing: "", delta: "Hi", mayRestate: true) == "Hi")
    }

    @Test func aFetchedUserRowClearsAFailedBubbleAndTailsTheTurn() async throws {
        let service = FakeCoachService(now: { [now] in now })
        service.enqueueOverride([.fail(.streamEndedEarly)])
        let vm = makeViewModel(service: service)
        let id = try #require(vm.send(text: "Did it go through?"))
        #expect(await waitUntil { vm.pendingSends.first?.isFailed == true })

        // The server actually stored it (the connection died after the insert).
        service.insert(CoachMessage(role: .user, kind: "text", body: "Did it go through?", localDay: today, deliverAt: now, clientRequestId: id))
        await vm.refresh()
        #expect(vm.pendingSends.isEmpty)
        #expect(await waitUntil { !vm.isSending })
        #expect(service.sentRequests.map(\.clientRequestId) == [id, id])
        #expect(vm.messages.contains { $0.role == .coach })
    }

    // MARK: Read state and actions

    @Test func markVisibleReadClearsUnreadLocallyAndOnTheServer() async {
        let fixtures = CoachFixtures.day(today, now: now)
        let service = FakeCoachService(messages: fixtures, now: { [now] in now })
        let notifier = RecordingThreadNotifier()
        let vm = makeViewModel(service: service, notifier: notifier)
        await vm.refresh()
        let unread = vm.messages.filter { $0.isUnread(at: now) }.map(\.id)
        #expect(!unread.isEmpty)

        await vm.markVisibleRead()
        #expect(vm.unreadCount == 0)
        #expect(vm.messages.allSatisfy { $0.role != .coach || $0.readAt != nil })
        #expect(Set(service.markedReadIds) == Set(unread))
        #expect(Set(notifier.removedDelivered) == Set(unread))
        #expect(notifier.badges.last == 0)
        #expect(try! await service.fetchUnreadCount() == 0)
    }

    @Test func cardActionsUpdateTheCardAndReuseTheirIdempotencyKey() async throws {
        let fixtures = CoachFixtures.day(today, now: now)
        let service = FakeCoachService(messages: fixtures, now: { [now] in now })
        let vm = makeViewModel(service: service)
        await vm.refresh()
        let cardMessage = try #require(vm.messages.first { if case .goalChange = $0.payload { return true }; return false })
        guard case .goalChange(let card) = cardMessage.payload else { return }

        service.setActError(URLError(.timedOut))
        let failed = await vm.act(on: .goalChange(card, decision: .apply))
        #expect(!failed)
        #expect(vm.errorMessage == "Shudo took too long to answer. Try again.")
        #expect(vm.actionsInFlight.isEmpty)

        let succeeded = await vm.act(on: .goalChange(card, decision: .apply))
        #expect(succeeded)
        #expect(service.actions.count == 2)
        #expect(service.actions[0].clientRequestId == service.actions[1].clientRequestId)
        guard case .goalChange(let updated)? = vm.message(id: cardMessage.id)?.payload else {
            Issue.record("card disappeared")
            return
        }
        #expect(updated.status == .applied)
    }

    @Test func focusSwitchesToTheLinkedDay() async {
        let yesterday = "2026-10-05"
        let old = CoachMessage(role: .coach, kind: "text", body: "Night.", localDay: yesterday, deliverAt: now.addingTimeInterval(-80_000))
        let service = FakeCoachService(messages: [old], now: { [now] in now })
        let vm = makeViewModel(service: service)
        await vm.focus(messageId: old.id, day: yesterday)
        #expect(vm.localDay == yesterday)
        #expect(vm.focusedMessageId == old.id)
        vm.consumeFocus()
        #expect(vm.focusedMessageId == nil)
    }
}
