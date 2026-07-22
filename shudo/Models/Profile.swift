import Foundation

public enum NutritionGoalType: String, Codable, CaseIterable, Sendable {
    case maintain
    case lose
    case gain
}

public enum ProfileActivityLevel: String, Codable, CaseIterable, Sendable {
    case sedentary
    case light
    case moderate
    case active
    case extraActive = "extra_active"
}

public struct ProfileSettingsUpdate: Equatable {
    public var timezone: String?
    public var units: String?
    public var displayName: String?
    public var heightCM: Double?
    public var weightKG: Double?
    public var targetWeightKG: Double?
    public var activityLevel: ProfileActivityLevel?
    public var goalType: NutritionGoalType
    public var goalNotes: String?
    public var dailyMacroTarget: MacroTarget?

    public init(
        timezone: String? = nil,
        units: String? = nil,
        displayName: String? = nil,
        heightCM: Double? = nil,
        weightKG: Double? = nil,
        targetWeightKG: Double? = nil,
        activityLevel: ProfileActivityLevel? = nil,
        goalType: NutritionGoalType = .maintain,
        goalNotes: String? = nil,
        dailyMacroTarget: MacroTarget? = nil
    ) {
        self.timezone = timezone
        self.units = units
        self.displayName = displayName
        self.heightCM = heightCM
        self.weightKG = weightKG
        self.targetWeightKG = targetWeightKG
        self.activityLevel = activityLevel
        self.goalType = goalType
        self.goalNotes = goalNotes
        self.dailyMacroTarget = dailyMacroTarget
    }
}

public struct Profile: Codable, Equatable {
    public var userId: String
    public var timezone: String
    public var dailyMacroTarget: MacroTarget
    public var units: String = "imperial"
    public var heightCM: Double? = nil
    public var weightKG: Double? = nil
    public var targetWeightKG: Double? = nil
    public var displayName: String? = nil
    public var activityLevel: ProfileActivityLevel? = nil
    public var goalType: NutritionGoalType = .maintain
    public var goalNotes: String? = nil
    public var onboardingStatus: OnboardingStatus? = nil
    public var onboardingCompletedAt: Date? = nil
    public var avatarPath: String? = nil
}
