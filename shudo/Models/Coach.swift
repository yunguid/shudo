import Foundation

// Shared Swift contracts for the Shudo 2.0 coach (SPEC §4, §5.1). Every type
// here mirrors a server JSON shape with snake_case keys; decoding is tolerant
// on purpose (unknown kinds, missing optional card fields, numbers sent as
// strings) so a newer server never breaks an older build's thread.

// MARK: - Raw JSON

/// A lossless JSON value. Coach payloads are `jsonb` on the server; the typed
/// card is derived from this, and the raw value is kept so a message can be
/// re-encoded (fixtures, the notification store) without losing fields.
enum CoachJSON: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CoachJSON])
    case object([String: CoachJSON])

    static let emptyObject = CoachJSON.object([:])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CoachJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: CoachJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Encodes any `Encodable` into a raw JSON value (fixtures and tests).
    init<T: Encodable>(encoding value: T) {
        guard let data = try? JSONEncoder().encode(value),
              let decoded = try? JSONDecoder().decode(CoachJSON.self, from: data) else {
            self = .null
            return
        }
        self = decoded
    }

    subscript(key: String) -> CoachJSON? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var objectValue: [String: CoachJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value.rounded() == value && abs(value) < 1e15
                ? String(Int64(value)) : String(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let value):
            switch value.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        default: return nil
        }
    }

    var uuidValue: UUID? { stringValue.flatMap(UUID.init(uuidString:)) }

    /// Re-decodes this value as a typed card; `nil` when the shape doesn't fit.
    func decoded<T: Decodable>(as type: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Dates

/// Server timestamps arrive from PostgREST (`2026-10-06T14:05:00.123456+00:00`)
/// and from Edge Functions (`2026-10-06T14:05:00.123Z`). Both are accepted;
/// outgoing dates are always UTC `Z` so they never carry a `+` that a query
/// string would turn into a space.
enum CoachDateCoding {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    static func date(from raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let date = fractionalFormatter.date(from: value) { return date }
        if let date = plainFormatter.date(from: value) { return date }
        // Postgres text form uses a space separator and may carry 6 fractional
        // digits or a short `+00` offset; normalize then retry.
        var normalized = value
        if let space = normalized.firstIndex(of: " ") {
            normalized.replaceSubrange(space...space, with: "T")
        }
        if let dot = normalized.firstIndex(of: ".") {
            let digitsStart = normalized.index(after: dot)
            let digitsEnd = normalized[digitsStart...].firstIndex { !$0.isNumber }
                ?? normalized.endIndex
            let digits = normalized[digitsStart..<digitsEnd]
            if digits.count > 3 {
                normalized.replaceSubrange(digitsStart..<digitsEnd, with: digits.prefix(3))
            }
        }
        if normalized.range(of: #"[+-]\d{2}$"#, options: .regularExpression) != nil {
            normalized += ":00"
        }
        return fractionalFormatter.date(from: normalized) ?? plainFormatter.date(from: normalized)
    }

    static func string(from date: Date) -> String {
        fractionalFormatter.string(from: date)
    }
}

// MARK: - Lenient decoding helpers

/// Decodes an element or yields `nil`, so one bad array element doesn't sink
/// the whole card.
struct CoachLenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension KeyedDecodingContainer {
    func coachJSON(_ key: Key) -> CoachJSON? {
        (try? decodeIfPresent(CoachJSON.self, forKey: key)) ?? nil
    }

    func coachString(_ key: Key) -> String? {
        coachJSON(key)?.stringValue
    }

    func coachDouble(_ key: Key) -> Double? {
        guard let value = coachJSON(key)?.doubleValue, value.isFinite else { return nil }
        return value
    }

    func coachInt(_ key: Key) -> Int? {
        coachDouble(key).map { Int($0.rounded()) }
    }

    func coachBool(_ key: Key) -> Bool? {
        coachJSON(key)?.boolValue
    }

    func coachUUID(_ key: Key) -> UUID? {
        coachJSON(key)?.uuidValue
    }

    func coachDate(_ key: Key) -> Date? {
        coachString(key).flatMap(CoachDateCoding.date(from:))
    }

    func coachArray<T: Decodable>(_ key: Key, of type: T.Type = T.self) -> [T] {
        ((try? decodeIfPresent([CoachLenient<T>].self, forKey: key)) ?? nil)?
            .compactMap(\.value) ?? []
    }

    func coachStrings(_ key: Key) -> [String] {
        guard case .array(let values)? = coachJSON(key) else { return [] }
        return values.compactMap(\.stringValue)
    }

    func coachDecode<T: Decodable>(_ key: Key, as type: T.Type = T.self) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

// MARK: - Message

enum CoachRole: String, Codable, Equatable, Sendable {
    case coach
    case user
    case systemEvent = "system_event"
}

enum CoachMessageStatus: String, Codable, Equatable, Sendable {
    case scheduled
    case delivered
    case superseded
}

/// Every message kind the server may write (SPEC §2). `CoachMessage.kind`
/// stays a `String` so unknown future kinds survive decoding.
enum CoachMessageKind: String, CaseIterable, Sendable {
    // coach
    case text
    case checkpoint
    case plan
    case snackRec = "snack_rec"
    case mealAck = "meal_ack"
    case workoutAck = "workout_ack"
    case weighInAck = "weigh_in_ack"
    case photoFeedback = "photo_feedback"
    case recap
    case profileUpdate = "profile_update"
    case trainingPlan = "training_plan"
    case goalChange = "goal_change"
    // user
    case photo
    // system_event
    case event
}

struct CoachMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var role: CoachRole
    var kind: String
    var body: String
    /// Typed card decoded from `payload` by `kind`; unknown kinds → `.unknown`.
    var payload: CoachPayload
    /// The payload exactly as the server sent it.
    var rawPayload: CoachJSON
    var localDay: String
    var deliverAt: Date
    var status: CoachMessageStatus
    var notify: Bool
    var slotKey: String?
    var entryId: UUID?
    var activityId: UUID?
    var attachmentPath: String?
    /// Set on user rows; matches the optimistic bubble's `clientRequestId`.
    var clientRequestId: UUID?
    var replyToId: UUID?
    var readAt: Date?
    var createdAt: Date
    var updatedAt: Date
    /// `payload.streaming == true`: the server is still writing `body`.
    var isStreaming: Bool
    /// `payload.interrupted == true`: the reply run failed mid-stream; the
    /// text so far is kept but will not grow.
    var isInterrupted: Bool
    /// `payload.push_body`: the lock-screen text when `notify` is true.
    var pushBody: String?

    init(
        id: UUID = UUID(),
        role: CoachRole,
        kind: String,
        body: String,
        rawPayload: CoachJSON = .emptyObject,
        localDay: String,
        deliverAt: Date,
        status: CoachMessageStatus = .delivered,
        notify: Bool = false,
        slotKey: String? = nil,
        entryId: UUID? = nil,
        activityId: UUID? = nil,
        attachmentPath: String? = nil,
        clientRequestId: UUID? = nil,
        replyToId: UUID? = nil,
        readAt: Date? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.body = body
        self.rawPayload = rawPayload
        self.localDay = localDay
        self.deliverAt = deliverAt
        self.status = status
        self.notify = notify
        self.slotKey = slotKey
        self.entryId = entryId
        self.activityId = activityId
        self.attachmentPath = attachmentPath
        self.clientRequestId = clientRequestId
        self.replyToId = replyToId
        self.readAt = readAt
        self.createdAt = createdAt ?? deliverAt
        self.updatedAt = updatedAt ?? createdAt ?? deliverAt
        self.payload = CoachPayload.make(
            kind: kind,
            raw: rawPayload,
            localDay: localDay,
            entryId: entryId,
            activityId: activityId
        )
        self.isInterrupted = rawPayload["interrupted"]?.boolValue ?? false
        self.isStreaming = (rawPayload["streaming"]?.boolValue ?? false) && !isInterrupted
        self.pushBody = Self.trimmedPushBody(rawPayload["push_body"]?.stringValue)
    }

    enum CodingKeys: String, CodingKey {
        case id, role, kind, body, payload, status, notify
        case localDay = "local_day"
        case deliverAt = "deliver_at"
        case slotKey = "slot_key"
        case entryId = "entry_id"
        case activityId = "activity_id"
        case attachmentPath = "attachment_path"
        case clientRequestId = "client_request_id"
        case replyToId = "reply_to_id"
        case readAt = "read_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.coachUUID(.id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: c,
                debugDescription: "coach message id is missing"
            )
        }
        var raw = c.coachJSON(.payload) ?? .emptyObject
        if case .string(let text) = raw,
           let data = text.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(CoachJSON.self, from: data) {
            raw = parsed
        }
        if raw.objectValue == nil { raw = .emptyObject }
        let created = c.coachDate(.createdAt)
        let deliver = c.coachDate(.deliverAt) ?? created ?? Date()
        self.init(
            id: id,
            role: c.coachString(.role).flatMap(CoachRole.init(rawValue:)) ?? .systemEvent,
            kind: c.coachString(.kind) ?? "text",
            body: c.coachString(.body) ?? "",
            rawPayload: raw,
            localDay: c.coachString(.localDay) ?? "",
            deliverAt: deliver,
            status: c.coachString(.status).flatMap(CoachMessageStatus.init(rawValue:)) ?? .delivered,
            notify: c.coachBool(.notify) ?? false,
            slotKey: c.coachString(.slotKey),
            entryId: c.coachUUID(.entryId),
            activityId: c.coachUUID(.activityId),
            attachmentPath: c.coachString(.attachmentPath),
            clientRequestId: c.coachUUID(.clientRequestId),
            replyToId: c.coachUUID(.replyToId),
            readAt: c.coachDate(.readAt),
            createdAt: created ?? deliver,
            updatedAt: c.coachDate(.updatedAt) ?? created ?? deliver
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.uuidString.lowercased(), forKey: .id)
        try c.encode(role.rawValue, forKey: .role)
        try c.encode(kind, forKey: .kind)
        try c.encode(body, forKey: .body)
        try c.encode(rawPayload, forKey: .payload)
        try c.encode(localDay, forKey: .localDay)
        try c.encode(CoachDateCoding.string(from: deliverAt), forKey: .deliverAt)
        try c.encode(status.rawValue, forKey: .status)
        try c.encode(notify, forKey: .notify)
        try c.encodeIfPresent(slotKey, forKey: .slotKey)
        try c.encodeIfPresent(entryId?.uuidString.lowercased(), forKey: .entryId)
        try c.encodeIfPresent(activityId?.uuidString.lowercased(), forKey: .activityId)
        try c.encodeIfPresent(attachmentPath, forKey: .attachmentPath)
        try c.encodeIfPresent(clientRequestId?.uuidString.lowercased(), forKey: .clientRequestId)
        try c.encodeIfPresent(replyToId?.uuidString.lowercased(), forKey: .replyToId)
        try c.encodeIfPresent(readAt.map(CoachDateCoding.string(from:)), forKey: .readAt)
        try c.encode(CoachDateCoding.string(from: createdAt), forKey: .createdAt)
        try c.encode(CoachDateCoding.string(from: updatedAt), forKey: .updatedAt)
    }

    var knownKind: CoachMessageKind? { CoachMessageKind(rawValue: kind) }

    /// Thread visibility rule shared with the server (SPEC §2).
    func isVisible(at now: Date) -> Bool {
        status != .superseded && deliverAt <= now
    }

    /// Counts toward the unread badge.
    func isUnread(at now: Date) -> Bool {
        role == .coach && readAt == nil && isVisible(at: now)
    }

    /// Text for a lock-screen notification: `push_body`, else the body.
    var notificationText: String {
        if let pushBody, !pushBody.isEmpty { return pushBody }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > Self.maximumPushBodyLength else { return trimmed }
        return String(trimmed.prefix(Self.maximumPushBodyLength - 1)) + "…"
    }

    var deepLink: URL { AppRouter.coachDeepLink(messageId: id, localDay: localDay) }

    static let maximumPushBodyLength = 150

    private static func trimmedPushBody(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Card payloads (SPEC §4)

struct CoachMacros: Codable, Equatable, Sendable {
    var caloriesKcal: Double
    var proteinG: Double
    var carbsG: Double
    var fatG: Double

    static let zero = CoachMacros(caloriesKcal: 0, proteinG: 0, carbsG: 0, fatG: 0)

    init(caloriesKcal: Double, proteinG: Double, carbsG: Double, fatG: Double) {
        self.caloriesKcal = caloriesKcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
    }

    enum CodingKeys: String, CodingKey {
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        caloriesKcal = c.coachDouble(.caloriesKcal) ?? 0
        proteinG = c.coachDouble(.proteinG) ?? 0
        carbsG = c.coachDouble(.carbsG) ?? 0
        fatG = c.coachDouble(.fatG) ?? 0
    }
}

/// `snack_rec` card: SnackRecPayload from `_shared/nearby_food.ts`.
struct SnackRec: Codable, Equatable, Sendable {
    enum Verdict: String, Codable, Sendable {
        case grab
        case noSnackNeeded = "no_snack_needed"
    }

    struct Item: Codable, Equatable, Sendable {
        var name: String
        var brand: String?
        var serving: String
        var quantity: Double
        var caloriesKcal: Double
        var proteinG: Double
        var carbsG: Double
        var fatG: Double
        var priceUsdEst: Double?
        var sourceUrl: String?
        /// `web` | `label_known` | `estimate`
        var nutritionSource: String

        init(
            name: String,
            brand: String? = nil,
            serving: String,
            quantity: Double = 1,
            caloriesKcal: Double,
            proteinG: Double,
            carbsG: Double,
            fatG: Double,
            priceUsdEst: Double? = nil,
            sourceUrl: String? = nil,
            nutritionSource: String = "estimate"
        ) {
            self.name = name
            self.brand = brand
            self.serving = serving
            self.quantity = quantity
            self.caloriesKcal = caloriesKcal
            self.proteinG = proteinG
            self.carbsG = carbsG
            self.fatG = fatG
            self.priceUsdEst = priceUsdEst
            self.sourceUrl = sourceUrl
            self.nutritionSource = nutritionSource
        }

        enum CodingKeys: String, CodingKey {
            case name, brand, serving, quantity
            case caloriesKcal = "calories_kcal"
            case proteinG = "protein_g"
            case carbsG = "carbs_g"
            case fatG = "fat_g"
            case priceUsdEst = "price_usd_est"
            case sourceUrl = "source_url"
            case nutritionSource = "nutrition_source"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let name = c.coachString(.name), !name.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .name,
                    in: c,
                    debugDescription: "snack item name is missing"
                )
            }
            self.name = name
            brand = c.coachString(.brand)
            serving = c.coachString(.serving) ?? ""
            quantity = c.coachDouble(.quantity) ?? 1
            caloriesKcal = c.coachDouble(.caloriesKcal) ?? 0
            proteinG = c.coachDouble(.proteinG) ?? 0
            carbsG = c.coachDouble(.carbsG) ?? 0
            fatG = c.coachDouble(.fatG) ?? 0
            priceUsdEst = c.coachDouble(.priceUsdEst)
            sourceUrl = c.coachString(.sourceUrl)
            nutritionSource = c.coachString(.nutritionSource) ?? "estimate"
        }
    }

    struct Option: Codable, Equatable, Sendable, Identifiable {
        var storeRef: String
        var storeName: String
        var walkMinutes: Int
        var items: [Item]
        var combined: CoachMacros
        var remainingAfter: CoachMacros
        /// Query for Apple Maps ("Directions").
        var mapsQuery: String

        var id: String { storeRef.isEmpty ? storeName : storeRef }

        init(
            storeRef: String,
            storeName: String,
            walkMinutes: Int,
            items: [Item],
            combined: CoachMacros,
            remainingAfter: CoachMacros,
            mapsQuery: String
        ) {
            self.storeRef = storeRef
            self.storeName = storeName
            self.walkMinutes = walkMinutes
            self.items = items
            self.combined = combined
            self.remainingAfter = remainingAfter
            self.mapsQuery = mapsQuery
        }

        enum CodingKeys: String, CodingKey {
            case items, combined
            case storeRef = "store_ref"
            case storeName = "store_name"
            case walkMinutes = "walk_minutes"
            case remainingAfter = "remaining_after"
            case mapsQuery = "maps_query"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            storeRef = c.coachString(.storeRef) ?? ""
            storeName = c.coachString(.storeName) ?? ""
            walkMinutes = max(0, c.coachInt(.walkMinutes) ?? 0)
            items = c.coachArray(.items)
            combined = c.coachDecode(.combined) ?? .zero
            remainingAfter = c.coachDecode(.remainingAfter) ?? .zero
            mapsQuery = c.coachString(.mapsQuery) ?? storeName
        }
    }

    var headline: String
    var verdict: Verdict
    var options: [Option]
    var sources: [String]

    init(headline: String, verdict: Verdict, options: [Option], sources: [String] = []) {
        self.headline = headline
        self.verdict = verdict
        self.options = options
        self.sources = sources
    }

    enum CodingKeys: String, CodingKey {
        case headline, verdict, options, sources
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headline = c.coachString(.headline) ?? ""
        verdict = c.coachString(.verdict).flatMap(Verdict.init(rawValue:)) ?? .grab
        options = c.coachArray(.options)
        sources = c.coachStrings(.sources)
        guard !headline.isEmpty || !options.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .headline,
                in: c,
                debugDescription: "snack recommendation is empty"
            )
        }
    }
}

