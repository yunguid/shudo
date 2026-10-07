import Foundation

// MARK: - Contract

/// Everything the app needs from the coach backend (SPEC §5.1). The live
/// implementation talks to `coach_chat` / `coach_sync` and PostgREST; DEBUG
/// builds also ship `FakeCoachService` with scripted streams.
protocol CoachServing: Sendable {
    /// Sends one chat turn and streams its events. Server-side the run is
    /// detached, so cancelling the stream never loses the turn; resending the
    /// same `clientRequestId` replays (complete) or tails (running) it.
    func send(_ request: CoachSendRequest) -> AsyncThrowingStream<CoachStreamEvent, Error>
    /// Applies a card button (Apply / Undo / Activate …); returns changed rows.
    func act(on action: CoachCardAction) async throws -> [CoachMessage]
    /// Visible rows for one local day (`status <> superseded`, delivered).
    func fetchDay(_ localDay: String) async throws -> [CoachMessage]
    /// Rows changed after `cursor` (`updated_at > cursor`), oldest first. A nil
    /// cursor returns the recent window (last 48 h of deliveries + future).
    func fetchChanges(since cursor: Date?) async throws -> [CoachMessage]
    func markRead(_ ids: [UUID]) async throws
    func sync(_ request: CoachSyncRequest) async throws -> CoachSyncResponse
    func fetchMemory() async throws -> CoachMemoryDocument

    // Lane I2 additions.
    /// Delivered, unread coach rows across all days (badge source).
    func fetchUnreadCount() async throws -> Int
    func fetchSettings() async throws -> CoachSettings
    func updateSettings(_ settings: CoachSettings) async throws -> CoachSettings
    /// Uploads a chat photo to `coach-media/<uid>/<day>/chat-<uuid>.jpg` and
    /// returns the object path for `CoachSendRequest.attachmentPath`.
    func uploadAttachment(jpeg: Data, localDay: String) async throws -> String
}

enum CoachServiceError: LocalizedError, Equatable {
    case notAuthenticated
    case invalidRequest(String)
    case invalidResponse
    case server(statusCode: Int, code: String?, message: String)
    /// The event stream closed before a `done` or `error` event.
    case streamEndedEarly

    var isRetryable: Bool {
        switch self {
        case .server(let status, _, _):
            return status == 408 || status == 425 || status == 429 || status >= 500
        case .streamEndedEarly, .invalidResponse:
            return true
        case .notAuthenticated, .invalidRequest:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Sign in again to talk to Shudo."
        case .invalidRequest(let message): return message
        case .invalidResponse: return "Shudo sent back something unexpected."
        case .server(_, _, let message): return message
        case .streamEndedEarly: return "The connection dropped before Shudo finished."
        }
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let error = error as? CoachServiceError { return error.isRetryable }
        if let failure = error as? CoachStreamFailure { return failure.retryable }
        if let urlError = error as? URLError { return urlError.code != .cancelled }
        if error is CancellationError { return false }
        return true
    }
}

// MARK: - SSE parsing

/// Parses the `coach_chat` event stream. Each event is ONE `data: {json}`
/// line; blank lines are optional (`AsyncBytes.lines` can drop them), `:`
/// lines are keepalives, and other SSE fields are ignored. Bytes are split
/// on `\n` only, so multi-byte UTF-8 survives arbitrary chunk boundaries.
struct CoachSSEParser {
    static let maximumLineBytes = 1_048_576

    private(set) var keepaliveCount = 0
    private(set) var ignoredLineCount = 0
    private var lineBuffer: [UInt8] = []
    private var lineOverflowed = false
    /// Unparseable `data:` lines held in case the server split one JSON
    /// value across several `data:` lines (standard SSE framing).
    private var pendingData: [String] = []
    private var pendingBytes = 0

    init() {
        lineBuffer.reserveCapacity(1024)
    }

    /// Feeds one byte; returns an event when it completes a line that holds one.
    mutating func feed(byte: UInt8) -> CoachStreamEvent? {
        if byte == 0x0A {
            defer {
                lineBuffer.removeAll(keepingCapacity: true)
                lineOverflowed = false
            }
            guard !lineOverflowed else {
                ignoredLineCount += 1
                return nil
            }
            return consumeLineBytes(lineBuffer)
        }
        guard !lineOverflowed else { return nil }
        if lineBuffer.count >= Self.maximumLineBytes {
            lineOverflowed = true
            lineBuffer.removeAll(keepingCapacity: true)
            return nil
        }
        lineBuffer.append(byte)
        return nil
    }

    mutating func feed<S: Sequence>(_ bytes: S) -> [CoachStreamEvent] where S.Element == UInt8 {
        var events: [CoachStreamEvent] = []
        for byte in bytes {
            if let event = feed(byte: byte) { events.append(event) }
        }
        return events
    }

