import Foundation
import Testing
@testable import shudo

struct CoachSSEParserTests {
    private static let userId = "0b6a1d6e-0000-4000-8000-0000000000aa"
    private static let replyId = "0b6a1d6e-0000-4000-8000-0000000000bb"
    private static let runId = "0b6a1d6e-0000-4000-8000-0000000000cc"

    private static let userRow = """
    {"id":"\(userId)","role":"user","kind":"text","body":"Lunch?","payload":{},"local_day":"2026-10-06",\
    "deliver_at":"2026-10-06T16:00:00Z","status":"delivered","notify":false,\
    "client_request_id":"0b6a1d6e-0000-4000-8000-0000000000dd","created_at":"2026-10-06T16:00:00Z",\
    "updated_at":"2026-10-06T16:00:00Z"}
    """

    private static let replyRow = """
    {"id":"\(replyId)","role":"coach","kind":"text","body":"Chicken bowl. Café-style 🌯.","payload":{},\
    "local_day":"2026-10-06","deliver_at":"2026-10-06T16:00:02Z","status":"delivered","notify":false,\
    "created_at":"2026-10-06T16:00:02Z","updated_at":"2026-10-06T16:00:04Z"}
    """

    /// A realistic stream: one `data:` line per event, keepalives, blank
    /// lines, and non-ASCII text.
    private static let stream = """
    : keepalive

    data: {"type":"accepted","run_id":"\(runId)","user_message":\(userRow),"duplicate":false}

    data: {"type":"status","label":"Checking what’s near you…"}

    : keepalive

    data: {"type":"delta","message_id":"\(replyId)","text":"Chicken bowl. "}

    data: {"type":"delta","message_id":"\(replyId)","text":"Café-style 🌯."}

    data: {"type":"message","message":\(replyRow)}

    data: {"type":"done","run_id":"\(runId)","message_ids":["\(replyId)"]}


    """

    private func parseWhole(_ text: String) -> (events: [CoachStreamEvent], parser: CoachSSEParser) {
        var parser = CoachSSEParser()
        var events = parser.feed(Array(text.utf8))
        events += parser.finish()
        return (events, parser)
    }

    @Test func parsesEveryEventTypeAndSkipsKeepalives() throws {
        let (events, parser) = parseWhole(Self.stream)
        #expect(events.count == 6)
        #expect(parser.keepaliveCount == 2)
        guard case .accepted(let runId, let user, let duplicate) = events[0] else {
            Issue.record("first event must be accepted")
            return
        }
        #expect(runId == UUID(uuidString: Self.runId))
        #expect(user?.role == .user)
        #expect(user?.clientRequestId == UUID(uuidString: "0b6a1d6e-0000-4000-8000-0000000000dd"))
        #expect(!duplicate)
        #expect(events[1] == .status(label: "Checking what’s near you…"))
        #expect(events[2] == .delta(messageId: UUID(uuidString: Self.replyId)!, text: "Chicken bowl. "))
        #expect(events[3] == .delta(messageId: UUID(uuidString: Self.replyId)!, text: "Café-style 🌯."))
        guard case .message(let reply) = events[4] else {
            Issue.record("expected message")
            return
        }
        #expect(reply.body == "Chicken bowl. Café-style 🌯.")
        #expect(events[5] == .done(runId: UUID(uuidString: Self.runId), messageIds: [UUID(uuidString: Self.replyId)!]))
    }

    @Test func chunkBoundariesAnywhereGiveTheSameEvents() {
        let expected = parseWhole(Self.stream).events
        let bytes = Array(Self.stream.utf8)
        // Every chunk size from 1 byte up splits lines and multi-byte
        // characters (é, …, 🌯) at different points.
        for chunkSize in [1, 2, 3, 5, 7, 13, 64, 257] {
            var parser = CoachSSEParser()
            var events: [CoachStreamEvent] = []
            var index = 0
            while index < bytes.count {
                let end = min(index + chunkSize, bytes.count)
                events += parser.feed(bytes[index..<end])
                index = end
            }
            events += parser.finish()
            #expect(events == expected, "chunk size \(chunkSize)")
        }
    }

    @Test func doesNotNeedBlankLinesBetweenEvents() {
        let compact = """
        data: {"type":"status","label":"One"}
        data: {"type":"status","label":"Two"}
        data:{"type":"status","label":"No space"}
        """
        let (events, _) = parseWhole(compact)
        #expect(events == [.status(label: "One"), .status(label: "Two"), .status(label: "No space")])
    }

    @Test func handlesCRLFLineEndings() {
        let text = ": keepalive\r\n\r\ndata: {\"type\":\"status\",\"label\":\"CRLF\"}\r\n\r\n"
        let (events, parser) = parseWhole(text)
        #expect(events == [.status(label: "CRLF")])
        #expect(parser.keepaliveCount == 1)
    }

    @Test func decodesErrorEvents() {
        let text = """
        data: {"type":"error","code":"model_overloaded","message":"Shudo’s swamped. Hit me again.","retryable":true}
        data: {"type":"error","code":"quota"}

        """
        let (events, _) = parseWhole(text)
        #expect(events == [
            .error(CoachStreamFailure(code: "model_overloaded", message: "Shudo’s swamped. Hit me again.", retryable: true)),
            .error(CoachStreamFailure(code: "quota", message: "Shudo couldn’t answer that.", retryable: false)),
        ])
    }

    @Test func unknownTypesAndOtherFieldsAreIgnored() {
        let text = """
        event: message
        id: 42
        retry: 1000
        data: {"type":"tool_call","name":"find_nearby_food"}
        data: {"type":"status","label":"Still here"}

        """
        let (events, parser) = parseWhole(text)
        #expect(events == [.status(label: "Still here")])
        #expect(parser.ignoredLineCount == 4)
    }

    @Test func aMalformedLineDoesNotPoisonTheNextEvent() {
        let text = """
        data: {"type":"delta","message_id":
        data: {"type":"status","label":"Recovered"}
        data: not json at all
        data: {"type":"status","label":"Again"}

        """
        let (events, _) = parseWhole(text)
        #expect(events == [.status(label: "Recovered"), .status(label: "Again")])
    }

    @Test func joinsStandardMultiLineDataFields() {
        let text = """
        data: {"type":"status",
        data: "label":"Split across lines"}

        """
        let (events, _) = parseWhole(text)
        #expect(events == [.status(label: "Split across lines")])
    }

    @Test func finishFlushesATrailingLineWithoutNewline() {
        var parser = CoachSSEParser()
        let partial = parser.feed(Array(#"data: {"type":"done","run_id":null,"message_ids":[]}"#.utf8))
        #expect(partial.isEmpty)
        #expect(parser.finish() == [.done(runId: nil, messageIds: [])])
    }

    @Test func oversizedLinesAreDroppedWithoutStoppingTheStream() {
        var parser = CoachSSEParser()
        var bytes = Array("data: ".utf8)
        bytes += Array(repeating: UInt8(ascii: "x"), count: CoachSSEParser.maximumLineBytes + 10)
        bytes.append(0x0A)
        bytes += Array("data: {\"type\":\"status\",\"label\":\"After\"}\n".utf8)
        let events = parser.feed(bytes)
        #expect(events == [.status(label: "After")])
    }
}