/// `training_plan` card.
struct TrainingPlanCard: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case draft, active, superseded, rejected
    }

    struct Session: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var name: String
        var estMinutes: Int?
        var topExercises: [String]

        init(id: String, name: String, estMinutes: Int? = nil, topExercises: [String] = []) {
            self.id = id
            self.name = name
            self.estMinutes = estMinutes
            self.topExercises = topExercises
        }

        enum CodingKeys: String, CodingKey {
            case id, name
            case estMinutes = "est_minutes"
            case topExercises = "top_exercises"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let name = c.coachString(.name) ?? ""
            id = c.coachString(.id) ?? name
            self.name = name.isEmpty ? id : name
            estMinutes = c.coachInt(.estMinutes)
            topExercises = c.coachStrings(.topExercises)
        }
    }

    var planId: UUID
    var status: Status
    var name: String
    var sessionsPerWeek: Int
    var summary: String
    var sessions: [Session]

    var isActive: Bool { status == .active }

    init(
        planId: UUID,
        status: Status,
        name: String,
        sessionsPerWeek: Int,
        summary: String,
        sessions: [Session]
    ) {
        self.planId = planId
        self.status = status
        self.name = name
        self.sessionsPerWeek = sessionsPerWeek
        self.summary = summary
        self.sessions = sessions
    }

    enum CodingKeys: String, CodingKey {
        case status, name, summary, sessions
        case planId = "plan_id"
        case sessionsPerWeek = "sessions_per_week"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let planId = c.coachUUID(.planId) else {
            throw DecodingError.dataCorruptedError(
                forKey: .planId,
                in: c,
                debugDescription: "training plan id is missing"
            )
        }
        self.planId = planId
        status = c.coachString(.status).flatMap(Status.init(rawValue:)) ?? .draft
        name = c.coachString(.name) ?? "Training plan"
        sessions = c.coachArray(.sessions)
        sessionsPerWeek = c.coachInt(.sessionsPerWeek) ?? sessions.count
        summary = c.coachString(.summary) ?? ""
    }
}

