import Foundation

// MARK: - Activities (public.activities)
//
// Workouts live in their own table, never in meal `entries`. Rows arrive via
// PostgREST (RLS select-own) and are written only by the `log_activity` edge
// function. Decoding is deliberately tolerant: an unknown kind, a malformed
// set, or a number serialized as a string must never sink the whole list.

enum ActivityStatus: String, Codable, Equatable, Sendable {
    case processing
    case complete
    case failed
}

enum ActivityKind: String, Codable, CaseIterable, Equatable, Sendable {
    case strength
    case cardio
    case walk
    case run
    case cycle
    case swim
    case hiit
    case sport
    case mobility
    case other

    init(lossy raw: String?) {
        let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = Self(rawValue: normalized) ?? .other
    }

    var symbolName: String {
        switch self {
        case .strength: return "dumbbell.fill"
        case .cardio: return "figure.mixed.cardio"
        case .walk: return "figure.walk"
        case .run: return "figure.run"
        case .cycle: return "figure.outdoor.cycle"
        case .swim: return "figure.pool.swim"
        case .hiit: return "figure.highintensity.intervaltraining"
        case .sport: return "sportscourt.fill"
        case .mobility: return "figure.flexibility"
        case .other: return "bolt.heart.fill"
        }
    }

    var label: String {
        switch self {
        case .strength: return "Strength"
        case .cardio: return "Cardio"
        case .walk: return "Walk"
        case .run: return "Run"
        case .cycle: return "Ride"
        case .swim: return "Swim"
        case .hiit: return "HIIT"
        case .sport: return "Sport"
        case .mobility: return "Mobility"
        case .other: return "Workout"
        }
    }
}

enum ActivityIntensity: String, Codable, Equatable, Sendable {
    case easy
    case moderate
    case hard
    case max

    var label: String { rawValue.capitalized }
}

enum WeightUnit: String, Codable, Equatable, Hashable, Sendable {
    case lb
    case kg

    static let poundsPerKilogram = 2.204_622_6

    init(lossy raw: String?, fallback: WeightUnit = .lb) {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "lb", "lbs", "pound", "pounds": self = .lb
        case "kg", "kgs", "kilo", "kilos", "kilogram", "kilograms": self = .kg
        default: self = fallback
        }
    }

    /// The unit a profile's `units` preference implies for bare numbers.
    init(preference units: String) {
        self = units.lowercased() == "metric" ? .kg : .lb
    }
}

struct ActivitySet: Codable, Equatable, Hashable, Sendable {
    var reps: Int
    var weight: Double?
    var unit: WeightUnit
    var isWarmup: Bool
    var rpe: Double?

    init(reps: Int, weight: Double? = nil, unit: WeightUnit = .lb, isWarmup: Bool = false, rpe: Double? = nil) {
        self.reps = reps
        self.weight = weight
        self.unit = unit
        self.isWarmup = isWarmup
        self.rpe = rpe
    }

    /// Positive load normalized to pounds; nil for bodyweight sets.
    var weightInPounds: Double? {
        guard let weight, weight > 0, weight.isFinite else { return nil }
        return unit == .kg ? weight * WeightUnit.poundsPerKilogram : weight
    }

    var isWorking: Bool { !isWarmup && reps > 0 }

    enum CodingKeys: String, CodingKey {
        case reps, weight, unit, rpe
        case isWarmup = "is_warmup"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reps = max(0, container.trainLossyInt(.reps) ?? 0)
        let decodedWeight = container.trainLossyDouble(.weight)
        weight = decodedWeight.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        unit = WeightUnit(lossy: container.trainLossyString(.unit))
        isWarmup = container.trainLossyBool(.isWarmup) ?? false
        rpe = container.trainLossyDouble(.rpe)
    }
}

struct ActivityExercise: Codable, Equatable, Hashable, Sendable {
    var name: String
    var key: String?
    var sets: [ActivitySet]

    init(name: String, key: String? = nil, sets: [ActivitySet]) {
        self.name = name
        self.key = key
        self.sets = sets
    }

    var workingSets: [ActivitySet] { sets.filter(\.isWorking) }

