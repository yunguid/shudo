import Foundation

public struct WeightCheckIn: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let localDay: String
    public let weightKG: Double
    public let progressPhotoPath: String?
    public let scalePhotoPath: String?
    public let createdAt: Date
    public let updatedAt: Date

    public var hasPhotos: Bool {
        progressPhotoPath != nil || scalePhotoPath != nil
    }
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