/// Targets + goal on one side of a `goal_change` card. The server's
/// `{...targets, goal}` is read flat, or with `targets` / `goal` nested.
struct GoalSnapshot: Codable, Equatable, Sendable {
    var caloriesKcal: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    /// `lose` | `maintain` | `gain` (profiles.goal_type), or a coach phase.
    var goalType: String?
    var targetWeightKg: Double?
    /// `YYYY-MM-DD`
    var goalDate: String?
    var weeklyRatePct: Double?

    init(
        caloriesKcal: Double? = nil,
        proteinG: Double? = nil,
        carbsG: Double? = nil,
        fatG: Double? = nil,
        goalType: String? = nil,
        targetWeightKg: Double? = nil,
        goalDate: String? = nil,
        weeklyRatePct: Double? = nil
    ) {
        self.caloriesKcal = caloriesKcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.goalType = goalType
        self.targetWeightKg = targetWeightKg
        self.goalDate = goalDate
        self.weeklyRatePct = weeklyRatePct
    }

    enum CodingKeys: String, CodingKey {
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case goalType = "goal_type"
        case targetWeightKg = "target_weight_kg"
        case goalDate = "goal_date"
        case weeklyRatePct = "weekly_rate_pct"
    }

    private enum NestedKeys: String, CodingKey {
        case targets
        case dailyMacroTarget = "daily_macro_target"
        case goal, phase, type
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try decoder.container(keyedBy: NestedKeys.self)
        let targets: CoachMacros? = nested.coachDecode(.targets) ?? nested.coachDecode(.dailyMacroTarget)
        caloriesKcal = c.coachDouble(.caloriesKcal) ?? targets?.caloriesKcal
        proteinG = c.coachDouble(.proteinG) ?? targets?.proteinG
        carbsG = c.coachDouble(.carbsG) ?? targets?.carbsG
        fatG = c.coachDouble(.fatG) ?? targets?.fatG

        var goalType = c.coachString(.goalType) ?? nested.coachString(.phase)
        var targetWeight = c.coachDouble(.targetWeightKg)
        var goalDate = c.coachString(.goalDate)
        var weeklyRate = c.coachDouble(.weeklyRatePct)
        switch nested.coachJSON(.goal) {
        case .string(let value)?:
            goalType = goalType ?? value
        case .object(let goal)?:
            goalType = goalType
                ?? goal["goal_type"]?.stringValue
                ?? goal["phase"]?.stringValue
                ?? goal["type"]?.stringValue
            targetWeight = targetWeight
                ?? goal["target_weight_kg"]?.doubleValue
                ?? goal["goal_weight_kg"]?.doubleValue
            goalDate = goalDate ?? goal["goal_date"]?.stringValue
            weeklyRate = weeklyRate ?? goal["weekly_rate_pct"]?.doubleValue
        default:
            break
        }
        self.goalType = goalType
        self.targetWeightKg = targetWeight
        self.goalDate = goalDate
        self.weeklyRatePct = weeklyRate
    }
}