    /// Flushes a trailing line that never got its newline.
    mutating func finish() -> [CoachStreamEvent] {
        var events: [CoachStreamEvent] = []
        if !lineBuffer.isEmpty, !lineOverflowed, let event = consumeLineBytes(lineBuffer) {
            events.append(event)
        }
        lineBuffer.removeAll()
        lineOverflowed = false
        clearPending()
        return events
    }

    mutating func consume(line rawLine: String) -> CoachStreamEvent? {
        var line = Substring(rawLine)
        if line.hasSuffix("\r") { line = line.dropLast() }
        if line.isEmpty {
            // End of a (possibly multi-line) event; anything still pending
            // never became valid JSON.
            if !pendingData.isEmpty { ignoredLineCount += 1 }
            clearPending()
            return nil
        }
        if line.hasPrefix(":") {
            keepaliveCount += 1
            return nil
        }
        guard line.hasPrefix("data:") else {
            ignoredLineCount += 1
            return nil
        }
        var value = line.dropFirst(5)
        if value.hasPrefix(" ") { value = value.dropFirst() }

        // A line that is complete JSON on its own always wins, so one stray
        // malformed line can never poison the events after it.
        switch Self.decode(String(value)) {
        case .event(let event):
            clearPending()
            return event
        case .ignored:
            clearPending()
            ignoredLineCount += 1
            return nil
        case .incomplete:
            break
        }

        pendingData.append(String(value))
        pendingBytes += value.utf8.count
        guard pendingData.count > 1 else { return nil }
        switch Self.decode(pendingData.joined(separator: "\n")) {
        case .event(let event):
            clearPending()
            return event
        case .ignored:
            clearPending()
            ignoredLineCount += 1
            return nil
        case .incomplete:
            if pendingBytes > Self.maximumLineBytes {
                clearPending()
                ignoredLineCount += 1
            }
            return nil
        }
    }

    enum DecodeResult: Equatable {
        case event(CoachStreamEvent)
        /// Valid JSON, but not an event this build understands.
        case ignored
        /// Not (yet) valid JSON.
        case incomplete
    }

    static func decode(_ json: String) -> DecodeResult {
        let data = Data(json.utf8)
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return .incomplete }
        guard let event = try? JSONDecoder().decode(CoachStreamEvent.self, from: data) else {
            return .ignored
        }
        return .event(event)
    }

    private mutating func consumeLineBytes(_ bytes: [UInt8]) -> CoachStreamEvent? {
        consume(line: String(decoding: bytes, as: UTF8.self))
    }

    private mutating func clearPending() {
        pendingData.removeAll()
        pendingBytes = 0
    }
}

// MARK: - Live service

struct CoachService: CoachServing {
    static let maximumAttachmentBytes = 6 * 1024 * 1024
    static let attachmentBucket = "coach-media"
    static let pageSize = 500

    let supabaseURL: URL
    let anonKey: String
    let session: URLSession
    let jwtProvider: @Sendable () async throws -> String
    let userIdProvider: @Sendable () -> String?
    let now: @Sendable () -> Date

    static let live = CoachService(
        jwtProvider: { try await AuthSessionManager.shared.getAccessToken() },
        userIdProvider: { AuthSessionManager.shared.userId }
    )

    init(
        supabaseURL: URL = AppConfig.supabaseURL,
        anonKey: String = AppConfig.supabaseAnonKey,
        session: URLSession = .shared,
        jwtProvider: @escaping @Sendable () async throws -> String,
        userIdProvider: @escaping @Sendable () -> String?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.supabaseURL = supabaseURL
        self.anonKey = anonKey
        self.session = session
        self.jwtProvider = jwtProvider
        self.userIdProvider = userIdProvider
        self.now = now
    }

    // MARK: Chat

    func send(_ request: CoachSendRequest) -> AsyncThrowingStream<CoachStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamTurn(request, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamTurn(
        _ request: CoachSendRequest,
        into continuation: AsyncThrowingStream<CoachStreamEvent, Error>.Continuation
    ) async throws {
        let jwt = try await jwtProvider()
        let urlRequest = try makeSendRequest(request, jwt: jwt)
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw CoachServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 65_536 { break }
            }
            throw Self.serverError(
                statusCode: http.statusCode,
                data: body,
                fallback: "Shudo couldn’t take that message."
            )
        }

