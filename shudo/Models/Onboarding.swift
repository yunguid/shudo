import Foundation

public enum OnboardingStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case completed
    case skipped
}

enum OnboardingAnalysisStatus: String, Codable, Sendable {
    case analyzing
    case proposed
    case applied
    case failed
}

struct OnboardingProposal: Codable, Equatable, Sendable {
    let summary: String
    let displayName: String?
    let goalType: NutritionGoalType
    let goalNotes: String
    let heightCM: Double?
    let weightKG: Double?
    let targetWeightKG: Double?
    let activityLevel: ProfileActivityLevel
    let caloriesKcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let assumptions: [String]
    let suggestions: [String]

    private enum CodingKeys: String, CodingKey {
        case summary
        case displayName = "display_name"
        case goalType = "goal_type"
        case goalNotes = "goal_notes"
        case heightCM = "height_cm"
        case weightKG = "weight_kg"
        case targetWeightKG = "target_weight_kg"
        case activityLevel = "activity_level"
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case assumptions
        case suggestions
    }
}

struct OnboardingProposalResult: Equatable, Sendable {
    let onboardingID: UUID
    let transcript: String
    let proposal: OnboardingProposal
}

struct OnboardingOverrides: Equatable, Encodable, Sendable {
    let displayName: String?
    let goalType: NutritionGoalType
    let goalNotes: String
    let heightCM: Double?
    let weightKG: Double?
    let targetWeightKG: Double?
    let activityLevel: ProfileActivityLevel
    let caloriesKcal: Double
    let proteinG: Double
    let carbsG: Double
    let fatG: Double

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case goalType = "goal_type"
        case goalNotes = "goal_notes"
        case heightCM = "height_cm"
        case weightKG = "weight_kg"
        case targetWeightKG = "target_weight_kg"
        case activityLevel = "activity_level"
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let displayName {
            try container.encode(displayName, forKey: .displayName)
        } else {
            try container.encodeNil(forKey: .displayName)
        }
        try container.encode(goalType, forKey: .goalType)
        try container.encode(goalNotes, forKey: .goalNotes)
        if let heightCM {
            try container.encode(heightCM, forKey: .heightCM)
        } else {
            try container.encodeNil(forKey: .heightCM)
        }
        if let weightKG {
            try container.encode(weightKG, forKey: .weightKG)
        } else {
            try container.encodeNil(forKey: .weightKG)
        }
        if let targetWeightKG {
            try container.encode(targetWeightKG, forKey: .targetWeightKG)
        } else {
            try container.encodeNil(forKey: .targetWeightKG)
        }
        try container.encode(activityLevel, forKey: .activityLevel)
        try container.encode(caloriesKcal, forKey: .caloriesKcal)
        try container.encode(proteinG, forKey: .proteinG)
        try container.encode(carbsG, forKey: .carbsG)
        try container.encode(fatG, forKey: .fatG)
    }
}

enum OnboardingUnitPreference: String, Equatable, Sendable {
    case imperial
    case metric

    init(profileUnits: String?) {
        self = profileUnits?.lowercased() == Self.metric.rawValue ? .metric : .imperial
    }
}

struct OnboardingDraft: Equatable, Sendable {
    enum ValidationError: LocalizedError, Equatable {
        case textTooLong(label: String)
        case invalidNumber(label: String)
        case invalidImperialHeight
        case imperialHeightOutOfRange
        case outOfRange(label: String, minimum: Double, maximum: Double)

        var errorDescription: String? {
            switch self {
            case .textTooLong(let label):
                return "\(label) is too long."
            case .invalidNumber(let label):
                return "Enter a valid \(label.lowercased())."
            case .invalidImperialHeight:
                return "Enter height using whole feet and 0 to 11.9 inches."
            case .imperialHeightOutOfRange:
                return "Height must be between 1 ft 8 in and 9 ft."
            case .outOfRange(let label, let minimum, let maximum):
                return "\(label) must be between \(Self.number(minimum)) and \(Self.number(maximum))."
            }
        }

        private static func number(_ value: Double) -> String {
            value.rounded() == value ? String(Int(value)) : String(value)
        }
    }

    let units: OnboardingUnitPreference
    var displayName: String
    var heightCentimeters: String
    var heightFeet: String
    var heightInches: String
    var weight: String
    var targetWeight: String
    var activityLevel: ProfileActivityLevel
    var goalType: NutritionGoalType
    var goalNotes: String
    var caloriesKcal: String
    var proteinG: String
    var carbsG: String
    var fatG: String

