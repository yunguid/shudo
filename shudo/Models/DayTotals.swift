import Foundation

public struct DayTotals: Codable, Equatable {
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var caloriesKcal: Double
    public var entryCount: Int

    public static let empty = DayTotals(proteinG: 0, carbsG: 0, fatG: 0, caloriesKcal: 0, entryCount: 0)
}


