import Foundation

// MARK: - Training plans (public.training_plans, TrainingPlanDoc v1)
//
// The plan document is model-written JSON. Decoding accepts the spec shape
// and the research-report variants (display_name/exercise_key,
// sessions_per_week_target, progression as an object), drops malformed
// sessions/exercises, and repairs the rotation so the client can always
// compute "next up".

enum TrainingPlanStatus: String, Codable, Equatable, Sendable {
    case draft
    case active
    case superseded
    case rejected
}

struct PlannedExercise: Codable, Equatable, Hashable, Sendable {
    var name: String
    var key: String?
    var sets: Int
    var repMin: Int
    var repMax: Int
    var restSec: Int?
    /// Progression rule; "double" (double progression) is the default.
    var progression: String
    /// Load jump once every working set reaches `repMax`.
    var incrementLb: Double?
    var targetRPE: Double?
    var cue: String?

    init(
        name: String,
        key: String? = nil,
        sets: Int,
        repMin: Int,
        repMax: Int,
        restSec: Int? = nil,
        progression: String = "double",
        incrementLb: Double? = nil,
        targetRPE: Double? = nil,
        cue: String? = nil
    ) {
        self.name = name
        self.key = key
        self.sets = sets
        self.repMin = repMin
        self.repMax = repMax
        self.restSec = restSec
        self.progression = progression
        self.incrementLb = incrementLb
        self.targetRPE = targetRPE
        self.cue = cue
    }

    /// "4×6–8" or "3×10".
    var prescription: String {
        repMin == repMax ? "\(sets)×\(repMax)" : "\(sets)×\(repMin)–\(repMax)"
    }

    enum CodingKeys: String, CodingKey {
        case name, key, sets, reps, progression, cue
        case displayName = "display_name"
        case exerciseKey = "exercise_key"
        case repMin = "rep_min"
        case repMax = "rep_max"
        case restSec = "rest_sec"
        case incrementLb = "increment_lb"
        case targetRPE = "target_rpe"
    }

    private enum ProgressionKeys: String, CodingKey {
        case rule
        case incrementLb = "increment_lb"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawName = container.trainLossyString(.name) ?? container.trainLossyString(.displayName) ?? ""
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: container, debugDescription: "Planned exercise has no name")
        }
        name = trimmed
        key = (container.trainLossyString(.key) ?? container.trainLossyString(.exerciseKey))
            .flatMap { $0.isEmpty ? nil : $0 }
        sets = min(10, max(1, container.trainLossyInt(.sets) ?? 3))
        let fixedReps = container.trainLossyInt(.reps)
        let low = container.trainLossyInt(.repMin) ?? fixedReps ?? 8
        let high = container.trainLossyInt(.repMax) ?? fixedReps ?? max(low, 12)
        repMin = max(1, min(low, high))
        repMax = max(repMin, max(low, high))
        restSec = container.trainLossyInt(.restSec)
        targetRPE = container.trainLossyDouble(.targetRPE)
        cue = container.trainLossyString(.cue).flatMap { $0.isEmpty ? nil : $0 }

        var rule = "double"
        var increment = container.trainLossyDouble(.incrementLb)
        if let text = container.trainLossyString(.progression), !text.isEmpty, text != "true" {
            rule = text
        } else if let nested = try? container.nestedContainer(keyedBy: ProgressionKeys.self, forKey: .progression) {
            if let nestedRule = nested.trainLossyString(.rule), !nestedRule.isEmpty {
                rule = nestedRule == "double_progression" ? "double" : nestedRule
            }
            increment = increment ?? nested.trainLossyDouble(.incrementLb)
        }
        progression = rule
        incrementLb = increment.flatMap { $0 > 0 ? $0 : nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encode(sets, forKey: .sets)
        try container.encode(repMin, forKey: .repMin)
        try container.encode(repMax, forKey: .repMax)
        try container.encodeIfPresent(restSec, forKey: .restSec)
        try container.encode(progression, forKey: .progression)
        try container.encodeIfPresent(incrementLb, forKey: .incrementLb)
        try container.encodeIfPresent(targetRPE, forKey: .targetRPE)
        try container.encodeIfPresent(cue, forKey: .cue)
    }
}