        var parser = CoachSSEParser()
        var sawTerminal = false
        for try await byte in bytes {
            guard let event = parser.feed(byte: byte) else { continue }
            continuation.yield(event)
            if case .done = event {
                sawTerminal = true
                break
            }
            if case .error = event { sawTerminal = true }
        }
        if !sawTerminal {
            for event in parser.finish() {
                continuation.yield(event)
                switch event {
                case .done, .error: sawTerminal = true
                default: break
                }
            }
        }
        guard sawTerminal else { throw CoachServiceError.streamEndedEarly }
    }

    func makeSendRequest(_ request: CoachSendRequest, jwt: String) throws -> URLRequest {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || request.attachmentPath != nil else {
            throw CoachServiceError.invalidRequest("Say something first.")
        }
        guard text.count <= CoachSendRequest.maximumTextLength else {
            throw CoachServiceError.invalidRequest("That’s too long for one message. Trim it a little.")
        }
        guard CoachLocalDay.isValid(request.localDay) else {
            throw CoachServiceError.invalidRequest("The message day is invalid.")
        }
        var normalized = request
        normalized.text = text
        var urlRequest = functionRequest("coach_chat", jwt: jwt, timeout: 150)
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(normalized)
        return urlRequest
    }

    func act(on action: CoachCardAction) async throws -> [CoachMessage] {
        let jwt = try await jwtProvider()
        var request = functionRequest("coach_chat", jwt: jwt, timeout: 60)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(action)
        let data = try await perform(request, fallback: "That didn’t go through. Try again.")
        return try Self.parseActionResponse(data)
    }

    static func parseActionResponse(_ data: Data) throws -> [CoachMessage] {
        struct Envelope: Decodable {
            let messages: [CoachLenient<CoachMessage>]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            throw CoachServiceError.invalidResponse
        }
        return envelope.messages.compactMap(\.value)
    }

    // MARK: Thread reads

    func fetchDay(_ localDay: String) async throws -> [CoachMessage] {
        guard CoachLocalDay.isValid(localDay) else {
            throw CoachServiceError.invalidRequest("The day is invalid.")
        }
        var query = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "local_day", value: "eq.\(localDay)"),
            URLQueryItem(name: "status", value: "neq.superseded"),
            URLQueryItem(name: "deliver_at", value: "lte.\(CoachDateCoding.string(from: now()))"),
            URLQueryItem(name: "order", value: "deliver_at.asc,created_at.asc,id.asc"),
            URLQueryItem(name: "limit", value: String(Self.pageSize)),
        ]
        if let userId = userIdProvider() {
            query.append(URLQueryItem(name: "user_id", value: "eq.\(userId)"))
        }
        let request = try await restRequest("coach_messages", query: query)
        let data = try await perform(request, fallback: "Couldn’t load the thread.")
        return try Self.parseMessages(data)
    }

    func fetchChanges(since cursor: Date?) async throws -> [CoachMessage] {
        var all: [CoachMessage] = []
        var seen = Set<UUID>()
        for page in 0..<4 {
            var query = [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "order", value: "updated_at.asc,id.asc"),
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
                URLQueryItem(name: "offset", value: String(page * Self.pageSize)),
            ]
            if let cursor {
                query.append(URLQueryItem(
                    name: "updated_at",
                    value: "gt.\(CoachDateCoding.string(from: cursor))"
                ))
            } else {
                let windowStart = now().addingTimeInterval(-48 * 3600)
                query.append(URLQueryItem(
                    name: "deliver_at",
                    value: "gte.\(CoachDateCoding.string(from: windowStart))"
                ))
            }
            if let userId = userIdProvider() {
                query.append(URLQueryItem(name: "user_id", value: "eq.\(userId)"))
            }
            let request = try await restRequest("coach_messages", query: query)
            let data = try await perform(request, fallback: "Couldn’t sync Shudo’s messages.")
            let rows = try Self.parseMessages(data)
            for row in rows where seen.insert(row.id).inserted { all.append(row) }
            if rows.count < Self.pageSize { break }
        }
        return all
    }

    func markRead(_ ids: [UUID]) async throws {
        let unique = Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
        guard !unique.isEmpty else { return }
        let readAt = CoachDateCoding.string(from: now())
        for start in stride(from: 0, to: unique.count, by: 50) {
            let chunk = unique[start..<min(start + 50, unique.count)]
            let list = chunk.map { $0.uuidString.lowercased() }.joined(separator: ",")
            var request = try await restRequest(
                "coach_messages",
                query: [
                    URLQueryItem(name: "id", value: "in.(\(list))"),
                    URLQueryItem(name: "read_at", value: "is.null"),
                ],
                method: "PATCH"
            )
            request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["read_at": readAt])
            _ = try await perform(request, fallback: "Couldn’t mark messages read.")
        }
    }

    func fetchUnreadCount() async throws -> Int {
        var query = [
            URLQueryItem(name: "select", value: "id"),
            URLQueryItem(name: "role", value: "eq.coach"),
            URLQueryItem(name: "read_at", value: "is.null"),
            URLQueryItem(name: "status", value: "neq.superseded"),
            URLQueryItem(name: "deliver_at", value: "lte.\(CoachDateCoding.string(from: now()))"),
            URLQueryItem(name: "limit", value: "100"),
        ]
        if let userId = userIdProvider() {
            query.append(URLQueryItem(name: "user_id", value: "eq.\(userId)"))
        }
        let request = try await restRequest("coach_messages", query: query)
        let data = try await perform(request, fallback: "Couldn’t count unread messages.")
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw CoachServiceError.invalidResponse
        }
        return rows.count
    }

    static func parseMessages(_ data: Data) throws -> [CoachMessage] {
        guard let rows = try? JSONDecoder().decode([CoachLenient<CoachMessage>].self, from: data) else {
            throw CoachServiceError.invalidResponse
        }
        return rows.compactMap(\.value)
    }

    // MARK: Sync, memory, settings

    func sync(_ request: CoachSyncRequest) async throws -> CoachSyncResponse {
        let jwt = try await jwtProvider()
        var urlRequest = functionRequest("coach_sync", jwt: jwt, timeout: 40)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        let data = try await perform(urlRequest, fallback: "Couldn’t reach Shudo.")
        guard let response = try? JSONDecoder().decode(CoachSyncResponse.self, from: data) else {
            throw CoachServiceError.invalidResponse
        }
        return response
    }

    func fetchMemory() async throws -> CoachMemoryDocument {
        guard let userId = userIdProvider() else { throw CoachServiceError.notAuthenticated }
        let request = try await restRequest("coach_memory", query: [
            URLQueryItem(name: "select", value: "version,document,sections,updated_source,updated_at"),
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "limit", value: "1"),
        ])
        let data = try await perform(request, fallback: "Couldn’t load your bio.")
        guard let rows = try? JSONDecoder().decode([CoachMemoryDocument].self, from: data) else {
            throw CoachServiceError.invalidResponse
        }
        return rows.first ?? .empty
    }

    func fetchSettings() async throws -> CoachSettings {
        guard let userId = userIdProvider() else { throw CoachServiceError.notAuthenticated }
        let request = try await restRequest("profiles", query: [
            URLQueryItem(name: "select", value: CoachSettings.profileColumns),
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
        ])
        let data = try await perform(request, fallback: "Couldn’t load coach settings.")
        guard let rows = try? JSONDecoder().decode([CoachSettings].self, from: data),
              let settings = rows.first else {
            throw CoachServiceError.invalidResponse
        }
        return settings
    }

    func updateSettings(_ settings: CoachSettings) async throws -> CoachSettings {
        guard let userId = userIdProvider() else { throw CoachServiceError.notAuthenticated }
        guard settings.quietHoursStart != settings.quietHoursEnd else {
            throw CoachServiceError.invalidRequest("Quiet hours need a different start and end.")
        }
        var request = try await restRequest(
            "profiles",
            query: [
                URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                URLQueryItem(name: "select", value: CoachSettings.profileColumns),
            ],
            method: "PATCH"
        )
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(settings)
        let data = try await perform(request, fallback: "Couldn’t save coach settings.")
        guard let rows = try? JSONDecoder().decode([CoachSettings].self, from: data),
              let saved = rows.first else {
            throw CoachServiceError.invalidResponse
        }
        return saved
    }

    // MARK: Attachments

    static func attachmentPath(userId: String, localDay: String, fileId: UUID = UUID()) throws -> String {
        guard let owner = UUID(uuidString: userId), CoachLocalDay.isValid(localDay) else {
            throw CoachServiceError.invalidRequest("The photo path is invalid.")
        }
        return "\(owner.uuidString.lowercased())/\(localDay)/chat-\(fileId.uuidString.lowercased()).jpg"
    }

    static func isJPEG(_ data: Data) -> Bool {
        data.count >= 4 && data.starts(with: [0xFF, 0xD8]) && data.suffix(2).elementsEqual([0xFF, 0xD9])
    }

    func uploadAttachment(jpeg: Data, localDay: String) async throws -> String {
        guard jpeg.count <= Self.maximumAttachmentBytes, Self.isJPEG(jpeg) else {
            throw CoachServiceError.invalidRequest("Photos must be JPEGs under 6 MB.")
        }
        guard let userId = userIdProvider() else { throw CoachServiceError.notAuthenticated }
        let path = try Self.attachmentPath(userId: userId, localDay: localDay)
        let jwt = try await jwtProvider()
        let url = supabaseURL
            .appendingPathComponent("storage/v1/object")
            .appendingPathComponent(Self.attachmentBucket)
            .appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        request.httpBody = jpeg
        _ = try await perform(request, fallback: "Couldn’t upload that photo.")
        return path
    }

    // MARK: Plumbing

    private func functionRequest(_ name: String, jwt: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: supabaseURL.appendingPathComponent("functions/v1/\(name)"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        return request
    }

    func restURL(_ table: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(
            url: supabaseURL.appendingPathComponent("rest/v1/\(table)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = query
        // `+` is legal in a query but PostgREST would read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private func restRequest(
        _ table: String,
        query: [URLQueryItem],
        method: String = "GET"
    ) async throws -> URLRequest {
        let jwt = try await jwtProvider()
        var request = URLRequest(url: restURL(table, query: query))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform(_ request: URLRequest, fallback: String) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CoachServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.serverError(statusCode: http.statusCode, data: data, fallback: fallback)
        }
        return data
    }

    /// Edge Functions answer `{"error": "...", "code": "..."}`; PostgREST
    /// answers `{"message": "...", "code": "..."}`.
    static func serverError(statusCode: Int, data: Data, fallback: String) -> CoachServiceError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = object?["code"] as? String
        let rawMessage = (object?["error"] as? String) ?? (object?["message"] as? String)
        let message: String
        if statusCode == 401 || statusCode == 403 {
            message = "Sign in again to talk to Shudo."
        } else if let rawMessage, !rawMessage.isEmpty, rawMessage.count <= 240 {
            message = rawMessage
        } else {
            message = fallback
        }
        return .server(statusCode: statusCode, code: code, message: message)
    }
}

