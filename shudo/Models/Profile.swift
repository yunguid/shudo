import Foundation

public struct Profile: Codable, Equatable {
    public var userId: String
    public var timezone: String
    public var dailyMacroTarget: MacroTarget
    public var units: String = "imperial"
    public var heightCM: Double? = nil
    public var weightKG: Double? = nil
    public var targetWeightKG: Double? = nil
    public var activityLevel: String? = nil
    public var cutoffTimeLocal: String? = nil
}


