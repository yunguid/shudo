import Foundation

// MARK: - Train data access
//
// Activities and training plans are read through PostgREST (RLS select-own).
// Workouts are written only by the `log_activity` edge function (multipart,
// idempotent on client_request_id). Plan activation is a coach_chat card
// action. Everything the Train UI and the activity logger need goes through
// `TrainServing`, so previews and tests can swap in fakes.

struct ActivityLogRequest: Equatable, Sendable {
    var clientRequestId: UUID
    var localDay: String
    var timezone: String
    var text: String
    var speechEngine: String?
    var occurredAt: Date?
    var planSessionId: String?
    var imageJPEG: Data?
    /// Lift/Cardio/Walk chip. The server may ignore it; it only steers the
    /// analysis when the text alone is ambiguous.
    var kindHint: ActivityKind?

    init(
        clientRequestId: UUID = UUID(),
        localDay: String,
        timezone: String,
        text: String,
        speechEngine: String? = nil,
        occurredAt: Date? = nil,
        planSessionId: String? = nil,
        imageJPEG: Data? = nil,
        kindHint: ActivityKind? = nil
    ) {
        self.clientRequestId = clientRequestId
        self.localDay = localDay
        self.timezone = timezone
        self.text = text
        self.speechEngine = speechEngine
        self.occurredAt = occurredAt
        self.planSessionId = planSessionId
        self.imageJPEG = imageJPEG
        self.kindHint = kindHint
    }
}

struct ActivityLogResult: Equatable, Sendable {
    var activityId: UUID
    var status: ActivityStatus
    var duplicate: Bool
}

enum TrainServiceError: LocalizedError, Equatable {
    case invalidRequest(String)
    case server(statusCode: Int, message: String)
    case invalidResponse
    case stillProcessing

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): return message
        case .server(_, let message): return message
        case .invalidResponse: return "The server returned an unexpected response."
        case .stillProcessing: return "Shudo is still reading that workout. Try again in a moment."
        }
    }
}

protocol TrainServing: Sendable {
    /// Activities with `local_day` in [from, through] (through nil = open),
    /// newest first.
    func fetchActivities(fromLocalDay: String, throughLocalDay: String?, limit: Int) async throws -> [Activity]
    func fetchActivity(id: UUID) async throws -> Activity?
    func fetchTrainingPlans() async throws -> TrainingPlanState
    func logActivity(_ request: ActivityLogRequest) async throws -> ActivityLogResult
    func deleteActivity(id: UUID) async throws
    func activateTrainingPlan(planId: UUID, clientRequestId: UUID) async throws
    func signedActivityImageURL(path: String) async -> URL?
}

extension TrainServing {
    func fetchActivities(localDay: String) async throws -> [Activity] {
        try await fetchActivities(fromLocalDay: localDay, throughLocalDay: localDay, limit: 100)
    }

    /// Polls one activity until it leaves `processing` (650 ms → 3 s backoff),
    /// reporting every observed row. Returns the settled row, nil if the row
    /// disappeared, or the last processing row at the timeout.
    func pollActivity(
        id: UUID,
        timeout: TimeInterval = ActivityPollingPolicy.timeout,
        onUpdate: @escaping @Sendable (Activity) async -> Void = { _ in }
    ) async throws -> Activity? {
        try await ActivityPoller.poll(
            id: id,
            timeout: timeout,
            fetch: { try await fetchActivity(id: $0) },
            onUpdate: onUpdate
        )
    }
}

enum ActivityPoller {
    static func poll(
        id: UUID,
        timeout: TimeInterval,
        fetch: @escaping @Sendable (UUID) async throws -> Activity?,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        onUpdate: @escaping @Sendable (Activity) async -> Void
    ) async throws -> Activity? {
        let deadline = now().addingTimeInterval(timeout)
        var delay = ActivityPollingPolicy.initialDelay
        var consecutiveErrors = 0
        var latest: Activity?
        while now() < deadline {
            try Task.checkCancellation()
            do {
                guard let row = try await fetch(id) else { return nil }
                consecutiveErrors = 0
                latest = row
                await onUpdate(row)
                if row.status != .processing { return row }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                consecutiveErrors += 1
                if consecutiveErrors >= ActivityPollingPolicy.maximumConsecutiveErrors { throw error }
            }
            try await sleep(delay)
            delay = ActivityPollingPolicy.nextDelay(after: delay)
        }
        return latest
    }
}

extension SupabaseService: TrainServing {
    static let activityColumns =
        "id,client_request_id,local_day,occurred_at,status,source,kind,title,duration_min,distance_km,active_kcal,avg_heart_rate,intensity,rpe,details,input_text,image_path,confidence,error_message,created_at,updated_at"
    static let trainingPlanColumns =
        "id,status,plan,rationale,change_summary,source,created_at,activated_at"
    static let maximumActivityPhotoBytes = 6_291_456
    static let maximumActivityTextLength = 4_000

