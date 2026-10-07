import Foundation

/// One day's body check-in: a physique photo, a weight, or both. Luke has no
/// scale yet, so photo-only days are normal and the weight can be added later
/// the same day without touching the photo (and vice versa).
public struct WeightCheckIn: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let localDay: String
    public let weightKG: Double?
    public let progressPhotoPath: String?
    public var note: String? = nil
    public var photoPose: PhysiquePose? = nil
    public var photoCapturedAt: Date? = nil
    /// Server-written physique review (`coach_review jsonb`), read-only here.
    public var coachReview: PhysiqueCoachReview? = nil
    public var coachReviewedAt: Date? = nil
    public let createdAt: Date
    public let updatedAt: Date

    public var hasPhoto: Bool { progressPhotoPath != nil }
    public var hasWeight: Bool { weightKG != nil }
}

/// `weight_checkins.photo_pose` values (DB check constraint). The app writes
/// `front_relaxed` for a plain front shot; plain `front` is accepted by the
/// schema too, so it decodes.
public enum PhysiquePose: String, CaseIterable, Sendable, Identifiable {
    case front
    case frontRelaxed = "front_relaxed"
    case frontFlexed = "front_flexed"
    case side
    case back
    case other

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .front, .frontRelaxed: "Front"
        case .frontFlexed: "Flexed"
        case .side: "Side"
        case .back: "Back"
        case .other: "Other"
        }
    }
}

/// The parts of the server's physique review the Body tab shows. Decoded
/// leniently: the review JSON is versioned by the backend lane, so unknown
/// fields are ignored and observations may be strings or objects.
public struct PhysiqueCoachReview: Equatable, Sendable {
    public let headline: String?
    public let coachNote: String?
    public let bulkQuality: String?
    public let observations: [String]

    static func parse(_ value: Any?) -> PhysiqueCoachReview? {
        var object = value as? [String: Any]
        if object == nil, let text = value as? String, let data = text.data(using: .utf8) {
            object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard let object else { return nil }
        func text(_ key: String) -> String? {
            (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }
        let observations = (object["observations"] as? [Any] ?? []).compactMap { item -> String? in
            if let line = item as? String { return line.nilIfEmpty }
            guard let entry = item as? [String: Any] else { return nil }
            return ((entry["evidence"] as? String) ?? (entry["text"] as? String))?.nilIfEmpty
        }
        let review = PhysiqueCoachReview(
            headline: text("headline"),
            coachNote: text("coach_note"),
            bulkQuality: text("bulk_quality"),
            observations: Array(observations.prefix(3))
        )
        return review.headline == nil && review.coachNote == nil && review.observations.isEmpty
            ? nil : review
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum WeightCheckInPolicy {
    static let kilogramsRange = 20.0...500.0
    static let poundsPerKilogram = 2.20462
    static let noteLimit = 1_000

    static func kilograms(from displayedValue: Double, units: String) -> Double? {
        guard displayedValue.isFinite, displayedValue > 0 else { return nil }
        let kilograms =
            units.lowercased() == "imperial"
            ? displayedValue / poundsPerKilogram
            : displayedValue
        guard kilogramsRange.contains(kilograms) else { return nil }
        return (kilograms * 100).rounded() / 100
    }

    static func displayedValue(kilograms: Double, units: String) -> Double {
        units.lowercased() == "imperial" ? kilograms * poundsPerKilogram : kilograms
    }
}

/// Pulls the spoken weight out of a live dictation transcript. Dictation
/// renders numbers as digits ("one eighty two point four" → "182.4"), but
/// low-confidence passes can leave "182 point 4" or comma decimals, so both
/// are normalized before scanning. The LAST plausible number wins: people
/// correct themselves mid-utterance ("183 — no, 182.6").
enum WeightUtterancePolicy {
    static func parsedWeight(transcript: String, units: String) -> Double? {
        var text = transcript.lowercased().replacingOccurrences(of: ",", with: ".")
        text = text.replacingOccurrences(
            of: #"(?<=\d)\s*point\s*(?=\d)"#,
            with: ".",
            options: .regularExpression
        )

        var candidates: [Double] = []
        var remaining = text[text.startIndex...]
        while let range = remaining.range(of: #"\d+(\.\d+)?"#, options: .regularExpression) {
            if let value = Double(remaining[range]) { candidates.append(value) }
            remaining = remaining[range.upperBound...]
        }

        // Trailing fragments like the lone "4" in "182 4" are implausible as
        // weights and skipped, so the utterance still resolves to 182.
        for value in candidates.reversed() {
            if WeightCheckInPolicy.kilograms(from: value, units: units) != nil {
                return (value * 10).rounded() / 10
            }
        }
        return nil
    }
}