/// `goal_change` card.
struct GoalChangeCard: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case needsConfirmation = "needs_confirmation"
        case applied
        case undone
        case discarded
        case rejected
    }

    var changeId: UUID
    var status: Status
    var before: GoalSnapshot
    var after: GoalSnapshot
    var projectedGoalDate: String?
    var warnings: [String]

    var needsConfirmation: Bool { status == .needsConfirmation }

    init(
        changeId: UUID,
        status: Status,
        before: GoalSnapshot,
        after: GoalSnapshot,
        projectedGoalDate: String? = nil,
        warnings: [String] = []
    ) {
        self.changeId = changeId
        self.status = status
        self.before = before
        self.after = after
        self.projectedGoalDate = projectedGoalDate
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case status, before, after, warnings
        case changeId = "change_id"
        case projectedGoalDate = "projected_goal_date"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let changeId = c.coachUUID(.changeId) else {
            throw DecodingError.dataCorruptedError(
                forKey: .changeId,
                in: c,
                debugDescription: "goal change id is missing"
            )
        }
        self.changeId = changeId
        status = c.coachString(.status).flatMap(Status.init(rawValue:)) ?? .needsConfirmation
        before = c.coachDecode(.before) ?? GoalSnapshot()
        after = c.coachDecode(.after) ?? GoalSnapshot()
        projectedGoalDate = c.coachString(.projectedGoalDate)
        warnings = c.coachStrings(.warnings)
    }
}

/// `profile_update` card (bio / memory change with undo).
struct ProfileUpdateCard: Codable, Equatable, Sendable {
    struct Change: Codable, Equatable, Sendable, Identifiable {
        enum Operation: String, Codable, Sendable { case add, replace, remove }
        var section: String
        var op: Operation
        var summary: String

        var id: String { "\(section):\(op.rawValue):\(summary)" }
        /// Display title for a bio section key (falls back to the raw key).
        var sectionTitle: String {
            CoachBioSectionKey(rawValue: section)?.title
                ?? section.replacingOccurrences(of: "_", with: " ").capitalized
        }

        init(section: String, op: Operation, summary: String) {
            self.section = section
            self.op = op
            self.summary = summary
        }

        enum CodingKeys: String, CodingKey { case section, op, summary }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            section = c.coachString(.section) ?? "notes"
            op = c.coachString(.op).flatMap(Operation.init(rawValue:)) ?? .replace
            summary = c.coachString(.summary) ?? ""
        }
    }

    var memoryVersion: Int
    var changes: [Change]
    var undoVersion: Int?
    /// Optional server status after an action (`applied` | `undone`).
    var status: String?

    var isUndone: Bool { status == "undone" }

    init(memoryVersion: Int, changes: [Change], undoVersion: Int? = nil, status: String? = nil) {
        self.memoryVersion = memoryVersion
        self.changes = changes
        self.undoVersion = undoVersion
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case changes, status
        case memoryVersion = "memory_version"
        case undoVersion = "undo_version"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = c.coachInt(.memoryVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .memoryVersion,
                in: c,
                debugDescription: "memory version is missing"
            )
        }
        memoryVersion = version
        changes = c.coachArray(.changes)
        undoVersion = c.coachInt(.undoVersion)
        status = c.coachString(.status)
    }
}

/// `workout_ack` card.
struct WorkoutAckCard: Codable, Equatable, Sendable {
    struct PersonalRecord: Codable, Equatable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable { case e1rm, weight, reps }
        var exercise: String
        var kind: Kind
        var value: Double
        var unit: String
        var previous: Double?

        var id: String { "\(exercise):\(kind.rawValue)" }

        init(exercise: String, kind: Kind, value: Double, unit: String, previous: Double? = nil) {
            self.exercise = exercise
            self.kind = kind
            self.value = value
            self.unit = unit
            self.previous = previous
        }

        enum CodingKeys: String, CodingKey { case exercise, kind, value, unit, previous }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let exercise = c.coachString(.exercise), let value = c.coachDouble(.value) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .exercise,
                    in: c,
                    debugDescription: "personal record is incomplete"
                )
            }
            self.exercise = exercise
            self.value = value
            kind = c.coachString(.kind).flatMap(Kind.init(rawValue:)) ?? .weight
            unit = c.coachString(.unit) ?? "lb"
            previous = c.coachDouble(.previous)
        }
    }

    var activityId: UUID?
    var prs: [PersonalRecord]

    init(activityId: UUID?, prs: [PersonalRecord] = []) {
        self.activityId = activityId
        self.prs = prs
    }

    enum CodingKeys: String, CodingKey {
        case prs
        case activityId = "activity_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activityId = c.coachUUID(.activityId)
        prs = c.coachArray(.prs)
    }
}

/// `weigh_in_ack` / `photo_feedback` card (body check-in).
struct CheckInCard: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case weighInAck = "weigh_in_ack"
        case photoFeedback = "photo_feedback"
    }

    struct Review: Codable, Equatable, Sendable {
        var headline: String
        var observations: [String]
        /// Free-form quality label from the physique review (e.g. `on_track`).
        var bulkQuality: String?

        init(headline: String, observations: [String] = [], bulkQuality: String? = nil) {
            self.headline = headline
            self.observations = observations
            self.bulkQuality = bulkQuality
        }

        enum CodingKeys: String, CodingKey {
            case headline, observations
            case bulkQuality = "bulk_quality"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            headline = c.coachString(.headline) ?? ""
            observations = c.coachStrings(.observations)
            bulkQuality = c.coachString(.bulkQuality)
        }
    }

    var kind: Kind
    var localDay: String
    var photoPath: String?
    var weightKg: Double?
    var review: Review?

    init(
        kind: Kind,
        localDay: String,
        photoPath: String? = nil,
        weightKg: Double? = nil,
        review: Review? = nil
    ) {
        self.kind = kind
        self.localDay = localDay
        self.photoPath = photoPath
        self.weightKg = weightKg
        self.review = review
    }

    enum CodingKeys: String, CodingKey {
        case kind, review
        case localDay = "local_day"
        case photoPath = "photo_path"
        case weightKg = "weight_kg"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.coachString(.kind).flatMap(Kind.init(rawValue:)) ?? .weighInAck
        localDay = c.coachString(.localDay) ?? ""
        photoPath = c.coachString(.photoPath)
        weightKg = c.coachDouble(.weightKg)
        review = c.coachDecode(.review)
    }
}

/// `recap` card: a day recap or the weekly-summary pointer.
struct RecapCard: Codable, Equatable, Sendable {
    enum Period: String, Codable, Sendable { case day, week }

    var period: Period?
    var kcal: Double?
    var proteinG: Double?
    var kcalTarget: Double?
    var proteinTargetG: Double?
    var headline: String?
    var score: Double?
    /// Weekly recap: `weekly_summaries.id` and its week start.
    var summaryId: UUID?
    var weekStart: String?

    init(
        period: Period? = nil,
        kcal: Double? = nil,
        proteinG: Double? = nil,
        kcalTarget: Double? = nil,
        proteinTargetG: Double? = nil,
        headline: String? = nil,
        score: Double? = nil,
        summaryId: UUID? = nil,
        weekStart: String? = nil
    ) {
        self.period = period
        self.kcal = kcal
        self.proteinG = proteinG
        self.kcalTarget = kcalTarget
        self.proteinTargetG = proteinTargetG
        self.headline = headline
        self.score = score
        self.summaryId = summaryId
        self.weekStart = weekStart
    }

