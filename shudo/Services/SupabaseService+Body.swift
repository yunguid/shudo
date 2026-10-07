import Foundation

/// Profile columns the Body tab needs beyond `Profile` (Shudo 2.0 goal
/// anchor + privacy opt-in). Read straight from `profiles` so the shared
/// `Profile` model and its cache stay untouched.
struct BodyGoalSettings: Equatable, Sendable {
    var goalType: NutritionGoalType = .maintain
    var targetWeightKG: Double? = nil
    /// `profiles.weight_kg`: self-reported until the scale arrives.
    var selfReportedWeightKG: Double? = nil
    var goalDate: String? = nil
    var goalStartedOn: String? = nil
    var goalStartWeightKG: Double? = nil
    var physiqueAIReviewEnabled = false

    init(
        goalType: NutritionGoalType = .maintain,
        targetWeightKG: Double? = nil,
        selfReportedWeightKG: Double? = nil,
        goalDate: String? = nil,
        goalStartedOn: String? = nil,
        goalStartWeightKG: Double? = nil,
        physiqueAIReviewEnabled: Bool = false
    ) {
        self.goalType = goalType
        self.targetWeightKG = targetWeightKG
        self.selfReportedWeightKG = selfReportedWeightKG
        self.goalDate = goalDate
        self.goalStartedOn = goalStartedOn
        self.goalStartWeightKG = goalStartWeightKG
        self.physiqueAIReviewEnabled = physiqueAIReviewEnabled
    }

    init(profile: Profile) {
        self.init(
            goalType: profile.goalType,
            targetWeightKG: profile.targetWeightKG,
            selfReportedWeightKG: profile.weightKG
        )
    }
}

/// What a check-in save writes. Absent values are left out of the upsert so
/// a photo-only save never nulls a weight logged earlier that day (and a
/// weight-only save never touches the photo).
struct BodyCheckInDraft: Equatable, Sendable {
    var localDay: String
    var weightKG: Double? = nil
    var photoJPEG: Data? = nil
    var pose: PhysiquePose? = nil
    var capturedAt: Date? = nil
    var note: String? = nil
}

extension SupabaseService {
    static let weightCheckInBaseColumns =
        "id,local_day,weight_kg,progress_photo_path,created_at,updated_at"
    static let weightCheckInColumns =
        weightCheckInBaseColumns
        + ",note,photo_pose,photo_captured_at,coach_review,coach_reviewed_at"
    static let bodyGoalColumns =
        "goal_type,target_weight_kg,weight_kg,goal_date,goal_started_on,goal_start_weight_kg,physique_ai_review_enabled"
    static let bodyGoalBaseColumns = "goal_type,target_weight_kg,weight_kg"
    /// Columns added in Shudo 2.0; stripped on retry if the server predates them.
    static let checkInV2PayloadKeys: Set<String> = ["note", "photo_pose", "photo_captured_at"]

    /// Physique photos never touch `URLSession.shared` (whose disk cache is
    /// unprotected Library/Caches): an ephemeral session with no URL cache.
    static let bodyPhotoSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    // MARK: Paths

    static func weightPhotoPath(
        userId: String,
        localDay: String,
        fileId: UUID = UUID()
    ) throws -> String {
        guard UUID(uuidString: userId) != nil,
            localDay.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
        else {
            throw ServiceError.parseError(message: "Invalid weigh-in photo path")
        }
        return
            "\(userId.lowercased())/\(localDay)/progress-\(fileId.uuidString.lowercased()).jpg"
    }