// MARK: - Fake (DEBUG)

#if DEBUG
/// Scripted in-memory coach for previews, UI tests and unit tests. It
/// behaves like the database: accepted user rows and streamed coach rows are
/// stored, so `fetchDay` after a send returns them, and a resend with the
/// same `client_request_id` replays the finished turn.
final class FakeCoachService: CoachServing, @unchecked Sendable {
    enum Step: Sendable {
        case event(CoachStreamEvent)
        case pause(milliseconds: Int)
        case fail(CoachServiceError)
    }

    struct TurnContext: Sendable {
        let now: Date
        let runId: UUID
        let replyId: UUID
        let userMessage: CoachMessage
    }

    typealias Script = @Sendable (CoachSendRequest, TurnContext) -> [Step]

    private let lock = NSLock()
    private var stored: [UUID: CoachMessage]
    private var completedTurns: [UUID: [CoachMessage]] = [:]
    private var queuedOverrides: [[Step]] = []
    private var _sentRequests: [CoachSendRequest] = []
    private var _actions: [CoachCardAction] = []
    private var _markedRead: [UUID] = []
    private var _syncRequests: [CoachSyncRequest] = []
    private var _uploads: [String] = []
    private var _memory: CoachMemoryDocument
    private var _settings: CoachSettings
    private var _fetchDayError: Error?
    private var _script: Script
    private let clock: @Sendable () -> Date
    /// Added between scripted steps (PolishPreview uses ~90 ms for realism).
    let stepDelayMilliseconds: Int

