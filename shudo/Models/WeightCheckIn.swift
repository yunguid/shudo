import Foundation

public struct WeightCheckIn: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let localDay: String
    public let weightKG: Double
    public let progressPhotoPath: String?
    public let createdAt: Date
    public let updatedAt: Date

    public var hasPhoto: Bool { progressPhotoPath != nil }
}

enum WeightCheckInPolicy {
    static let kilogramsRange = 20.0...500.0
    static let poundsPerKilogram = 2.20462

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