    private let originalHeightCM: Double?
    private let originalWeightKG: Double?
    private let originalTargetWeightKG: Double?
    private let initialHeightCentimeters: String
    private let initialHeightFeet: String
    private let initialHeightInches: String
    private let initialWeight: String
    private let initialTargetWeight: String
    private let targetPreview: OnboardingTargetPreview

    init(proposal: OnboardingProposal, profileUnits: String? = nil) {
        let units = OnboardingUnitPreference(profileUnits: profileUnits)
        let heightCentimeters = Self.editableNumber(proposal.heightCM)
        let imperialHeight = Self.imperialHeight(proposal.heightCM)
        let weightScale = units == .imperial ? Self.poundsPerKilogram : 1
        let weight = Self.editableNumber(proposal.weightKG.map { $0 * weightScale })
        let targetWeight = Self.editableNumber(
            proposal.targetWeightKG.map { $0 * weightScale }
        )

        self.units = units
        displayName = proposal.displayName ?? ""
        self.heightCentimeters = heightCentimeters
        heightFeet = imperialHeight.feet
        heightInches = imperialHeight.inches
        self.weight = weight
        self.targetWeight = targetWeight
        activityLevel = proposal.activityLevel
        goalType = proposal.goalType
        goalNotes = proposal.goalNotes
        caloriesKcal = Self.editableNumber(proposal.caloriesKcal)
        proteinG = Self.editableNumber(proposal.proteinG)
        carbsG = Self.editableNumber(proposal.carbsG)
        fatG = Self.editableNumber(proposal.fatG)
        originalHeightCM = proposal.heightCM
        originalWeightKG = proposal.weightKG
        originalTargetWeightKG = proposal.targetWeightKG
        initialHeightCentimeters = heightCentimeters
        initialHeightFeet = imperialHeight.feet
        initialHeightInches = imperialHeight.inches
        initialWeight = weight
        initialTargetWeight = targetWeight
        targetPreview = OnboardingTargetPreview(proposal: proposal)
    }

    mutating func applyGoal(_ goal: NutritionGoalType) {
        goalType = goal
        let target = targetPreview.target(for: goal)
        caloriesKcal = Self.editableNumber(target.caloriesKcal)
        proteinG = Self.editableNumber(target.proteinG)
        carbsG = Self.editableNumber(target.carbsG)
        fatG = Self.editableNumber(target.fatG)
    }

    func validatedOverrides() throws -> OnboardingOverrides {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNotes = goalNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.count <= 80 else {
            throw ValidationError.textTooLong(label: "Display name")
        }
        guard normalizedNotes.count <= 2_000 else {
            throw ValidationError.textTooLong(label: "Goal description")
        }

        return try OnboardingOverrides(
            displayName: normalizedName.isEmpty ? nil : normalizedName,
            goalType: goalType,
            goalNotes: normalizedNotes,
            heightCM: try validatedHeightCM(),
            weightKG: try validatedWeightKG(
                weight,
                label: "Weight",
                originalValue: originalWeightKG,
                initialDisplay: initialWeight
            ),
            targetWeightKG: try validatedWeightKG(
                targetWeight,
                label: "Target weight",
                originalValue: originalTargetWeightKG,
                initialDisplay: initialTargetWeight
            ),
            activityLevel: activityLevel,
            caloriesKcal: requiredNumber(
                caloriesKcal,
                label: "Calories",
                range: 500...10_000
            ),
            proteinG: requiredNumber(proteinG, label: "Protein", range: 0...1_000),
            carbsG: requiredNumber(carbsG, label: "Carbs", range: 0...1_500),
            fatG: requiredNumber(fatG, label: "Fat", range: 0...1_000)
        )
    }

    private func validatedHeightCM() throws -> Double? {
        switch units {
        case .metric:
            if normalized(heightCentimeters) == normalized(initialHeightCentimeters) {
                return originalHeightCM
            }
            return try optionalNumber(
                heightCentimeters,
                label: "Height",
                range: Self.heightRangeCM
            )
        case .imperial:
            if normalized(heightFeet) == normalized(initialHeightFeet),
               normalized(heightInches) == normalized(initialHeightInches) {
                return originalHeightCM
            }

            let normalizedFeet = normalized(heightFeet)
            let normalizedInches = normalized(heightInches)
            guard !normalizedFeet.isEmpty || !normalizedInches.isEmpty else { return nil }
            guard !normalizedFeet.isEmpty,
                  let feet = parsedNumber(normalizedFeet),
                  feet >= 0,
                  feet.rounded() == feet else {
                throw ValidationError.invalidImperialHeight
            }

            let inches: Double
            if normalizedInches.isEmpty {
                inches = 0
            } else if let parsedInches = parsedNumber(normalizedInches),
                      parsedInches >= 0,
                      parsedInches < 12 {
                inches = parsedInches
            } else {
                throw ValidationError.invalidImperialHeight
            }

            let centimeters = (feet * 12 + inches) * Self.centimetersPerInch
            guard Self.heightRangeCM.contains(centimeters) else {
                throw ValidationError.imperialHeightOutOfRange
            }
            return Self.roundedCanonical(centimeters)
        }
    }