    enum CodingKeys: String, CodingKey {
        case kcal, headline, score
        case period = "kind"
        case proteinG = "protein_g"
        case kcalTarget = "kcal_target"
        case proteinTargetG = "protein_target_g"
        case summaryId = "summary_id"
        case weekStart = "week_start"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summaryId = c.coachUUID(.summaryId)
        weekStart = c.coachString(.weekStart)
        period = c.coachString(.period).flatMap(Period.init(rawValue:))
            ?? (summaryId != nil || weekStart != nil ? .week : nil)
        kcal = c.coachDouble(.kcal)
        proteinG = c.coachDouble(.proteinG)
        kcalTarget = c.coachDouble(.kcalTarget)
        proteinTargetG = c.coachDouble(.proteinTargetG)
        headline = c.coachString(.headline)
        score = c.coachDouble(.score)
    }

    /// True when the payload carried no card data (a plain recap text slot).
    var isEmpty: Bool {
        kcal == nil && proteinG == nil && headline == nil && summaryId == nil
            && weekStart == nil && score == nil
    }
}

/// `plan` card: the morning game plan.
struct PlanCard: Codable, Equatable, Sendable {
    var theme: String?
    var remaining: CoachMacros?
    var actions: [String]

    init(theme: String? = nil, remaining: CoachMacros? = nil, actions: [String] = []) {
        self.theme = theme
        self.remaining = remaining
        self.actions = actions
    }

    enum CodingKeys: String, CodingKey { case theme, remaining, actions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = c.coachString(.theme)
        remaining = c.coachDecode(.remaining)
        actions = c.coachStrings(.actions)
    }

    var isEmpty: Bool { theme == nil && remaining == nil && actions.isEmpty }
}

/// The typed card for a message, discriminated by `CoachMessage.kind`.
enum CoachPayload: Equatable, Sendable {
    case none
    case snackRec(SnackRec)
    case trainingPlan(TrainingPlanCard)
    case goalChange(GoalChangeCard)
    case profileUpdate(ProfileUpdateCard)
    case mealAck(entryId: UUID)
    case workoutAck(WorkoutAckCard)
    case checkIn(CheckInCard)
    case recap(RecapCard)
    case plan(PlanCard)
    case unknown(type: String)

    var hasCard: Bool {
        switch self {
        case .none, .unknown: return false
        default: return true
        }
    }

    static func make(
        kind: String,
        raw: CoachJSON,
        localDay: String,
        entryId: UUID?,
        activityId: UUID?
    ) -> CoachPayload {
        guard let known = CoachMessageKind(rawValue: kind) else { return .unknown(type: kind) }
        switch known {
        case .text, .checkpoint, .photo, .event:
            return .none
        case .plan:
            guard let card = raw.decoded(as: PlanCard.self) else { return .none }
            return card.isEmpty ? .none : .plan(card)
        case .recap:
            guard let card = raw.decoded(as: RecapCard.self) else { return .none }
            return card.isEmpty ? .none : .recap(card)
        case .snackRec:
            return raw.decoded(as: SnackRec.self).map(CoachPayload.snackRec) ?? .unknown(type: kind)
        case .trainingPlan:
            return raw.decoded(as: TrainingPlanCard.self).map(CoachPayload.trainingPlan)
                ?? .unknown(type: kind)
        case .goalChange:
            return raw.decoded(as: GoalChangeCard.self).map(CoachPayload.goalChange)
                ?? .unknown(type: kind)
        case .profileUpdate:
            return raw.decoded(as: ProfileUpdateCard.self).map(CoachPayload.profileUpdate)
                ?? .unknown(type: kind)
        case .mealAck:
            guard let id = raw["entry_id"]?.uuidValue ?? entryId else { return .unknown(type: kind) }
            return .mealAck(entryId: id)
        case .workoutAck:
            guard var card = raw.decoded(as: WorkoutAckCard.self) else { return .unknown(type: kind) }
            card.activityId = card.activityId ?? activityId
            guard card.activityId != nil else { return .unknown(type: kind) }
            return .workoutAck(card)
        case .weighInAck, .photoFeedback:
            guard var card = raw.decoded(as: CheckInCard.self) else { return .unknown(type: kind) }
            card.kind = known == .photoFeedback ? .photoFeedback : .weighInAck
            if card.localDay.isEmpty { card.localDay = localDay }
            return .checkIn(card)
        }
    }
}

// MARK: - Location (no coordinates, ever)

struct NearbyStore: Codable, Equatable, Hashable, Sendable, Identifiable {
    enum WalkMinutesSource: String, Codable, Sendable {
        case mapkitETA = "mapkit_eta"
        case estimate
    }

    /// Short stable reference (hash of the MapKit place id); `store_ref` in
    /// snack cards points back here.
    var ref: String
    var name: String
    /// Our store type: `convenience|grocery|pharmacy|gas_station|cafe|bakery|restaurant`.
    var category: String
    var distanceM: Int
    var walkMinutes: Int
    var walkMinutesSource: WalkMinutesSource
    var addressShort: String?

    var id: String { ref }

    init(
        ref: String,
        name: String,
        category: String,
        distanceM: Int,
        walkMinutes: Int,
        walkMinutesSource: WalkMinutesSource,
        addressShort: String? = nil
    ) {
        self.ref = ref
        self.name = name
        self.category = category
        self.distanceM = distanceM
        self.walkMinutes = walkMinutes
        self.walkMinutesSource = walkMinutesSource
        self.addressShort = addressShort
    }

    enum CodingKeys: String, CodingKey {
        case ref, name, category
        case distanceM = "distance_m"
        case walkMinutes = "walk_minutes"
        case walkMinutesSource = "walk_minutes_source"
        case addressShort = "address_short"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = c.coachString(.ref) ?? ""
        name = c.coachString(.name) ?? ""
        category = c.coachString(.category) ?? "store"
        distanceM = c.coachInt(.distanceM) ?? 0
        walkMinutes = c.coachInt(.walkMinutes) ?? 0
        walkMinutesSource = c.coachString(.walkMinutesSource)
            .flatMap(WalkMinutesSource.init(rawValue:)) ?? .estimate
        addressShort = c.coachString(.addressShort)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ref, forKey: .ref)
        try c.encode(name, forKey: .name)
        try c.encode(category, forKey: .category)
        try c.encode(distanceM, forKey: .distanceM)
        try c.encode(walkMinutes, forKey: .walkMinutes)
        try c.encode(walkMinutesSource, forKey: .walkMinutesSource)
        if let addressShort {
            try c.encode(addressShort, forKey: .addressShort)
        } else {
            try c.encodeNil(forKey: .addressShort)
        }
    }
}

/// What the coach knows about "near you": locality strings and a store list.
/// Coordinates and geohashes never leave the phone (SPEC §4, §5.5).
struct LocationContext: Codable, Equatable, Sendable {
    enum Quality: String, Codable, Sendable {
        case precise
        case approximate
        case none
    }

    struct Locality: Codable, Equatable, Sendable {
        var neighborhood: String?
        var city: String?
        var region: String?
        /// ISO 3166-1 alpha-2.
        var country: String?
        var timezone: String

        init(
            neighborhood: String? = nil,
            city: String? = nil,
            region: String? = nil,
            country: String? = nil,
            timezone: String
        ) {
            self.neighborhood = neighborhood
            self.city = city
            self.region = region
            self.country = country
            self.timezone = timezone
        }