    /// Heaviest working set (ties broken by reps); for bodyweight work, the
    /// set with the most reps.
    var topSet: ActivitySet? {
        workingSets.max { lhs, rhs in
            let lw = lhs.weightInPounds ?? 0
            let rw = rhs.weightInPounds ?? 0
            if lw != rw { return lw < rw }
            return lhs.reps < rhs.reps
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, key, sets
        case displayName = "display_name"
        case exerciseKey = "exercise_key"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawName = container.trainLossyString(.name) ?? container.trainLossyString(.displayName) ?? ""
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: container, debugDescription: "Exercise has no name")
        }
        name = trimmed
        key = (container.trainLossyString(.key) ?? container.trainLossyString(.exerciseKey))
            .flatMap { $0.isEmpty ? nil : $0 }
        sets = (try? container.decode(TrainLossyArray<ActivitySet>.self, forKey: .sets))?.elements ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encode(sets, forKey: .sets)
    }
}

enum ActivityPRKind: String, Codable, Equatable, Sendable {
    case e1rm
    case weight
    case reps
    case other

    init(lossy raw: String?) {
        self = raw.flatMap { Self(rawValue: $0.lowercased()) } ?? .other
    }
}

struct ActivityPR: Codable, Equatable, Hashable, Sendable {
    var exercise: String
    var kind: ActivityPRKind
    var value: Double
    var unit: String?
    var previous: Double?

    init(exercise: String, kind: ActivityPRKind, value: Double, unit: String? = nil, previous: Double? = nil) {
        self.exercise = exercise
        self.kind = kind
        self.value = value
        self.unit = unit
        self.previous = previous
    }

    enum CodingKeys: String, CodingKey {
        case exercise, kind, value, unit, previous
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let exercise = container.trainLossyString(.exercise), !exercise.isEmpty,
              let value = container.trainLossyDouble(.value), value.isFinite
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .exercise, in: container, debugDescription: "PR needs exercise and value")
        }
        self.exercise = exercise
        self.kind = ActivityPRKind(lossy: container.trainLossyString(.kind))
        self.value = value
        self.unit = container.trainLossyString(.unit)
        self.previous = container.trainLossyDouble(.previous)
    }
}

enum ActivityBurnMethod: String, Codable, Equatable, Sendable {
    case device
    case met
}

struct ActivityDetails: Codable, Equatable, Sendable {
    var exercises: [ActivityExercise]
    var prs: [ActivityPR]
    var deviceLabel: String?
    var planSessionId: String?
    var burnMethod: ActivityBurnMethod?
    var met: Double?
    var weightKgUsed: Double?
    var analysisPreview: String?

    init(
        exercises: [ActivityExercise] = [],
        prs: [ActivityPR] = [],
        deviceLabel: String? = nil,
        planSessionId: String? = nil,
        burnMethod: ActivityBurnMethod? = nil,
        met: Double? = nil,
        weightKgUsed: Double? = nil,
        analysisPreview: String? = nil
    ) {
        self.exercises = exercises
        self.prs = prs
        self.deviceLabel = deviceLabel
        self.planSessionId = planSessionId
        self.burnMethod = burnMethod
        self.met = met
        self.weightKgUsed = weightKgUsed
        self.analysisPreview = analysisPreview
    }

    static let empty = ActivityDetails()