    private func validatedWeightKG(
        _ rawValue: String,
        label: String,
        originalValue: Double?,
        initialDisplay: String
    ) throws -> Double? {
        if normalized(rawValue) == normalized(initialDisplay) {
            return originalValue
        }

        switch units {
        case .metric:
            return try optionalNumber(rawValue, label: label, range: Self.weightRangeKG)
        case .imperial:
            let poundRange = Self.roundedCanonical(
                Self.weightRangeKG.lowerBound * Self.poundsPerKilogram
            )...Self.roundedCanonical(
                Self.weightRangeKG.upperBound * Self.poundsPerKilogram
            )
            return try optionalNumber(rawValue, label: label, range: poundRange)
                .map { Self.roundedCanonical($0 / Self.poundsPerKilogram) }
        }
    }

    private func optionalNumber(
        _ rawValue: String,
        label: String,
        range: ClosedRange<Double>
    ) throws -> Double? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return try parsedNumber(normalized, label: label, range: range)
    }

    private func requiredNumber(
        _ rawValue: String,
        label: String,
        range: ClosedRange<Double>
    ) throws -> Double {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw ValidationError.invalidNumber(label: label) }
        return try parsedNumber(normalized, label: label, range: range)
    }

    private func parsedNumber(
        _ rawValue: String,
        label: String,
        range: ClosedRange<Double>
    ) throws -> Double {
        guard let value = parsedNumber(rawValue) else {
            throw ValidationError.invalidNumber(label: label)
        }
        guard range.contains(value) else {
            throw ValidationError.outOfRange(
                label: label,
                minimum: range.lowerBound,
                maximum: range.upperBound
            )
        }
        return Self.roundedCanonical(value)
    }

    private func parsedNumber(_ rawValue: String) -> Double? {
        let decimalNormalized = rawValue.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(decimalNormalized), value.isFinite else { return nil }
        return value
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
    }

    private static let centimetersPerInch = 2.54
    private static let poundsPerKilogram = 2.204_622_621_8
    private static let heightRangeCM = 50.0...275.0
    private static let weightRangeKG = 20.0...500.0

    private static func imperialHeight(_ centimeters: Double?) -> (feet: String, inches: String) {
        guard let centimeters else { return ("", "") }
        let totalInches = centimeters / centimetersPerInch
        var feet = Int(totalInches / 12)
        var inches = roundedCanonical(totalInches - Double(feet * 12))
        if inches >= 12 {
            feet += 1
            inches = 0
        }
        return (String(feet), editableNumber(inches))
    }

    private static func roundedCanonical(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private static func editableNumber(_ value: Double?) -> String {
        guard let value else { return "" }
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

struct OnboardingTargetPreview: Equatable, Sendable {
    private let maintenanceCalories: Double
    private let weightKG: Double?
    private let proteinBias: Double
    private let fatFraction: Double

    init(proposal: OnboardingProposal) {
        weightKG = proposal.weightKG
        var maintenance = proposal.caloriesKcal
        for _ in 0..<3 {
            maintenance = proposal.caloriesKcal - Self.goalAdjustment(
                goal: proposal.goalType,
                maintenance: maintenance,
                weightKG: proposal.weightKG
            )
        }
        maintenanceCalories = Self.clamp(maintenance, minimum: 1_400, maximum: 6_000)

        if let weight = proposal.weightKG, weight > 0 {
            proteinBias = Self.clamp(
                proposal.proteinG / weight - Self.baseProteinPerKG(for: proposal.goalType),
                minimum: 0,
                maximum: 0.4
            )
        } else {
            proteinBias = 0
        }
        fatFraction = Self.clamp(
            proposal.fatG * 9 / max(proposal.caloriesKcal, 1),
            minimum: 0.22,
            maximum: 0.30
        )
    }

    func target(for goal: NutritionGoalType) -> MacroTarget {
        let adjustment = Self.goalAdjustment(
            goal: goal,
            maintenance: maintenanceCalories,
            weightKG: weightKG
        )
        let calories = Self.roundTo(
            Self.clamp(maintenanceCalories + adjustment, minimum: 1_200, maximum: 6_000),
            increment: 10
        )
        let proteinEstimate = weightKG.map {
            $0 * Self.clamp(
                Self.baseProteinPerKG(for: goal) + proteinBias,
                minimum: 1.2,
                maximum: 2.2
            )
        } ?? (calories * 0.25 / 4)
        let protein = Self.roundTo(
            Self.clamp(proteinEstimate, minimum: 40, maximum: 300),
            increment: 1
        )
        let fat = Self.roundTo(
            Self.clamp(calories * fatFraction / 9, minimum: 20, maximum: 250),
            increment: 1
        )
        let carbs = Self.roundTo(
            Self.clamp(
                (calories - protein * 4 - fat * 9) / 4,
                minimum: 0,
                maximum: 900
            ),
            increment: 1
        )
        return MacroTarget(
            caloriesKcal: calories,
            proteinG: protein,
            carbsG: carbs,
            fatG: fat
        )
    }

    private static func baseProteinPerKG(for goal: NutritionGoalType) -> Double {
        switch goal {
        case .lose: 1.8
        case .maintain: 1.6
        case .gain: 1.7
        }
    }

    private static func goalAdjustment(
        goal: NutritionGoalType,
        maintenance: Double,
        weightKG: Double?
    ) -> Double {
        switch goal {
        case .maintain:
            return 0
        case .lose:
            let weightBased = weightKG.map { $0 * 0.005 * 7_700 / 7 } ?? 400
            return -clamp(
                weightBased,
                minimum: 250,
                maximum: min(750, maintenance * 0.25)
            )
        case .gain:
            let weightBased = weightKG.map { $0 * 0.0025 * 7_700 / 7 } ?? 250
            return clamp(
                weightBased,
                minimum: 150,
                maximum: min(500, maintenance * 0.20)
            )
        }
    }

    private static func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(maximum, max(minimum, value))
    }

    private static func roundTo(_ value: Double, increment: Double) -> Double {
        (value / increment).rounded() * increment
    }
}

enum OnboardingCapturePolicy {
    static let maximumTextCharacters = 30_000

    static func normalizedText(_ text: String) -> String {
        String(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maximumTextCharacters)
        )
    }

    static func canSubmit(text: String, hasAudio: Bool, isSubmitting: Bool) -> Bool {
        guard !isSubmitting, text.count <= maximumTextCharacters else { return false }
        return hasAudio || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func proposalContext(userText: String, preserving profile: Profile?) -> String {
        guard let profile else { return normalizedText(userText) }

        let optionalValue: (Double?) -> String = { value in
            value.map { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0) }
                ?? "not set"
        }
        let baseline = [
            "Existing saved profile. Preserve every value unless the user explicitly asks to change or clear it:",
            "display_name: \(profile.displayName ?? "not set")",
            "units: \(profile.units)",
            "height_cm: \(optionalValue(profile.heightCM))",
            "weight_kg: \(optionalValue(profile.weightKG))",
            "target_weight_kg: \(optionalValue(profile.targetWeightKG))",
            "activity_level: \(profile.activityLevel?.rawValue ?? "not set")",
            "goal_type: \(profile.goalType.rawValue)",
            "goal_notes: \(profile.goalNotes ?? "not set")",
            "current_targets: \(Int(profile.dailyMacroTarget.caloriesKcal.rounded())) kcal, "
                + "\(Int(profile.dailyMacroTarget.proteinG.rounded())) g protein, "
                + "\(Int(profile.dailyMacroTarget.carbsG.rounded())) g carbs, "
                + "\(Int(profile.dailyMacroTarget.fatG.rounded())) g fat",
        ].joined(separator: "\n")

        let normalizedUserText = normalizedText(userText)
        let separator = "\n\n"
        let availableUserCharacters = max(0, maximumTextCharacters - baseline.count - separator.count)
        let boundedUserText = String(normalizedUserText.prefix(availableUserCharacters))
        return [boundedUserText, baseline]
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }
}

enum ProfileLaunchDestination: Equatable {
    case onboarding
    case today
    case loading
}

enum ProfileLaunchPolicy {
    static func destination(for profile: Profile) -> ProfileLaunchDestination {
        switch profile.onboardingStatus {
        case .pending:
            return .onboarding
        case .completed, .skipped:
            return .today
        case nil:
            return .loading
        }
    }
}
