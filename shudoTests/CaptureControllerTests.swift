import Foundation
import Testing
@testable import shudo

/// The capture bar is the app's one voice/text entry point; other screens
/// route through `CaptureController`.
@MainActor
struct CaptureControllerTests {
    @Test func eachTabGivesTheBarItsContext() {
        let controller = CaptureController()
        #expect(controller.context == .today)
        controller.setTab(.train)
        #expect(controller.context == .train)
        controller.setTab(.body)
        #expect(controller.context == .body)
        controller.setTab(.today)
        #expect(controller.context == .today)
        #expect(controller.request == nil)
    }

    @Test func bioRecordsOnTodayUntilTheSendGoesOut() throws {
        let controller = CaptureController()
        controller.setTab(.body)

        controller.startRecording(context: .bio)
        let request = try #require(controller.request)
        #expect(request.action == .record)
        #expect(request.context == .bio)
        #expect(request.context.tab == .today)
        #expect(controller.context == .bio)

        // The shell switches to Today: the bio context survives that…
        controller.setTab(.today)
        #expect(controller.context == .bio)
        controller.consume(request)
        #expect(controller.request == nil)

        // …and ends with the send (or a discard).
        controller.captureEnded()
        #expect(controller.context == .today)
    }

    @Test func leavingTheTabDropsAOneOffContext() {
        let controller = CaptureController()
        controller.startRecording(context: .bio)
        controller.setTab(.train)
        #expect(controller.context == .train)
    }

    @Test func trainAndBodyRequestsFollowTheirTabs() throws {
        let controller = CaptureController()
        controller.focusText(context: .train)
        let request = try #require(controller.request)
        #expect(request.action == .type)
        #expect(request.context.tab == .train)
        #expect(controller.contextOverride == nil, "a tab's own context is not an override")
        #expect(controller.context == .train)

        controller.startRecording(context: .body)
        #expect(controller.request?.context == .body)
        #expect(controller.context == .body)
        // A stale consume doesn't drop the newer request.
        controller.consume(request)
        #expect(controller.request?.context == .body)
    }

    @Test func contextsMapToHintsPurposesAndPlaceholders() {
        #expect(CaptureContext.today.contextHint == nil)
        #expect(CaptureContext.train.contextHint == .train)
        #expect(CaptureContext.body.contextHint == .body)
        #expect(CaptureContext.bio.contextHint == .bio)

        #expect(CaptureContext.train.transcriptionPurpose == .workout)
        #expect(CaptureContext.today.transcriptionPurpose == .coach)
        #expect(CaptureContext.body.transcriptionPurpose == .coach)
        #expect(CaptureContext.bio.transcriptionPurpose == .coach)

        #expect(CaptureContext.today.placeholder == "Tell Shudo anything…")
        #expect(CaptureContext.train.placeholder == "Log a workout…")
        #expect(CaptureContext.body.placeholder == "Weight, check-in notes…")
        #expect(AppTab.allCases.map(CaptureContext.forTab) == [.today, .body, .train])
    }

    @Test func contextHintsGoOnTheWire() throws {
        for (hint, wire) in [(CoachContextHint.train, "train"), (.body, "body"), (.bio, "bio")] {
            let request = CoachSendRequest(
                clientRequestId: UUID(),
                text: "bench 185 for 8",
                inputMode: .dictated,
                speechEngine: SpeechEngineID.openAITranscribe.rawValue,
                localDay: "2026-10-07",
                timezone: "America/New_York",
                contextHint: hint
            )
            let object = try #require(
                try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
            )
            #expect(object["context_hint"] as? String == wire)
            #expect(object["speech_engine"] as? String == "openai.gpt-4o-transcribe")
            #expect(try JSONDecoder().decode(CoachSendRequest.self, from: JSONEncoder().encode(request)) == request)
        }
    }
}