        enum CodingKeys: String, CodingKey { case neighborhood, city, region, country, timezone }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            neighborhood = c.coachString(.neighborhood)
            city = c.coachString(.city)
            region = c.coachString(.region)
            country = c.coachString(.country)
            timezone = c.coachString(.timezone) ?? TimeZone.autoupdatingCurrent.identifier
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            for (key, value) in [
                (CodingKeys.neighborhood, neighborhood),
                (.city, city),
                (.region, region),
                (.country, country),
            ] {
                if let value { try c.encode(value, forKey: key) } else { try c.encodeNil(forKey: key) }
            }
            try c.encode(timezone, forKey: .timezone)
        }
    }

    var capturedAt: Date
    var quality: Quality
    var locality: Locality
    var stores: [NearbyStore]

    init(capturedAt: Date, quality: Quality, locality: Locality, stores: [NearbyStore]) {
        self.capturedAt = capturedAt
        self.quality = quality
        self.locality = locality
        self.stores = stores
    }

    enum CodingKeys: String, CodingKey {
        case quality, locality, stores
        case capturedAt = "captured_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capturedAt = c.coachDate(.capturedAt) ?? Date(timeIntervalSince1970: 0)
        quality = c.coachString(.quality).flatMap(Quality.init(rawValue:)) ?? .none
        locality = c.coachDecode(.locality)
            ?? Locality(timezone: TimeZone.autoupdatingCurrent.identifier)
        stores = c.coachArray(.stores)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(CoachDateCoding.string(from: capturedAt), forKey: .capturedAt)
        try c.encode(quality, forKey: .quality)
        try c.encode(locality, forKey: .locality)
        try c.encode(stores, forKey: .stores)
    }

    func age(at now: Date) -> TimeInterval { now.timeIntervalSince(capturedAt) }
}

// MARK: - Requests and stream events

enum CoachInputMode: String, Codable, Equatable, Sendable {
    case typed
    case dictated
    case notificationReply = "notification_reply"
}

/// `context_hint` on coach_chat: what the capture bar was capturing for.
/// train → treat as a workout log, body → weight / check-in, bio → bio
/// update; nil is the plain chat.
enum CoachContextHint: String, Codable, Equatable, Sendable {
    case bio
    case train
    case body
}

/// `POST coach_chat` (send shape, SPEC §3.1).
struct CoachSendRequest: Codable, Equatable, Sendable {
    static let maximumTextLength = 4000

    var clientRequestId: UUID
    var text: String
    var inputMode: CoachInputMode
    /// `apple.speech_transcriber` etc. (VoiceTake.engine raw value) for dictation.
    var speechEngine: String?
    var localDay: String
    var timezone: String
    /// A `coach-media` object path from `CoachServing.uploadAttachment`.
    var attachmentPath: String?
    var location: LocationContext?
    var contextHint: CoachContextHint?

    init(
        clientRequestId: UUID = UUID(),
        text: String,
        inputMode: CoachInputMode = .typed,
        speechEngine: String? = nil,
        localDay: String,
        timezone: String,
        attachmentPath: String? = nil,
        location: LocationContext? = nil,
        contextHint: CoachContextHint? = nil
    ) {
        self.clientRequestId = clientRequestId
        self.text = text
        self.inputMode = inputMode
        self.speechEngine = speechEngine
        self.localDay = localDay
        self.timezone = timezone
        self.attachmentPath = attachmentPath
        self.location = location
        self.contextHint = contextHint
    }

    enum CodingKeys: String, CodingKey {
        case text, timezone, location
        case clientRequestId = "client_request_id"
        case inputMode = "input_mode"
        case speechEngine = "speech_engine"
        case localDay = "local_day"
        case attachmentPath = "attachment_path"
        case contextHint = "context_hint"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.coachUUID(.clientRequestId) else {
            throw DecodingError.dataCorruptedError(
                forKey: .clientRequestId,
                in: c,
                debugDescription: "client_request_id is missing"
            )
        }
        clientRequestId = id
        text = c.coachString(.text) ?? ""
        inputMode = c.coachString(.inputMode).flatMap(CoachInputMode.init(rawValue:)) ?? .typed
        speechEngine = c.coachString(.speechEngine)
        localDay = c.coachString(.localDay) ?? ""
        timezone = c.coachString(.timezone) ?? TimeZone.autoupdatingCurrent.identifier
        attachmentPath = c.coachString(.attachmentPath)
        location = c.coachDecode(.location)
        contextHint = c.coachString(.contextHint).flatMap(CoachContextHint.init(rawValue:))
    }

    /// Every nullable field is sent explicitly as `null`.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientRequestId.uuidString.lowercased(), forKey: .clientRequestId)
        try c.encode(text, forKey: .text)
        try c.encode(inputMode, forKey: .inputMode)
        try c.encode(localDay, forKey: .localDay)
        try c.encode(timezone, forKey: .timezone)
        if let speechEngine { try c.encode(speechEngine, forKey: .speechEngine) } else {
            try c.encodeNil(forKey: .speechEngine)
        }
        if let attachmentPath { try c.encode(attachmentPath, forKey: .attachmentPath) } else {
            try c.encodeNil(forKey: .attachmentPath)
        }
        if let location { try c.encode(location, forKey: .location) } else {
            try c.encodeNil(forKey: .location)
        }
        if let contextHint { try c.encode(contextHint, forKey: .contextHint) } else {
            try c.encodeNil(forKey: .contextHint)
        }
    }
}

/// A terminal failure reported by the server inside the event stream.
struct CoachStreamFailure: Error, Equatable, Sendable, LocalizedError {
    var code: String
    var message: String
    var retryable: Bool

    var errorDescription: String? { message }
}

/// One `data:` line of the `coach_chat` SSE stream (SPEC §3.1).
enum CoachStreamEvent: Equatable, Sendable {
    case accepted(runId: UUID?, userMessage: CoachMessage?, duplicate: Bool)
    case status(label: String)
    case delta(messageId: UUID, text: String)
    case message(CoachMessage)
    case done(runId: UUID?, messageIds: [UUID])
    case error(CoachStreamFailure)
}

extension CoachStreamEvent: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type, label, text, message, duplicate, code, retryable
        case runId = "run_id"
        case userMessage = "user_message"
        case messageId = "message_id"
        case messageIds = "message_ids"
    }

    /// Thrown for well-formed JSON whose `type` this build doesn't know.
    struct UnknownEventType: Error { let type: String }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = c.coachString(.type) ?? ""
        switch type {
        case "accepted":
            self = .accepted(
                runId: c.coachUUID(.runId),
                userMessage: c.coachDecode(.userMessage),
                duplicate: c.coachBool(.duplicate) ?? false
            )
        case "status":
            self = .status(label: c.coachString(.label) ?? "")
        case "delta":
            guard let id = c.coachUUID(.messageId) else { throw UnknownEventType(type: type) }
            self = .delta(messageId: id, text: c.coachString(.text) ?? "")
        case "message":
            guard let message: CoachMessage = c.coachDecode(.message) else {
                throw UnknownEventType(type: type)
            }
            self = .message(message)
        case "done":
            self = .done(
                runId: c.coachUUID(.runId),
                messageIds: c.coachStrings(.messageIds).compactMap(UUID.init(uuidString:))
            )
        case "error":
            self = .error(CoachStreamFailure(
                code: c.coachString(.code) ?? "error",
                message: c.coachString(.message) ?? "Shudo couldn’t answer that.",
                retryable: c.coachBool(.retryable) ?? false
            ))
        default:
            throw UnknownEventType(type: type)
        }
    }
}