    static func weightPhotoPathBelongsToUser(_ path: String, userId: String) -> Bool {
        guard UUID(uuidString: userId) != nil else { return false }
        let pattern =
            #"^"# + NSRegularExpression.escapedPattern(for: userId.lowercased())
            + #"/\d{4}-\d{2}-\d{2}/progress-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$"#
        return path.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: Read

    func fetchWeightCheckIns(limit: Int = 30) async throws -> [WeightCheckIn] {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        func request(columns: String) -> URLRequest {
            var components = URLComponents(
                url: supabaseUrl.appendingPathComponent("/rest/v1/weight_checkins"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "select", value: columns),
                URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                URLQueryItem(name: "order", value: "local_day.desc"),
                URLQueryItem(name: "limit", value: "\(max(1, min(limit, 400)))"),
            ]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            authorize(&request, jwt: jwt)
            return request
        }
        let (data, status) = try await bodyData(for: request(columns: Self.weightCheckInColumns))
        if status == 400 {
            // Server without the 2.0 columns yet: degrade to the base shape.
            let (fallback, fallbackStatus) = try await bodyData(
                for: request(columns: Self.weightCheckInBaseColumns))
            try Self.requireSuccess(fallbackStatus, data: fallback, message: "Couldn’t load check-ins")
            return try Self.parseWeightCheckIns(fallback)
        }
        try Self.requireSuccess(status, data: data, message: "Couldn’t load check-ins")
        return try Self.parseWeightCheckIns(data)
    }

    static func parseWeightCheckIns(_ data: Data) throws -> [WeightCheckIn] {
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ServiceError.parseError(message: "Invalid check-in response")
        }
        return objects.compactMap(parseWeightCheckIn)
    }