    init(
        messages: [CoachMessage] = [],
        memory: CoachMemoryDocument = .empty,
        settings: CoachSettings = .defaults,
        stepDelayMilliseconds: Int = 0,
        now: @escaping @Sendable () -> Date = { Date() },
        script: Script? = nil
    ) {
        stored = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        _memory = memory
        _settings = settings
        self.stepDelayMilliseconds = stepDelayMilliseconds
        clock = now
        _script = script ?? Self.replyScript(
            reply: ["Copy that. ", "Protein first, ", "then we talk dessert."],
            statusLabel: "Checking your day…"
        )
    }

    // MARK: Inspection

    var sentRequests: [CoachSendRequest] { lock.withLock { _sentRequests } }
    var actions: [CoachCardAction] { lock.withLock { _actions } }
    var markedReadIds: [UUID] { lock.withLock { _markedRead } }
    var syncRequests: [CoachSyncRequest] { lock.withLock { _syncRequests } }
    var uploadedPaths: [String] { lock.withLock { _uploads } }
    var allMessages: [CoachMessage] {
        lock.withLock { CoachThreadOrdering.sorted(Array(stored.values)) }
    }

    // MARK: Scripting

    var script: Script {
        get { lock.withLock { _script } }
        set { lock.withLock { _script = newValue } }
    }

    /// The next `send` uses these steps instead of the script (FIFO).
    func enqueueOverride(_ steps: [Step]) {
        lock.withLock { queuedOverrides.append(steps) }
    }

    func setFetchDayError(_ error: Error?) {
        lock.withLock { _fetchDayError = error }
    }

    func insert(_ message: CoachMessage) {
        lock.withLock { stored[message.id] = message }
    }

    /// accepted → status → deltas → final message → optional card → done.
    static func replyScript(
        reply: [String],
        statusLabel: String? = nil,
        card: (@Sendable (TurnContext) -> CoachMessage)? = nil
    ) -> Script {
        { request, context in
            var steps: [Step] = [
                .event(.accepted(runId: context.runId, userMessage: context.userMessage, duplicate: false)),
            ]
            if let statusLabel { steps.append(.event(.status(label: statusLabel))) }
            for chunk in reply {
                steps.append(.event(.delta(messageId: context.replyId, text: chunk)))
            }
            let final = CoachMessage(
                id: context.replyId,
                role: .coach,
                kind: "text",
                body: reply.joined(),
                localDay: request.localDay,
                deliverAt: context.now,
                replyToId: context.userMessage.id
            )
            steps.append(.event(.message(final)))
            var ids = [context.replyId]
            if let card {
                let cardMessage = card(context)
                steps.append(.event(.message(cardMessage)))
                ids.append(cardMessage.id)
            }
            steps.append(.event(.done(runId: context.runId, messageIds: ids)))
            return steps
        }
    }