/// `POST coach_chat` (card action shape) → `{"messages":[CoachMessageRow]}`.
struct CoachCardAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case goalChange = "goal_change"
        case trainingPlan = "training_plan"
        case bioUpdate = "bio_update"
        case nearby
    }

    enum Decision: String, Codable, Sendable {
        case apply, discard, undo, activate
    }

    var clientRequestId: UUID
    var kind: Kind
    /// `change_id` (goal), `plan_id` (training plan), or the card message id
    /// (bio update, nearby).
    var id: UUID
    var decision: Decision

    init(clientRequestId: UUID = UUID(), kind: Kind, id: UUID, decision: Decision) {
        self.clientRequestId = clientRequestId
        self.kind = kind
        self.id = id
        self.decision = decision
    }

    static func goalChange(_ card: GoalChangeCard, decision: Decision) -> CoachCardAction {
        CoachCardAction(kind: .goalChange, id: card.changeId, decision: decision)
    }

    static func trainingPlan(_ card: TrainingPlanCard, decision: Decision) -> CoachCardAction {
        CoachCardAction(kind: .trainingPlan, id: card.planId, decision: decision)
    }

    static func bioUpdate(messageId: UUID, decision: Decision) -> CoachCardAction {
        CoachCardAction(kind: .bioUpdate, id: messageId, decision: decision)
    }

    static func nearby(messageId: UUID, decision: Decision) -> CoachCardAction {
        CoachCardAction(kind: .nearby, id: messageId, decision: decision)
    }

    /// Identifies "the same tap" across retries so the VM can reuse one
    /// idempotency key.
    var dedupeKey: String { "\(kind.rawValue):\(id.uuidString.lowercased()):\(decision.rawValue)" }

    private enum CodingKeys: String, CodingKey {
        case action
        case clientRequestId = "client_request_id"
    }

    private enum ActionKeys: String, CodingKey { case kind, id, decision }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let action = try c.nestedContainer(keyedBy: ActionKeys.self, forKey: .action)
        clientRequestId = c.coachUUID(.clientRequestId) ?? UUID()
        kind = try action.decode(Kind.self, forKey: .kind)
        id = try action.decode(UUID.self, forKey: .id)
        decision = try action.decode(Decision.self, forKey: .decision)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientRequestId.uuidString.lowercased(), forKey: .clientRequestId)
        var action = c.nestedContainer(keyedBy: ActionKeys.self, forKey: .action)
        try action.encode(kind, forKey: .kind)
        try action.encode(id.uuidString.lowercased(), forKey: .id)
        try action.encode(decision, forKey: .decision)
    }
}

// MARK: - Sync

/// `POST coach_sync` (SPEC §3.2).
struct CoachSyncRequest: Encodable, Equatable, Sendable {
    enum Trigger: String, Codable, Sendable {
        case foreground
        case mealComplete = "meal_complete"
        case activityComplete = "activity_complete"
        case checkin
        case settings
        case bgRefresh = "bg_refresh"
        case chat
    }

    enum NotificationStatus: String, Codable, Sendable {
        case authorized, denied, provisional
        case notDetermined = "not_determined"
    }

    enum LocationStatus: String, Codable, Sendable {
        case denied
        case whenInUse = "when_in_use"
        case notDetermined = "not_determined"
    }

    struct Device: Encodable, Equatable, Sendable {
        var deviceId: UUID
        var appVersion: String
        var osVersion: String
        var notificationStatus: NotificationStatus
        var locationStatus: LocationStatus

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case appVersion = "app_version"
            case osVersion = "os_version"
            case notificationStatus = "notification_status"
            case locationStatus = "location_status"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(deviceId.uuidString.lowercased(), forKey: .deviceId)
            try c.encode(appVersion, forKey: .appVersion)
            try c.encode(osVersion, forKey: .osVersion)
            try c.encode(notificationStatus, forKey: .notificationStatus)
            try c.encode(locationStatus, forKey: .locationStatus)
        }
    }

    var trigger: Trigger
    var localDay: String
    var timezone: String
    var entryId: UUID?
    var activityId: UUID?
    var device: Device
    var location: LocationContext?
    var wait: Bool

    enum CodingKeys: String, CodingKey {
        case trigger, timezone, device, location, wait
        case localDay = "local_day"
        case entryId = "entry_id"
        case activityId = "activity_id"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(localDay, forKey: .localDay)
        try c.encode(timezone, forKey: .timezone)
        if let entryId { try c.encode(entryId.uuidString.lowercased(), forKey: .entryId) } else {
            try c.encodeNil(forKey: .entryId)
        }
        if let activityId { try c.encode(activityId.uuidString.lowercased(), forKey: .activityId) } else {
            try c.encodeNil(forKey: .activityId)
        }
        try c.encode(device, forKey: .device)
        if let location { try c.encode(location, forKey: .location) } else {
            try c.encodeNil(forKey: .location)
        }
        try c.encode(wait, forKey: .wait)
    }
}

struct CoachSyncResponse: Decodable, Equatable, Sendable {
    var planRunId: UUID?
    var generated: Bool
    var serverTime: Date?

    init(planRunId: UUID? = nil, generated: Bool = false, serverTime: Date? = nil) {
        self.planRunId = planRunId
        self.generated = generated
        self.serverTime = serverTime
    }

    enum CodingKeys: String, CodingKey {
        case generated
        case planRunId = "plan_run_id"
        case serverTime = "server_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planRunId = c.coachUUID(.planRunId)
        generated = c.coachBool(.generated) ?? false
        serverTime = c.coachDate(.serverTime)
    }
}

// MARK: - Memory (bio + coach notes)

/// User-owned bio sections, in display order (SPEC §2 `coach_memory`).
enum CoachBioSectionKey: String, CaseIterable, Sendable {
    case about
    case roleModels = "role_models"
    case schedule
    case trainingHistory = "training_history"
    case currentTraining = "current_training"
    case nutrition
    case sleep
    case goals
    case equipment
    case handleWithCare = "handle_with_care"

    var title: String {
        switch self {
        case .about: return "About"
        case .roleModels: return "Role models"
        case .schedule: return "Schedule"
        case .trainingHistory: return "Training history"
        case .currentTraining: return "Current training"
        case .nutrition: return "Nutrition"
        case .sleep: return "Sleep"
        case .goals: return "Goals"
        case .equipment: return "Equipment"
        case .handleWithCare: return "Handle with care"
        }
    }
}

struct CoachBioSection: Identifiable, Equatable, Sendable {
    var key: String
    var title: String
    var markdown: String
    var id: String { key }
}

/// Structured schedule used by the checkpoint policy (all fields optional).
struct CoachSchedule: Codable, Equatable, Sendable {
    var wake: String?
    var officeStart: String?
    var officeDays: [String]
    var liftDays: [String]
    var liftTime: String?
    var bed: String?
    var targetBed: String?

    init(
        wake: String? = nil,
        officeStart: String? = nil,
        officeDays: [String] = [],
        liftDays: [String] = [],
        liftTime: String? = nil,
        bed: String? = nil,
        targetBed: String? = nil
    ) {
        self.wake = wake
        self.officeStart = officeStart
        self.officeDays = officeDays
        self.liftDays = liftDays
        self.liftTime = liftTime
        self.bed = bed
        self.targetBed = targetBed
    }

    enum CodingKeys: String, CodingKey {
        case wake, bed
        case officeStart = "office_start"
        case officeDays = "office_days"
        case liftDays = "lift_days"
        case liftTime = "lift_time"
        case targetBed = "target_bed"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wake = c.coachString(.wake)
        officeStart = c.coachString(.officeStart)
        officeDays = c.coachStrings(.officeDays)
        liftDays = c.coachStrings(.liftDays)
        liftTime = c.coachString(.liftTime)
        bed = c.coachString(.bed)
        targetBed = c.coachString(.targetBed)
    }
}

/// The one living `coach_memory` document: Luke's bio (user-owned sections)
/// plus what the coach has observed.
struct CoachMemoryDocument: Decodable, Equatable, Sendable {
    var version: Int
    var document: String
    /// Known bio sections first (fixed order), then any extra keys A→Z.
    var bio: [CoachBioSection]
    var notes: [String: String]
    var schedule: CoachSchedule?
    var equipment: [String]
    var updatedSource: String?
    var updatedAt: Date?