    static func parseWeightCheckIn(_ object: [String: Any]) -> WeightCheckIn? {
        guard let idText = object["id"] as? String,
            let id = UUID(uuidString: idText),
            let localDay = object["local_day"] as? String,
            LocalDayMath.date(localDay) != nil,
            let createdAt = bodyDate(object["created_at"]),
            let updatedAt = bodyDate(object["updated_at"])
        else { return nil }
        let weight = bodyNumber(object["weight_kg"]).flatMap {
            WeightCheckInPolicy.kilogramsRange.contains($0) ? $0 : nil
        }
        let photoPath = (object["progress_photo_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // A row with neither observation is meaningless to the UI.
        guard weight != nil || photoPath != nil else { return nil }
        return WeightCheckIn(
            id: id,
            localDay: localDay,
            weightKG: weight,
            progressPhotoPath: photoPath,
            note: (object["note"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            photoPose: (object["photo_pose"] as? String).flatMap(PhysiquePose.init(rawValue:)),
            photoCapturedAt: bodyDate(object["photo_captured_at"]),
            coachReview: PhysiqueCoachReview.parse(object["coach_review"]),
            coachReviewedAt: bodyDate(object["coach_reviewed_at"]),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    /// Authenticated download (`/object/authenticated/…` with the JWT) through
    /// the ephemeral session. Callers cache via `BodyPhotoCache`.
    func fetchCheckInPhoto(path: String) async throws -> Data {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        guard Self.weightPhotoPathBelongsToUser(path, userId: userId) else {
            throw ServiceError.parseError(message: "Invalid check-in photo path")
        }
        var request = URLRequest(url: bodyStorageURL(operation: "object/authenticated", path: path))
        request.httpMethod = "GET"
        authorize(&request, jwt: jwt)
        let (data, status) = try await bodyData(for: request)
        guard (200..<300).contains(status), data.count <= Self.maximumWeightPhotoBytes,
            Self.profilePhotoDataIsJPEG(data)
        else {
            throw ServiceError.serverError(statusCode: status, message: "Couldn’t load check-in photo")
        }
        return data
    }

    func fetchBodyGoalSettings() async throws -> BodyGoalSettings {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        func request(columns: String) -> URLRequest {
            var components = URLComponents(
                url: supabaseUrl.appendingPathComponent("/rest/v1/profiles"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "select", value: columns),
                URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                URLQueryItem(name: "limit", value: "1"),
            ]
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            authorize(&request, jwt: jwt)
            return request
        }
        var (data, status) = try await bodyData(for: request(columns: Self.bodyGoalColumns))
        if status == 400 {
            (data, status) = try await bodyData(for: request(columns: Self.bodyGoalBaseColumns))
        }
        try Self.requireSuccess(status, data: data, message: "Couldn’t load your goal")
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            let row = rows.first
        else { throw ServiceError.parseError(message: "Profile row was missing") }
        return Self.parseBodyGoalSettings(row)
    }

    static func parseBodyGoalSettings(_ row: [String: Any]) -> BodyGoalSettings {
        func day(_ key: String) -> String? {
            (row[key] as? String).flatMap { LocalDayMath.date($0) != nil ? $0 : nil }
        }
        func weight(_ key: String) -> Double? {
            bodyNumber(row[key]).flatMap { WeightCheckInPolicy.kilogramsRange.contains($0) ? $0 : nil }
        }
        return BodyGoalSettings(
            goalType: (row["goal_type"] as? String).flatMap(NutritionGoalType.init(rawValue:))
                ?? .maintain,
            targetWeightKG: weight("target_weight_kg"),
            selfReportedWeightKG: weight("weight_kg"),
            goalDate: day("goal_date"),
            goalStartedOn: day("goal_started_on"),
            goalStartWeightKG: weight("goal_start_weight_kg"),
            physiqueAIReviewEnabled: row["physique_ai_review_enabled"] as? Bool ?? false
        )
    }

    // MARK: Write

    static func bodyCheckInPayload(
        userId: String,
        draft: BodyCheckInDraft,
        photoPath: String?
    ) -> [String: Any] {
        var payload: [String: Any] = ["user_id": userId, "local_day": draft.localDay]
        if let weight = draft.weightKG { payload["weight_kg"] = weight }
        if let photoPath {
            payload["progress_photo_path"] = photoPath
            if let pose = draft.pose { payload["photo_pose"] = pose.rawValue }
            if let capturedAt = draft.capturedAt {
                payload["photo_captured_at"] = bodyISOFormatter.string(from: capturedAt)
            }
        }
        if let note = draft.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            payload["note"] = String(note.prefix(WeightCheckInPolicy.noteLimit))
        }
        return payload
    }

    /// Upserts one day's check-in through RLS. A new photo is uploaded first
    /// (`x-upsert: false`, a fresh uuid path), the row is merged on
    /// `(user_id, local_day)`, then the replaced object is removed. A failed
    /// row write deletes the just-uploaded object so nothing is orphaned.
    func saveBodyCheckIn(
        _ draft: BodyCheckInDraft,
        replacing existing: WeightCheckIn?,
        updatesProfileWeight: Bool = true
    ) async throws -> WeightCheckIn {
        if let weight = draft.weightKG, !WeightCheckInPolicy.kilogramsRange.contains(weight) {
            throw ServiceError.parseError(message: "Weight is outside the supported range")
        }
        guard draft.weightKG != nil || draft.photoJPEG != nil || existing != nil else {
            throw ServiceError.parseError(message: "Add a photo or a weight")
        }
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        var newPath: String?
        do {
            if let jpeg = draft.photoJPEG {
                guard jpeg.count <= Self.maximumWeightPhotoBytes, Self.profilePhotoDataIsJPEG(jpeg) else {
                    throw ServiceError.parseError(message: "Check-in photos must be JPEGs under 4 MB")
                }
                let path = try Self.weightPhotoPath(userId: userId, localDay: draft.localDay)
                var upload = URLRequest(url: bodyStorageURL(operation: "object", path: path))
                upload.httpMethod = "POST"
                authorize(&upload, jwt: jwt)
                upload.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
                upload.setValue("false", forHTTPHeaderField: "x-upsert")
                upload.httpBody = jpeg
                let (body, status) = try await bodyData(for: upload)
                try Self.requireSuccess(status, data: body, message: "Couldn’t upload the photo")
                newPath = path
            }

            var payload = Self.bodyCheckInPayload(userId: userId, draft: draft, photoPath: newPath)
            var (data, status) = try await bodyData(for: upsertRequest(payload, jwt: jwt))
            if status == 400, !Self.checkInV2PayloadKeys.isDisjoint(with: payload.keys) {
                for key in Self.checkInV2PayloadKeys { payload.removeValue(forKey: key) }
                (data, status) = try await bodyData(for: upsertRequest(payload, jwt: jwt))
            }
            try Self.requireSuccess(status, data: data, message: "Couldn’t save the check-in")
            guard let saved = try Self.parseWeightCheckIns(data).first else {
                throw ServiceError.parseError(message: "Saved check-in was missing")
            }

            if let weight = draft.weightKG, updatesProfileWeight {
                try? await patchProfile(["weight_kg": weight], jwt: jwt, userId: userId)
            }
            if newPath != nil, let oldPath = existing?.progressPhotoPath, oldPath != newPath {
                try? await deleteCheckInObject(path: oldPath, userId: userId, jwt: jwt)
            }
            return saved
        } catch {
            if let newPath {
                try? await deleteCheckInObject(path: newPath, userId: userId, jwt: jwt)
            }
            throw error
        }
    }

    /// 1.x signature, kept for any caller still on the weigh-in sheet API.
    func saveWeightCheckIn(
        localDay: String,
        weightKG: Double,
        progressJPEG: Data?,
        replacing existing: WeightCheckIn?
    ) async throws -> WeightCheckIn {
        try await saveBodyCheckIn(
            BodyCheckInDraft(
                localDay: localDay,
                weightKG: weightKG,
                photoJPEG: progressJPEG,
                capturedAt: progressJPEG == nil ? nil : Date()
            ),
            replacing: existing
        )
    }

    /// Removes a day's photo. The row stays when it still carries a weight
    /// (photo columns nulled); a photo-only row is deleted outright.
    func removeCheckInPhoto(_ checkIn: WeightCheckIn) async throws -> WeightCheckIn? {
        guard let path = checkIn.progressPhotoPath else { return checkIn }
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        var components = URLComponents(
            url: supabaseUrl.appendingPathComponent("/rest/v1/weight_checkins"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(checkIn.id.uuidString.lowercased())"),
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
        ]
        var request = URLRequest(url: components.url!)
        authorize(&request, jwt: jwt)
        var updated: WeightCheckIn?
        if checkIn.weightKG != nil {
            request.httpMethod = "PATCH"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("return=representation", forHTTPHeaderField: "Prefer")
            var body: [String: Any] = ["progress_photo_path": NSNull()]
            if checkIn.photoPose != nil { body["photo_pose"] = NSNull() }
            if checkIn.photoCapturedAt != nil { body["photo_captured_at"] = NSNull() }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, status) = try await bodyData(for: request)
            try Self.requireSuccess(status, data: data, message: "Couldn’t remove the photo")
            updated = try Self.parseWeightCheckIns(data).first
        } else {
            request.httpMethod = "DELETE"
            let (data, status) = try await bodyData(for: request)
            try Self.requireSuccess(status, data: data, message: "Couldn’t remove the check-in")
        }
        try? await deleteCheckInObject(path: path, userId: userId, jwt: jwt)
        return updated
    }

    static func bodyGoalPayload(
        goalDate: String?? = nil,
        goalStartedOn: String?? = nil,
        goalStartWeightKG: Double?? = nil,
        physiqueAIReviewEnabled: Bool? = nil
    ) throws -> [String: Any] {
        var payload: [String: Any] = [:]
        func day(_ value: String?, label: String) throws -> Any {
            guard let value else { return NSNull() }
            guard LocalDayMath.date(value) != nil else {
                throw ServiceError.parseError(message: "\(label) must be a calendar day")
            }
            return value
        }
        if let goalDate { payload["goal_date"] = try day(goalDate, label: "Goal date") }
        if let goalStartedOn { payload["goal_started_on"] = try day(goalStartedOn, label: "Start day") }
        if let goalStartWeightKG {
            if let weight = goalStartWeightKG {
                guard WeightCheckInPolicy.kilogramsRange.contains(weight) else {
                    throw ServiceError.parseError(message: "Start weight is outside the supported range")
                }
                payload["goal_start_weight_kg"] = (weight * 100).rounded() / 100
            } else {
                payload["goal_start_weight_kg"] = NSNull()
            }
        }
        if let physiqueAIReviewEnabled { payload["physique_ai_review_enabled"] = physiqueAIReviewEnabled }
        return payload
    }

    /// Client-updatable 2.0 goal columns on `profiles`. Pass `.some(nil)` to clear.
    func updateBodyGoal(
        goalDate: String?? = nil,
        goalStartedOn: String?? = nil,
        goalStartWeightKG: Double?? = nil
    ) async throws {
        let payload = try Self.bodyGoalPayload(
            goalDate: goalDate, goalStartedOn: goalStartedOn, goalStartWeightKG: goalStartWeightKG)
        guard !payload.isEmpty else { return }
        try await patchProfile(payload, jwt: try await currentJWT(), userId: try currentUserId())
    }

    /// Settings toggle (owned by the shell lane's Settings UI).
    func setPhysiqueAIReviewEnabled(_ enabled: Bool) async throws {
        try await patchProfile(
            try Self.bodyGoalPayload(physiqueAIReviewEnabled: enabled),
            jwt: try await currentJWT(),
            userId: try currentUserId()
        )
    }

    // MARK: Plumbing

    private func upsertRequest(_ payload: [String: Any], jwt: String) throws -> URLRequest {
        var components = URLComponents(
            url: supabaseUrl.appendingPathComponent("/rest/v1/weight_checkins"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "on_conflict", value: "user_id,local_day")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        authorize(&request, jwt: jwt)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("resolution=merge-duplicates,return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func patchProfile(_ payload: [String: Any], jwt: String, userId: String) async throws {
        var components = URLComponents(
            url: supabaseUrl.appendingPathComponent("/rest/v1/profiles"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "user_id", value: "eq.\(userId)")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        authorize(&request, jwt: jwt)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, status) = try await bodyData(for: request)
        try Self.requireSuccess(status, data: data, message: "Couldn’t update your profile")
    }

    private func deleteCheckInObject(path: String, userId: String, jwt: String) async throws {
        guard Self.weightPhotoPathBelongsToUser(path, userId: userId) else { return }
        var request = URLRequest(url: bodyStorageURL(operation: "object", path: path))
        request.httpMethod = "DELETE"
        authorize(&request, jwt: jwt)
        let (data, status) = try await bodyData(for: request)
        try Self.requireSuccess(status, data: data, message: "Couldn’t remove the old photo")
    }

    func bodyStorageURL(operation: String, path: String) -> URL {
        let base = (["storage", "v1"] + operation.split(separator: "/").map(String.init))
            .reduce(supabaseUrl) { $0.appendingPathComponent($1) }
            .appendingPathComponent("weight-checkin-photos")
        return path.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
    }

    private func authorize(_ request: inout URLRequest, jwt: String) {
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
    }

    private func bodyData(for request: URLRequest) async throws -> (Data, Int) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await Self.bodyPhotoSession.data(for: request)
        } catch {
            throw ServiceError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.parseError(message: "Invalid response type")
        }
        return (data, http.statusCode)
    }

    /// Server error bodies can echo object paths; only a friendly message and
    /// the status code surface (and nothing is logged).
    private static func requireSuccess(_ status: Int, data: Data, message: String) throws {
        guard !(200..<300).contains(status) else { return }
        throw ServiceError.serverError(statusCode: status, message: message)
    }

    private static let bodyISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let bodyPlainISOFormatter = ISO8601DateFormatter()

    static func bodyDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return bodyISOFormatter.date(from: string) ?? bodyPlainISOFormatter.date(from: string)
    }

    /// PostgREST renders `numeric` as a JSON number or a string; null stays nil.
    static func bodyNumber(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where !(value is Bool): return number.doubleValue.isFinite ? number.doubleValue : nil
        case let text as String: return Double(text)
        default: return nil
        }
    }
}