    enum CodingKeys: String, CodingKey {
        case exercises, prs, met
        case deviceLabel = "device_label"
        case planSessionId = "plan_session_id"
        case burnMethod = "burn_method"
        case weightKgUsed = "weight_kg_used"
        case analysisPreview = "analysis_preview"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exercises = (try? container.decode(TrainLossyArray<ActivityExercise>.self, forKey: .exercises))?
            .elements ?? []
        prs = (try? container.decode(TrainLossyArray<ActivityPR>.self, forKey: .prs))?.elements ?? []
        deviceLabel = container.trainLossyString(.deviceLabel).flatMap { $0.isEmpty ? nil : $0 }
        planSessionId = container.trainLossyString(.planSessionId).flatMap { $0.isEmpty ? nil : $0 }
        burnMethod = container.trainLossyString(.burnMethod).flatMap(ActivityBurnMethod.init(rawValue:))
        met = container.trainLossyDouble(.met)
        weightKgUsed = container.trainLossyDouble(.weightKgUsed)
        analysisPreview = container.trainLossyString(.analysisPreview)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Client-only lifecycle of a log that has no settled server row yet.
enum ActivityLocalState: Equatable, Sendable {
    /// Accepted locally; the `log_activity` request is in flight.
    case sending
    /// The request failed before the server confirmed it. The payload is
    /// preserved by `ActivityLoggingController`; retry re-sends the same
    /// client_request_id.
    case notSent(message: String)
    /// Polling gave up (timeout or repeated errors); the server keeps working.
    case stalled(message: String)
}

struct Activity: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var clientRequestId: UUID?
    var localDay: String
    var occurredAt: Date
    var status: ActivityStatus
    var source: String
    var kind: ActivityKind
    var title: String
    var durationMin: Double?
    var distanceKm: Double?
    var activeKcal: Double?
    var avgHeartRate: Int?
    var intensity: ActivityIntensity?
    var rpe: Double?
    var details: ActivityDetails
    var inputText: String?
    var imagePath: String?
    var confidence: Double?
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date
    /// Not persisted; set only on optimistic/local rows.
    var localState: ActivityLocalState?

    init(
        id: UUID,
        clientRequestId: UUID? = nil,
        localDay: String,
        occurredAt: Date,
        status: ActivityStatus = .complete,
        source: String = "voice",
        kind: ActivityKind = .other,
        title: String,
        durationMin: Double? = nil,
        distanceKm: Double? = nil,
        activeKcal: Double? = nil,
        avgHeartRate: Int? = nil,
        intensity: ActivityIntensity? = nil,
        rpe: Double? = nil,
        details: ActivityDetails = .empty,
        inputText: String? = nil,
        imagePath: String? = nil,
        confidence: Double? = nil,
        errorMessage: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        localState: ActivityLocalState? = nil
    ) {
        self.id = id
        self.clientRequestId = clientRequestId
        self.localDay = localDay
        self.occurredAt = occurredAt
        self.status = status
        self.source = source
        self.kind = kind
        self.title = title
        self.durationMin = durationMin
        self.distanceKm = distanceKm
        self.activeKcal = activeKcal
        self.avgHeartRate = avgHeartRate
        self.intensity = intensity
        self.rpe = rpe
        self.details = details
        self.inputText = inputText
        self.imagePath = imagePath
        self.confidence = confidence
        self.errorMessage = errorMessage
        self.createdAt = createdAt ?? occurredAt
        self.updatedAt = updatedAt ?? createdAt ?? occurredAt
        self.localState = localState
    }

    var planSessionId: String? { details.planSessionId }
    var exercises: [ActivityExercise] { details.exercises }
    var prs: [ActivityPR] { details.prs }
    var analysisPreview: String? { details.analysisPreview }

    /// Still being read: either in flight locally or analyzing on the server.
    var isProcessing: Bool {
        if case .notSent = localState { return false }
        return localState == .sending || status == .processing
    }

    /// No server row backs this card yet (sending, or failed before sending).
    var isLocalOnly: Bool {
        switch localState {
        case .sending, .notSent: return true
        case .stalled, .none: return false
        }
    }

    var isNotSent: Bool {
        if case .notSent = localState { return true }
        return false
    }

    /// Counts toward history (rotation, week ring): settled, still being
    /// read, or optimistically sending. A log that never reached the server,
    /// or that the server could not read, does not.
    var countsTowardHistory: Bool {
        !isNotSent && status != .failed
    }