    static let empty = CoachMemoryDocument(
        version: 0,
        document: "",
        bio: [],
        notes: [:],
        schedule: nil,
        equipment: [],
        updatedSource: nil,
        updatedAt: nil
    )

    var isEmpty: Bool { version == 0 && document.isEmpty && bio.isEmpty }

    init(
        version: Int,
        document: String,
        bio: [CoachBioSection],
        notes: [String: String],
        schedule: CoachSchedule?,
        equipment: [String],
        updatedSource: String?,
        updatedAt: Date?
    ) {
        self.version = version
        self.document = document
        self.bio = bio
        self.notes = notes
        self.schedule = schedule
        self.equipment = equipment
        self.updatedSource = updatedSource
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case version, document, sections
        case updatedSource = "updated_source"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.coachInt(.version) ?? 0
        document = c.coachString(.document) ?? ""
        updatedSource = c.coachString(.updatedSource)
        updatedAt = c.coachDate(.updatedAt)
        let sections = c.coachJSON(.sections)?.objectValue ?? [:]
        bio = Self.bioSections(sections["bio"]?.objectValue ?? [:])
        notes = (sections["notes"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        schedule = sections["schedule"].flatMap { $0.decoded(as: CoachSchedule.self) }
        if case .array(let values)? = sections["equipment"] {
            equipment = values.compactMap(\.stringValue)
        } else {
            equipment = []
        }
    }

    func section(_ key: CoachBioSectionKey) -> CoachBioSection? {
        bio.first { $0.key == key.rawValue }
    }

    static func bioSections(_ raw: [String: CoachJSON]) -> [CoachBioSection] {
        var sections: [CoachBioSection] = []
        for key in CoachBioSectionKey.allCases {
            guard let text = raw[key.rawValue]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            sections.append(CoachBioSection(key: key.rawValue, title: key.title, markdown: text))
        }
        let known = Set(CoachBioSectionKey.allCases.map(\.rawValue))
        for key in raw.keys.filter({ !known.contains($0) }).sorted() {
            guard let text = raw[key]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            sections.append(CoachBioSection(
                key: key,
                title: key.replacingOccurrences(of: "_", with: " ").capitalized,
                markdown: text
            ))
        }
        return sections
    }
}

// MARK: - Settings (profiles columns)

/// A wall-clock time like quiet hours. PostgREST returns `time` columns as
/// `HH:MM:SS`; we send `HH:MM`.
struct CoachClockTime: Codable, Equatable, Hashable, Comparable, Sendable {
    var hour: Int
    var minute: Int

    init(hour: Int, minute: Int) {
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
    }

    init?(string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.init(hour: hour, minute: minute)
    }

    var minutesFromMidnight: Int { hour * 60 + minute }
    var string: String { String(format: "%02d:%02d", hour, minute) }

    static func < (lhs: CoachClockTime, rhs: CoachClockTime) -> Bool {
        lhs.minutesFromMidnight < rhs.minutesFromMidnight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = CoachClockTime(string: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid time \(raw)")
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }

    /// True when `minutes` (from local midnight) falls in [start, end),
    /// wrapping past midnight when start > end.
    static func isWithin(_ minutes: Int, start: CoachClockTime, end: CoachClockTime) -> Bool {
        let s = start.minutesFromMidnight
        let e = end.minutesFromMidnight
        if s == e { return false }
        return s < e ? (minutes >= s && minutes < e) : (minutes >= s || minutes < e)
    }
}

/// Coach settings, stored as `profiles` columns and client-updatable via
/// column grants (SPEC §2).
struct CoachSettings: Codable, Equatable, Sendable {
    enum Intensity: String, Codable, CaseIterable, Sendable {
        case chill
        case lockedIn = "locked_in"
        case drillSergeant = "drill_sergeant"

        var title: String {
            switch self {
            case .chill: return "Chill"
            case .lockedIn: return "Locked in"
            case .drillSergeant: return "Drill sergeant"
            }
        }
    }

    enum Profanity: String, Codable, CaseIterable, Sendable {
        case off, mild, salty

        var title: String {
            switch self {
            case .off: return "Clean"
            case .mild: return "Mild"
            case .salty: return "Salty"
            }
        }
    }

    var enabled: Bool
    var intensity: Intensity
    var profanity: Profanity
    var quietHoursStart: CoachClockTime
    var quietHoursEnd: CoachClockTime
    var locationRecsEnabled: Bool
    var physiqueAIReviewEnabled: Bool

    static let defaults = CoachSettings(
        enabled: false,
        intensity: .lockedIn,
        profanity: .mild,
        quietHoursStart: CoachClockTime(hour: 23, minute: 0),
        quietHoursEnd: CoachClockTime(hour: 7, minute: 0),
        locationRecsEnabled: false,
        physiqueAIReviewEnabled: false
    )

    /// The exact `profiles` columns this maps to (PostgREST `select=`).
    static let profileColumns = CodingKeys.allCases.map(\.rawValue).joined(separator: ",")

    init(
        enabled: Bool,
        intensity: Intensity,
        profanity: Profanity,
        quietHoursStart: CoachClockTime,
        quietHoursEnd: CoachClockTime,
        locationRecsEnabled: Bool,
        physiqueAIReviewEnabled: Bool
    ) {
        self.enabled = enabled
        self.intensity = intensity
        self.profanity = profanity
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.locationRecsEnabled = locationRecsEnabled
        self.physiqueAIReviewEnabled = physiqueAIReviewEnabled
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case enabled = "coach_enabled"
        case intensity = "coach_intensity"
        case profanity = "coach_profanity"
        case quietHoursStart = "quiet_hours_start"
        case quietHoursEnd = "quiet_hours_end"
        case locationRecsEnabled = "location_recs_enabled"
        case physiqueAIReviewEnabled = "physique_ai_review_enabled"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CoachSettings.defaults
        enabled = c.coachBool(.enabled) ?? defaults.enabled
        intensity = c.coachString(.intensity).flatMap(Intensity.init(rawValue:)) ?? defaults.intensity
        profanity = c.coachString(.profanity).flatMap(Profanity.init(rawValue:)) ?? defaults.profanity
        quietHoursStart = c.coachString(.quietHoursStart).flatMap(CoachClockTime.init(string:))
            ?? defaults.quietHoursStart
        quietHoursEnd = c.coachString(.quietHoursEnd).flatMap(CoachClockTime.init(string:))
            ?? defaults.quietHoursEnd
        locationRecsEnabled = c.coachBool(.locationRecsEnabled) ?? defaults.locationRecsEnabled
        physiqueAIReviewEnabled = c.coachBool(.physiqueAIReviewEnabled)
            ?? defaults.physiqueAIReviewEnabled
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(intensity, forKey: .intensity)
        try c.encode(profanity, forKey: .profanity)
        try c.encode(quietHoursStart, forKey: .quietHoursStart)
        try c.encode(quietHoursEnd, forKey: .quietHoursEnd)
        try c.encode(locationRecsEnabled, forKey: .locationRecsEnabled)
        try c.encode(physiqueAIReviewEnabled, forKey: .physiqueAIReviewEnabled)
    }

    func isQuietHour(_ date: Date, timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return CoachClockTime.isWithin(minutes, start: quietHoursStart, end: quietHoursEnd)
    }
}

// MARK: - Local days

enum CoachLocalDay {
    /// `YYYY-MM-DD` in `timeZone`, midnight boundary (matches entries).
    static func string(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// `YYYY-MM-DD` and a real calendar date.
    static func isValid(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return false
        }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        return components.isValidDate(in: Calendar(identifier: .gregorian))
    }
}