    // MARK: Reads

    func fetchActivities(fromLocalDay: String, throughLocalDay: String?, limit: Int) async throws -> [Activity] {
        guard TrainCalendar.isLocalDay(fromLocalDay),
              throughLocalDay.map(TrainCalendar.isLocalDay) ?? true else {
            throw TrainServiceError.invalidRequest("Invalid day range")
        }
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        var items = [
            URLQueryItem(name: "select", value: Self.activityColumns),
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "local_day", value: "gte.\(fromLocalDay)"),
        ]
        if let throughLocalDay {
            items.append(URLQueryItem(name: "local_day", value: "lte.\(throughLocalDay)"))
        }
        items.append(URLQueryItem(name: "order", value: "occurred_at.desc,created_at.desc"))
        items.append(URLQueryItem(name: "limit", value: "\(max(1, min(limit, 1_000)))"))
        let data = try await trainGET(path: "/rest/v1/activities", items: items, jwt: jwt,
                                      failure: "Couldn’t load workouts")
        return try Self.parseActivities(data)
    }

    func fetchActivity(id: UUID) async throws -> Activity? {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        let data = try await trainGET(
            path: "/rest/v1/activities",
            items: [
                URLQueryItem(name: "select", value: Self.activityColumns),
                URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())"),
                URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                URLQueryItem(name: "limit", value: "1"),
            ],
            jwt: jwt,
            failure: "Couldn’t refresh that workout")
        return try Self.parseActivities(data).first
    }

    func fetchTrainingPlans() async throws -> TrainingPlanState {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        let data = try await trainGET(
            path: "/rest/v1/training_plans",
            items: [
                URLQueryItem(name: "select", value: Self.trainingPlanColumns),
                URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                URLQueryItem(name: "status", value: "in.(active,draft)"),
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "6"),
            ],
            jwt: jwt,
            failure: "Couldn’t load your training plan")
        return TrainingPlanState(rows: try Self.parseTrainingPlans(data))
    }

    static func parseActivities(_ data: Data) throws -> [Activity] {
        do {
            return try JSONDecoder().decode(TrainLossyArray<Activity>.self, from: data).elements
        } catch {
            throw ServiceError.parseError(message: "Invalid workouts response")
        }
    }

    static func parseTrainingPlans(_ data: Data) throws -> [TrainingPlan] {
        do {
            return try JSONDecoder().decode(TrainLossyArray<TrainingPlan>.self, from: data).elements
        } catch {
            throw ServiceError.parseError(message: "Invalid training plan response")
        }
    }

    // MARK: log_activity

    func logActivity(_ request: ActivityLogRequest) async throws -> ActivityLogResult {
        let jwt = try await currentJWT()
        let urlRequest = try makeLogActivityRequest(request, jwt: jwt)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw ServiceError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else { throw TrainServiceError.invalidResponse }
        return try Self.parseLogActivityResponse(statusCode: http.statusCode, data: data)
    }

    func makeLogActivityRequest(_ request: ActivityLogRequest, jwt: String) throws -> URLRequest {
        try Self.validate(request)
        var urlRequest = URLRequest(url: supabaseUrl.appendingPathComponent("/functions/v1/log_activity"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 60
        urlRequest.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
        let boundary = "shudo-\(UUID().uuidString.lowercased())"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = Self.makeLogActivityMultipart(boundary: boundary, request: request)
        return urlRequest
    }

    /// Text placeholder when only a photo was attached; the analyzer reads
    /// the image (Watch/treadmill screenshot) and needs no other context.
    static let photoOnlyActivityText = "Logged from a photo."

    static func validate(_ request: ActivityLogRequest) throws {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImage = request.imageJPEG?.isEmpty == false
        guard !text.isEmpty || hasImage else {
            throw TrainServiceError.invalidRequest("Say or type what you did, or add a photo.")
        }
        guard text.count <= maximumActivityTextLength else {
            throw TrainServiceError.invalidRequest("That’s a long one — keep it under 4,000 characters.")
        }
        guard TrainCalendar.isLocalDay(request.localDay), TimeZone(identifier: request.timezone) != nil else {
            throw TrainServiceError.invalidRequest("Invalid day or timezone")
        }
        if let image = request.imageJPEG, !image.isEmpty {
            guard image.count <= maximumActivityPhotoBytes, profilePhotoDataIsJPEG(image) else {
                throw TrainServiceError.invalidRequest("Workout photos must be JPEGs under 6 MB.")
            }
        }
    }

    static func makeLogActivityMultipart(boundary: String, request: ActivityLogRequest) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(Data(string.utf8)) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        field("client_request_id", request.clientRequestId.uuidString.lowercased())
        field("local_day", request.localDay)
        field("timezone", request.timezone)
        field("text", text.isEmpty ? photoOnlyActivityText : text)
        // activities.speech_engine must match ^[a-z][a-z0-9_.]{0,63}$.
        if let engine = request.speechEngine?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           engine.range(of: #"^[a-z][a-z0-9_.]{0,63}$"#, options: .regularExpression) != nil {
            field("speech_engine", engine)
        }
        if let occurredAt = request.occurredAt {
            field("occurred_at", TrainDateParser.string(from: occurredAt))
        }
        if let session = request.planSessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !session.isEmpty {
            field("plan_session_id", session)
        }
        if let kind = request.kindHint {
            field("kind_hint", kind.rawValue)
        }
        if let image = request.imageJPEG, !image.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"image\"; filename=\"workout.jpg\"\r\n")
            append("Content-Type: image/jpeg\r\n\r\n")
            data.append(image)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return data
    }

    static func parseLogActivityResponse(statusCode: Int, data: Data) throws -> ActivityLogResult {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(statusCode) else {
            let message = (object?["error"] as? String)
                ?? (object?["message"] as? String)
                ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
            throw TrainServiceError.server(statusCode: statusCode, message: message)
        }
        guard let idText = object?["activity_id"] as? String, let id = UUID(uuidString: idText) else {
            throw TrainServiceError.invalidResponse
        }
        let status = (object?["status"] as? String).flatMap(ActivityStatus.init(rawValue:)) ?? .processing
        let duplicate = (object?["duplicate"] as? Bool) ?? false
        return ActivityLogResult(activityId: id, status: status, duplicate: duplicate)
    }

    // MARK: Delete

    /// RLS lets the owner delete a settled row (never one still processing);
    /// a delete that matches nothing means the row is mid-analysis.
    func deleteActivity(id: UUID) async throws {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        var components = URLComponents(
            url: supabaseUrl.appendingPathComponent("/rest/v1/activities"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())"),
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        let data = try await trainPerform(request, failure: "Couldn’t delete that workout")
        let rows = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        if rows.isEmpty {
            // Already gone is fine; still processing is not.
            if let existing = try await fetchActivity(id: id), existing.status == .processing {
                throw TrainServiceError.stillProcessing
            }
        }
    }

    // MARK: Plan activation (coach_chat card action)

    func activateTrainingPlan(planId: UUID, clientRequestId: UUID) async throws {
        let jwt = try await currentJWT()
        var request = URLRequest(url: supabaseUrl.appendingPathComponent("/functions/v1/coach_chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.httpBody = try Self.trainingPlanActionBody(
            planId: planId, decision: "activate", clientRequestId: clientRequestId)
        _ = try await trainPerform(request, failure: "Couldn’t start that plan")
    }

    static func trainingPlanActionBody(planId: UUID, decision: String, clientRequestId: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "client_request_id": clientRequestId.uuidString.lowercased(),
            "action": [
                "kind": "training_plan",
                "id": planId.uuidString.lowercased(),
                "decision": decision,
            ],
        ], options: [.sortedKeys])
    }

    // MARK: Photos (private coach-media bucket)

    static func activityImagePathBelongsToUser(_ path: String, userId: String) -> Bool {
        guard UUID(uuidString: userId) != nil else { return false }
        let pattern = "^" + NSRegularExpression.escapedPattern(for: userId.lowercased())
            + #"/\d{4}-\d{2}-\d{2}/(activity|chat)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$"#
        return path.range(of: pattern, options: .regularExpression) != nil
    }

    func signedActivityImageURL(path: String) async -> URL? {
        guard let userId = try? currentUserId(),
              Self.activityImagePathBelongsToUser(path, userId: userId),
              let jwt = try? await currentJWT() else { return nil }
        let cacheKey = "coach-media/\(path)"
        if let cached = await SignedImageURLCache.shared.cachedURL(for: cacheKey) { return cached }
        let epoch = await SignedImageURLCache.shared.currentEpoch()
        var url = supabaseUrl.appendingPathComponent("storage/v1/object/sign/coach-media")
        for segment in path.split(separator: "/") { url.appendPathComponent(String(segment)) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "expiresIn": Int(SignedImageURLCache.signedURLLifetime)
        ])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let signed = (object["signedURL"] as? String) ?? (object["signedUrl"] as? String),
              let resolved = Self.normalizeSignedStorageURL(signed, supabaseUrl: supabaseUrl)
        else { return nil }
        await SignedImageURLCache.shared.store(resolved, for: cacheKey, epoch: epoch)
        return resolved
    }

    // MARK: Plumbing

    private func trainGET(path: String, items: [URLQueryItem], jwt: String, failure: String) async throws -> Data {
        var components = URLComponents(url: supabaseUrl.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        return try await trainPerform(request, failure: failure)
    }

    private func trainPerform(_ request: URLRequest, failure: String) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.parseError(message: "Invalid response type")
        }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (object?["error"] as? String) ?? (object?["message"] as? String)
            throw ServiceError.serverError(statusCode: http.statusCode, message: message ?? failure)
        }
        return data
    }
}