    // MARK: CoachServing

    func send(_ request: CoachSendRequest) -> AsyncThrowingStream<CoachStreamEvent, Error> {
        let now = clock()
        let steps: [Step] = lock.withLock {
            _sentRequests.append(request)
            if let replay = completedTurns[request.clientRequestId] {
                let user = replay.first { $0.role == .user }
                var steps: [Step] = [
                    .event(.accepted(runId: UUID(), userMessage: user, duplicate: true)),
                ]
                steps += replay.filter { $0.role != .user }.map { .event(.message($0)) }
                steps.append(.event(.done(
                    runId: nil,
                    messageIds: replay.filter { $0.role != .user }.map(\.id)
                )))
                return steps
            }
            if !queuedOverrides.isEmpty { return queuedOverrides.removeFirst() }
            let user = CoachMessage(
                role: .user,
                kind: request.attachmentPath == nil ? "text" : "photo",
                body: request.text,
                localDay: request.localDay,
                deliverAt: now,
                attachmentPath: request.attachmentPath,
                clientRequestId: request.clientRequestId
            )
            return _script(
                request,
                TurnContext(now: now, runId: UUID(), replyId: UUID(), userMessage: user)
            )
        }
        let delay = stepDelayMilliseconds
        return AsyncThrowingStream { continuation in
            let task = Task {
                var turnMessages: [CoachMessage] = []
                for step in steps {
                    if Task.isCancelled { break }
                    if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
                    switch step {
                    case .pause(let milliseconds):
                        try? await Task.sleep(nanoseconds: UInt64(max(0, milliseconds)) * 1_000_000)
                    case .fail(let error):
                        continuation.finish(throwing: error)
                        return
                    case .event(let event):
                        self.record(event, request: request, turnMessages: &turnMessages)
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func record(
        _ event: CoachStreamEvent,
        request: CoachSendRequest,
        turnMessages: inout [CoachMessage]
    ) {
        lock.withLock {
            switch event {
            case .accepted(_, let user, let duplicate):
                guard !duplicate, let user else { return }
                stored[user.id] = user
                turnMessages.append(user)
            case .delta(let id, let text):
                var message = stored[id] ?? CoachMessage(
                    id: id,
                    role: .coach,
                    kind: "text",
                    body: "",
                    rawPayload: .object(["streaming": .bool(true)]),
                    localDay: request.localDay,
                    deliverAt: clock()
                )
                message.body += text
                message.isStreaming = true
                stored[id] = message
            case .message(let message):
                stored[message.id] = message
                turnMessages.removeAll { $0.id == message.id }
                turnMessages.append(message)
            case .done:
                completedTurns[request.clientRequestId] = turnMessages
            case .status, .error:
                break
            }
        }
    }

    func act(on action: CoachCardAction) async throws -> [CoachMessage] {
        lock.withLock {
            _actions.append(action)
            var updated: [CoachMessage] = []
            for (id, message) in stored {
                var raw = message.rawPayload.objectValue ?? [:]
                switch (message.payload, action.kind) {
                case (.goalChange(let card), .goalChange) where card.changeId == action.id:
                    raw["status"] = .string(action.decision == .undo ? "undone"
                        : action.decision == .discard ? "discarded" : "applied")
                case (.trainingPlan(let card), .trainingPlan) where card.planId == action.id:
                    raw["status"] = .string(action.decision == .discard ? "rejected" : "active")
                case (.profileUpdate, .bioUpdate) where message.id == action.id:
                    raw["status"] = .string(action.decision == .undo ? "undone" : "applied")
                default:
                    continue
                }
                let changed = CoachMessage(
                    id: message.id,
                    role: message.role,
                    kind: message.kind,
                    body: message.body,
                    rawPayload: .object(raw),
                    localDay: message.localDay,
                    deliverAt: message.deliverAt,
                    status: message.status,
                    notify: message.notify,
                    readAt: message.readAt,
                    createdAt: message.createdAt,
                    updatedAt: clock()
                )
                stored[id] = changed
                updated.append(changed)
            }
            return updated
        }
    }

    func fetchDay(_ localDay: String) async throws -> [CoachMessage] {
        let now = clock()
        return try lock.withLock {
            if let error = _fetchDayError { throw error }
            return CoachThreadOrdering.sorted(
                stored.values.filter { $0.localDay == localDay && $0.isVisible(at: now) }
            )
        }
    }

    func fetchChanges(since cursor: Date?) async throws -> [CoachMessage] {
        lock.withLock {
            stored.values
                .filter { cursor == nil || $0.updatedAt > cursor! }
                .sorted { ($0.updatedAt, $0.id.uuidString) < ($1.updatedAt, $1.id.uuidString) }
        }
    }

    func markRead(_ ids: [UUID]) async throws {
        let now = clock()
        lock.withLock {
            _markedRead.append(contentsOf: ids)
            for id in ids where stored[id]?.readAt == nil {
                stored[id]?.readAt = now
                stored[id]?.updatedAt = now
            }
        }
    }

    func sync(_ request: CoachSyncRequest) async throws -> CoachSyncResponse {
        let now = clock()
        lock.withLock { _syncRequests.append(request) }
        return CoachSyncResponse(planRunId: nil, generated: false, serverTime: now)
    }

    func fetchMemory() async throws -> CoachMemoryDocument {
        lock.withLock { _memory }
    }

    func fetchUnreadCount() async throws -> Int {
        let now = clock()
        return lock.withLock { stored.values.filter { $0.isUnread(at: now) }.count }
    }

    func fetchSettings() async throws -> CoachSettings {
        lock.withLock { _settings }
    }

    func updateSettings(_ settings: CoachSettings) async throws -> CoachSettings {
        lock.withLock {
            _settings = settings
            return settings
        }
    }

    func uploadAttachment(jpeg: Data, localDay: String) async throws -> String {
        let path = "00000000-0000-0000-0000-000000000000/\(localDay)/chat-\(UUID().uuidString.lowercased()).jpg"
        lock.withLock { _uploads.append(path) }
        return path
    }

    /// A seeded fake for PolishPreview: a full day with every card kind and
    /// a ~90 ms step delay so the typing → streaming → card flow is visible.
    static func polishPreview(localDay: String, now: Date = Date()) -> FakeCoachService {
        FakeCoachService(
            messages: CoachFixtures.day(localDay, now: now),
            memory: CoachFixtures.memory,
            settings: CoachSettings.defaults,
            stepDelayMilliseconds: 90,
            script: replyScript(
                reply: [
                    "Copy that. ", "You’re 62 g of protein short ", "with about 900 kcal left. ",
                    "There’s a 7-Eleven four minutes out. Here’s the play.",
                ],
                statusLabel: "Checking what’s near you…",
                card: { context in
                    CoachFixtures.snackRec(localDay: context.userMessage.localDay, at: context.now)
                }
            )
        )
    }
}

/// Fixture rows covering every card kind (previews and tests).
enum CoachFixtures {
    static let memory = CoachMemoryDocument(
        version: 3,
        document: "# Luke\n\nLean bulk 162.5 → 175 lb.",
        bio: CoachMemoryDocument.bioSections([
            "about": .string("Software engineer in New York. Lifts four days a week."),
            "goals": .string("Lean bulk from 162.5 to 175 lb without losing his abs."),
            "schedule": .string("Office Tue–Thu, lifts after work around 6:15."),
        ]),
        notes: ["protein": "Misses protein on office days."],
        schedule: CoachSchedule(wake: "07:00", officeStart: "09:30", liftDays: ["mon", "wed", "fri", "sat"], liftTime: "18:15"),
        equipment: ["commercial gym"],
        updatedSource: "coach_reply",
        updatedAt: nil
    )

    static func snackRec(localDay: String, at date: Date) -> CoachMessage {
        let card = SnackRec(
            headline: "Grab a Chobani and a Core Power",
            verdict: .grab,
            options: [
                SnackRec.Option(
                    storeRef: "p3f9a1c2b7d",
                    storeName: "7-Eleven",
                    walkMinutes: 4,
                    items: [
                        SnackRec.Item(name: "Chobani Complete vanilla", brand: "Chobani", serving: "10 oz bottle", caloriesKcal: 180, proteinG: 25, carbsG: 14, fatG: 3, priceUsdEst: 3.79, nutritionSource: "web"),
                        SnackRec.Item(name: "Core Power Elite", brand: "Fairlife", serving: "14 oz bottle", caloriesKcal: 230, proteinG: 42, carbsG: 8, fatG: 4.5, nutritionSource: "label_known"),
                    ],
                    combined: CoachMacros(caloriesKcal: 410, proteinG: 67, carbsG: 22, fatG: 7.5),
                    remainingAfter: CoachMacros(caloriesKcal: 490, proteinG: 0, carbsG: 88, fatG: 20),
                    mapsQuery: "7-Eleven 2nd Ave"
                ),
            ],
            sources: ["https://www.chobani.com"]
        )
        return CoachMessage(
            role: .coach,
            kind: CoachMessageKind.snackRec.rawValue,
            body: "Here’s the play.",
            rawPayload: CoachJSON(encoding: card),
            localDay: localDay,
            deliverAt: date
        )
    }

    static func day(_ localDay: String, now: Date) -> [CoachMessage] {
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        let plan = PlanCard(
            theme: "Protein early",
            remaining: CoachMacros(caloriesKcal: 2850, proteinG: 170, carbsG: 330, fatG: 85),
            actions: ["40 g protein by 10", "Lift at 6:15", "Lights out 11"]
        )
        let goal = GoalChangeCard(
            changeId: UUID(),
            status: .needsConfirmation,
            before: GoalSnapshot(caloriesKcal: 2450, proteinG: 150, carbsG: 280, fatG: 75, goalType: "maintain", targetWeightKg: 73.7),
            after: GoalSnapshot(caloriesKcal: 2850, proteinG: 170, carbsG: 330, fatG: 85, goalType: "gain", targetWeightKg: 79.4, goalDate: "2027-05-01"),
            projectedGoalDate: "2027-05-01",
            warnings: []
        )
        let training = TrainingPlanCard(
            planId: UUID(),
            status: .draft,
            name: "Upper/Lower 4x",
            sessionsPerWeek: 4,
            summary: "Two upper, two lower. Bench and squat twice a week.",
            sessions: [
                .init(id: "upper_a", name: "Upper A", estMinutes: 60, topExercises: ["Bench press", "Barbell row"]),
                .init(id: "lower_a", name: "Lower A", estMinutes: 55, topExercises: ["Back squat", "RDL"]),
            ]
        )
        let profile = ProfileUpdateCard(
            memoryVersion: 4,
            changes: [.init(section: "schedule", op: .replace, summary: "Lifts after work at 6:15")],
            undoVersion: 3
        )
        let workout = WorkoutAckCard(
            activityId: UUID(),
            prs: [.init(exercise: "Bench press", kind: .e1rm, value: 215, unit: "lb", previous: 205)]
        )
        let checkIn = CheckInCard(kind: .weighInAck, localDay: localDay, weightKg: 74.2)
        let recap = RecapCard(period: .day, kcal: 2710, proteinG: 164, kcalTarget: 2850, proteinTargetG: 170, headline: "Solid day", score: 86)
        let userId = UUID()
        return [
            CoachMessage(role: .coach, kind: "plan", body: "Morning. Protein early today, lift at 6:15.", rawPayload: CoachJSON(encoding: plan), localDay: localDay, deliverAt: at(600)),
            CoachMessage(role: .coach, kind: "meal_ack", body: "Eggs and oats. Good start.", rawPayload: .object(["entry_id": .string(UUID().uuidString)]), localDay: localDay, deliverAt: at(520)),
            CoachMessage(id: userId, role: .user, kind: "text", body: "I want to get back to 175, lean bulk.", localDay: localDay, deliverAt: at(400), clientRequestId: UUID()),
            CoachMessage(role: .coach, kind: "goal_change", body: "That’s a real bump. Confirm and I’ll set it.", rawPayload: CoachJSON(encoding: goal), localDay: localDay, deliverAt: at(399), replyToId: userId),
            CoachMessage(role: .coach, kind: "profile_update", body: "Noted your schedule.", rawPayload: CoachJSON(encoding: profile), localDay: localDay, deliverAt: at(398)),
            CoachMessage(role: .coach, kind: "checkpoint", body: "Lunch check. You’re light on protein.", localDay: localDay, deliverAt: at(300), slotKey: "lunch"),
            snackRec(localDay: localDay, at: at(200)),
            CoachMessage(role: .coach, kind: "training_plan", body: "Your plan is ready.", rawPayload: CoachJSON(encoding: training), localDay: localDay, deliverAt: at(150)),
            CoachMessage(role: .coach, kind: "workout_ack", body: "New bench PR. That’s the stuff.", rawPayload: CoachJSON(encoding: workout), localDay: localDay, deliverAt: at(90)),
            CoachMessage(role: .coach, kind: "weigh_in_ack", body: "74.2 kg logged. Trend is moving.", rawPayload: CoachJSON(encoding: checkIn), localDay: localDay, deliverAt: at(60)),
            CoachMessage(role: .coach, kind: "recap", body: "Solid day. Bed by 11.", rawPayload: CoachJSON(encoding: recap), localDay: localDay, deliverAt: at(10), slotKey: "wind_down"),
        ]
    }
}
#endif

// MARK: - Ordering

enum CoachThreadOrdering {
    /// Chronological by delivery, then creation, then id (stable).
    static func sorted(_ messages: [CoachMessage]) -> [CoachMessage] {
        messages.sorted(by: precedes)
    }

    static func precedes(_ lhs: CoachMessage, _ rhs: CoachMessage) -> Bool {
        if lhs.deliverAt != rhs.deliverAt { return lhs.deliverAt < rhs.deliverAt }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        if lhs.role != rhs.role { return lhs.role == .user }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