struct TrainingSession: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var focus: String?
    var estMinutes: Int?
    var exercises: [PlannedExercise]

    init(id: String, name: String, focus: String? = nil, estMinutes: Int? = nil, exercises: [PlannedExercise]) {
        self.id = id
        self.name = name
        self.focus = focus
        self.estMinutes = estMinutes
        self.exercises = exercises
    }

    /// One-letter pad marker for the week strip ("Upper A" → "U").
    var marker: String {
        name.first.map { String($0).uppercased() } ?? "•"
    }

    enum CodingKeys: String, CodingKey {
        case id, name, focus, exercises
        case estMinutes = "est_minutes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = container.trainLossyString(.id)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawId.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container, debugDescription: "Session has no id")
        }
        id = rawId
        let rawName = container.trainLossyString(.name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        name = rawName.isEmpty ? rawId.replacingOccurrences(of: "_", with: " ").capitalized : rawName
        focus = container.trainLossyString(.focus).flatMap { $0.isEmpty ? nil : $0 }
        estMinutes = container.trainLossyInt(.estMinutes).flatMap { $0 > 0 ? $0 : nil }
        exercises = (try? container.decode(TrainLossyArray<PlannedExercise>.self, forKey: .exercises))?
            .elements ?? []
    }
}

struct TrainingConditioning: Codable, Equatable, Sendable {
    var kind: String
    var minutes: Int?
    var when: String?
    var daysPerWeek: Int?
    var optional: Bool

    init(kind: String, minutes: Int? = nil, when: String? = nil, daysPerWeek: Int? = nil, optional: Bool = true) {
        self.kind = kind
        self.minutes = minutes
        self.when = when
        self.daysPerWeek = daysPerWeek
        self.optional = optional
    }

    enum CodingKeys: String, CodingKey {
        case kind, minutes, when, optional
        case daysPerWeek = "days_per_week"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = container.trainLossyString(.kind) ?? "cardio"
        minutes = container.trainLossyInt(.minutes)
        when = container.trainLossyString(.when)
        daysPerWeek = container.trainLossyInt(.daysPerWeek)
        optional = container.trainLossyBool(.optional) ?? true
    }

    /// "Bike · 10 min · mornings · optional"
    var summary: String {
        var parts = [kind.replacingOccurrences(of: "_", with: " ").capitalized]
        if let minutes { parts.append("\(minutes) min") }
        if let when, !when.isEmpty { parts.append(when == "morning" ? "mornings" : when) }
        if let daysPerWeek { parts.append("\(daysPerWeek)×/wk") }
        if optional { parts.append("optional") }
        return parts.joined(separator: " · ")
    }
}

struct TrainingPlanDoc: Codable, Equatable, Sendable {
    var version: Int
    var name: String
    var phase: String?
    var sessionsPerWeek: Int
    var rotation: [String]
    var sessions: [TrainingSession]
    var conditioning: TrainingConditioning?
    var equipmentAssumed: [String]
    var notes: String?

    init(
        version: Int = 1,
        name: String,
        phase: String? = nil,
        sessionsPerWeek: Int,
        rotation: [String],
        sessions: [TrainingSession],
        conditioning: TrainingConditioning? = nil,
        equipmentAssumed: [String] = [],
        notes: String? = nil
    ) {
        self.version = version
        self.name = name
        self.phase = phase
        self.sessions = sessions
        self.rotation = Self.repairedRotation(rotation, sessions: sessions)
        self.sessionsPerWeek = Self.clampedSessionsPerWeek(sessionsPerWeek, sessions: sessions)
        self.conditioning = conditioning
        self.equipmentAssumed = equipmentAssumed
        self.notes = notes
    }

    func session(id: String) -> TrainingSession? {
        sessions.first { $0.id == id }
    }

    /// Sessions in rotation order, each once.
    var orderedSessions: [TrainingSession] {
        var seen = Set<String>()
        var ordered: [TrainingSession] = []
        for id in rotation where !seen.contains(id) {
            seen.insert(id)
            if let session = session(id: id) { ordered.append(session) }
        }
        for session in sessions where !seen.contains(session.id) {
            ordered.append(session)
        }
        return ordered
    }

    /// Keeps only ids that exist; an empty/invalid rotation falls back to the
    /// sessions in document order.
    static func repairedRotation(_ rotation: [String], sessions: [TrainingSession]) -> [String] {
        let known = Set(sessions.map(\.id))
        let repaired = rotation.filter { known.contains($0) }
        return repaired.isEmpty ? sessions.map(\.id) : repaired
    }

    static func clampedSessionsPerWeek(_ value: Int, sessions: [TrainingSession]) -> Int {
        let fallback = max(1, min(7, sessions.count))
        return (1...7).contains(value) ? value : fallback
    }