    enum CodingKeys: String, CodingKey {
        case id, status, source, kind, title, intensity, rpe, details, confidence
        case clientRequestId = "client_request_id"
        case localDay = "local_day"
        case occurredAt = "occurred_at"
        case durationMin = "duration_min"
        case distanceKm = "distance_km"
        case activeKcal = "active_kcal"
        case avgHeartRate = "avg_heart_rate"
        case inputText = "input_text"
        case imagePath = "image_path"
        case errorMessage = "error_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

extension Activity {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.trainLossyString(.id).flatMap(UUID.init(uuidString:)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container, debugDescription: "Activity id missing")
        }
        let rawDay = container.trainLossyString(.localDay) ?? ""
        let localDay = String(rawDay.prefix(10))
        guard TrainCalendar.isLocalDay(localDay) else {
            throw DecodingError.dataCorruptedError(
                forKey: .localDay, in: container, debugDescription: "Activity local_day malformed")
        }
        let createdAt = container.trainDate(.createdAt)
        let occurredAt = container.trainDate(.occurredAt) ?? createdAt ?? Date()
        self.id = id
        self.clientRequestId = container.trainLossyString(.clientRequestId).flatMap(UUID.init(uuidString:))
        self.localDay = localDay
        self.occurredAt = occurredAt
        self.status = container.trainLossyString(.status).flatMap(ActivityStatus.init(rawValue:)) ?? .complete
        self.source = container.trainLossyString(.source) ?? "manual"
        self.kind = ActivityKind(lossy: container.trainLossyString(.kind))
        let title = container.trainLossyString(.title)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = title.isEmpty ? "Workout" : title
        self.durationMin = container.trainLossyDouble(.durationMin).flatMap { $0 >= 0 ? $0 : nil }
        self.distanceKm = container.trainLossyDouble(.distanceKm).flatMap { $0 >= 0 ? $0 : nil }
        self.activeKcal = container.trainLossyDouble(.activeKcal).flatMap { $0 >= 0 ? $0 : nil }
        self.avgHeartRate = container.trainLossyInt(.avgHeartRate)
        self.intensity = container.trainLossyString(.intensity).flatMap(ActivityIntensity.init(rawValue:))
        self.rpe = container.trainLossyDouble(.rpe)
        self.details = (try? container.decode(ActivityDetails.self, forKey: .details)) ?? .empty
        self.inputText = container.trainLossyString(.inputText)
        self.imagePath = container.trainLossyString(.imagePath).flatMap { $0.isEmpty ? nil : $0 }
        self.confidence = container.trainLossyDouble(.confidence)
        self.errorMessage = container.trainLossyString(.errorMessage)
        self.createdAt = createdAt ?? occurredAt
        self.updatedAt = container.trainDate(.updatedAt) ?? createdAt ?? occurredAt
        self.localState = nil
    }
}

// MARK: - Tolerant decoding helpers (shared by the Train models)

/// Decodes an array element by element, dropping elements that fail.
struct TrainLossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    /// Accepts any JSON value without inspecting it, so decoding it always
    /// succeeds and advances the unkeyed container past a malformed element.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else if (try? container.decode(Skip.self)) == nil {
                break
            }
        }
        self.elements = elements
    }
}

enum TrainDateParser {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    /// Parses Postgres/PostgREST timestamps ("2026-10-06T22:14:03.123456+00:00",
    /// with or without fractional seconds).
    static func parse(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let date = fractional.date(from: trimmed) { return date }
        if let date = plain.date(from: trimmed) { return date }
        // Space separator ("2026-10-06 22:14:03+00") and over-long fractions.
        var normalized = trimmed.replacingOccurrences(of: " ", with: "T")
        if let regex = try? NSRegularExpression(pattern: #"\.(\d{3})\d+"#) {
            let range = NSRange(normalized.startIndex..., in: normalized)
            normalized = regex.stringByReplacingMatches(
                in: normalized, range: range, withTemplate: ".$1")
        }
        if normalized.range(of: #"[+-]\d{2}$"#, options: .regularExpression) != nil {
            normalized += ":00"
        }
        return fractional.date(from: normalized) ?? plain.date(from: normalized)
    }

    static func string(from date: Date) -> String {
        fractional.string(from: date)
    }
}

extension KeyedDecodingContainer {
    func trainLossyString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.rounded() == value ? String(Int(value)) : String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value ? "true" : "false" }
        return nil
    }

    func trainLossyDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return value.isFinite ? value : nil
        }
        if let text = try? decodeIfPresent(String.self, forKey: key),
           let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite {
            return value
        }
        return nil
    }

    func trainLossyInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        guard let double = trainLossyDouble(key), abs(double) < Double(Int32.max) else { return nil }
        return Int(double.rounded())
    }

    func trainLossyBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    func trainDate(_ key: Key) -> Date? {
        trainLossyString(key).flatMap(TrainDateParser.parse)
    }
}
