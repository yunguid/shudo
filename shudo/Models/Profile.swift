import Foundation

public struct Profile: Codable, Equatable {
    public var userId: String
    public var timezone: String
    public var dailyMacroTarget: MacroTarget
}