    enum CodingKeys: String, CodingKey {
        case version, name, phase, rotation, sessions, conditioning, notes
        case sessionsPerWeek = "sessions_per_week"
        case sessionsPerWeekTarget = "sessions_per_week_target"
        case equipmentAssumed = "equipment_assumed"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sessions = (try? container.decode(TrainLossyArray<TrainingSession>.self, forKey: .sessions))?
            .elements ?? []
        let rawName = container.trainLossyString(.name)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rotation = (try? container.decode(TrainLossyArray<String>.self, forKey: .rotation))?.elements ?? []
        let perWeek = container.trainLossyInt(.sessionsPerWeek)
            ?? container.trainLossyInt(.sessionsPerWeekTarget)
            ?? sessions.count
        self.init(
            version: container.trainLossyInt(.version) ?? 1,
            name: rawName.isEmpty ? "Training plan" : rawName,
            phase: container.trainLossyString(.phase),
            sessionsPerWeek: perWeek,
            rotation: rotation,
            sessions: sessions,
            conditioning: try? container.decodeIfPresent(TrainingConditioning.self, forKey: .conditioning),
            equipmentAssumed: (try? container.decode(TrainLossyArray<String>.self, forKey: .equipmentAssumed))?
                .elements ?? [],
            notes: container.trainLossyString(.notes).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(phase, forKey: .phase)
        try container.encode(sessionsPerWeek, forKey: .sessionsPerWeek)
        try container.encode(rotation, forKey: .rotation)
        try container.encode(sessions, forKey: .sessions)
        try container.encodeIfPresent(conditioning, forKey: .conditioning)
        try container.encode(equipmentAssumed, forKey: .equipmentAssumed)
        try container.encodeIfPresent(notes, forKey: .notes)
    }
}

struct TrainingPlan: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var status: TrainingPlanStatus
    var plan: TrainingPlanDoc
    var rationale: String?
    var changeSummary: String?
    var source: String?
    var createdAt: Date
    var activatedAt: Date?

    init(
        id: UUID,
        status: TrainingPlanStatus,
        plan: TrainingPlanDoc,
        rationale: String? = nil,
        changeSummary: String? = nil,
        source: String? = "coach",
        createdAt: Date = Date(),
        activatedAt: Date? = nil
    ) {
        self.id = id
        self.status = status
        self.plan = plan
        self.rationale = rationale
        self.changeSummary = changeSummary
        self.source = source
        self.createdAt = createdAt
        self.activatedAt = activatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, status, plan, rationale, source
        case changeSummary = "change_summary"
        case createdAt = "created_at"
        case activatedAt = "activated_at"
    }
}

extension TrainingPlan {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = container.trainLossyString(.id).flatMap(UUID.init(uuidString:)),
              let status = container.trainLossyString(.status).flatMap(TrainingPlanStatus.init(rawValue:))
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .id, in: container, debugDescription: "Plan needs id and known status")
        }
        // jsonb normally arrives as an object; tolerate a JSON-encoded string.
        let plan: TrainingPlanDoc
        if let object = try? container.decode(TrainingPlanDoc.self, forKey: .plan) {
            plan = object
        } else if let text = try? container.decode(String.self, forKey: .plan),
                  let data = text.data(using: .utf8),
                  let object = try? JSONDecoder().decode(TrainingPlanDoc.self, from: data) {
            plan = object
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .plan, in: container, debugDescription: "Plan document unreadable")
        }
        guard !plan.sessions.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .plan, in: container, debugDescription: "Plan has no sessions")
        }
        self.init(
            id: id,
            status: status,
            plan: plan,
            rationale: container.trainLossyString(.rationale).flatMap { $0.isEmpty ? nil : $0 },
            changeSummary: container.trainLossyString(.changeSummary).flatMap { $0.isEmpty ? nil : $0 },
            source: container.trainLossyString(.source),
            createdAt: container.trainDate(.createdAt) ?? Date(),
            activatedAt: container.trainDate(.activatedAt)
        )
    }
}

/// The plan rows the Train tab cares about: at most one active, one draft.
struct TrainingPlanState: Equatable, Sendable {
    var active: TrainingPlan?
    var draft: TrainingPlan?

    init(active: TrainingPlan? = nil, draft: TrainingPlan? = nil) {
        self.active = active
        self.draft = draft
    }

    /// Picks the newest active and newest draft (the DB guarantees one of
    /// each; this stays deterministic if it ever sees more).
    init(rows: [TrainingPlan]) {
        let newestFirst = rows.sorted { $0.createdAt > $1.createdAt }
        active = newestFirst.first { $0.status == .active }
        draft = newestFirst.first { $0.status == .draft }
    }
}
