import Foundation

public struct MacroTarget: Codable, Equatable, Sendable {
    public var caloriesKcal: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double

    public static let defaultDaily = MacroTarget(
        caloriesKcal: 2_200,
        proteinG: 150,
        carbsG: 250,
        fatG: 70
    )
}
