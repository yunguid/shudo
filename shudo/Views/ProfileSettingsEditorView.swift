import SwiftUI

struct ProfileSettingsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var displayName: String
    @State private var timezone: String
    @State private var units: String
    @State private var heightCentimeters: String
    @State private var heightFeet: String
    @State private var heightInches: String
    @State private var weight: String
    @State private var targetWeight: String
    @State private var activityLevel: ProfileActivityLevel
    @State private var goalType: NutritionGoalType
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let profile: Profile
    private let service: SupabaseService
    private let onSaved: (Profile) -> Void

    init(
        profile: Profile,
        service: SupabaseService = SupabaseService(),
        onSaved: @escaping (Profile) -> Void
    ) {
        self.profile = profile
        self.service = service
        self.onSaved = onSaved
        _displayName = State(initialValue: profile.displayName ?? "")
        _timezone = State(initialValue: profile.timezone)
        _units = State(initialValue: profile.units)
        _heightCentimeters = State(initialValue: Self.decimalText(profile.heightCM))

        let totalInches = (profile.heightCM ?? 0) / 2.54
        var feet = Int(totalInches / 12)
        var inches = max(0, totalInches - Double(feet * 12))
        if inches >= 11.95 {
            feet += 1
            inches = 0
        }
        _heightFeet = State(initialValue: profile.heightCM == nil ? "" : String(feet))
        _heightInches = State(
            initialValue: profile.heightCM == nil ? "" : Self.decimalText(inches)
        )

        let weightScale = profile.units == "metric" ? 1 : 2.204_622_621_8
        _weight = State(initialValue: Self.decimalText(profile.weightKG.map { $0 * weightScale }))
        _targetWeight = State(
            initialValue: Self.decimalText(profile.targetWeightKG.map { $0 * weightScale })
        )
        _activityLevel = State(initialValue: profile.activityLevel ?? .moderate)
        _goalType = State(initialValue: profile.goalType)
    }

    private var usesMetric: Bool { units == "metric" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.section) {
                    // Your name, written large on the page instead of boxed
                    // in a form row.
                    TextField(
                        "",
                        text: $displayName,
                        prompt: Text("Your name").foregroundStyle(Design.Color.textTertiary)
                    )
                    .textInputAutocapitalization(.words)
                    .textContentType(.givenName)
                    .font(Design.Typeface.display(.title))
                    .foregroundStyle(Design.Color.textPrimary)
                    .tint(Design.Color.pernambuco)
                    .accessibilityLabel("Name")
                    .padding(.top, Design.Space.m)

                    SettingsGroup {
                        heightFields
                        measurementField("Weight", unit: weightUnit, text: $weight)
                        measurementField("Goal weight", unit: weightUnit, text: $targetWeight)
                    }

                    SettingsGroup {
                        SettingsRow(title: "Goal") {
                            menu("Goal", selection: $goalType) {
                                Text("Bulk").tag(NutritionGoalType.gain)
                                Text("Cut").tag(NutritionGoalType.lose)
                                Text("Maintain").tag(NutritionGoalType.maintain)
                            }
                        }
                        SettingsRow(title: "Activity") {
                            menu("Activity", selection: $activityLevel) {
                                ForEach(ProfileActivityLevel.allCases, id: \.self) { level in
                                    Text(activityLabel(level)).tag(level)
                                }
                            }
                        }
                    }

                    SettingsGroup {
                        SettingsRow(title: "Units") {
                            menu("Units", selection: $units) {
                                Text("Pounds & feet").tag("imperial")
                                Text("Kilograms & cm").tag("metric")
                            }
                        }
                        .onChange(of: units) { previous, updated in
                            convertMeasurements(from: previous, to: updated)
                        }
                        SettingsRow(title: "Time zone", subtitle: Self.cityName(timezone)) {
                            if timezone != TimeZone.autoupdatingCurrent.identifier {
                                Button("Use \(Self.cityName(TimeZone.autoupdatingCurrent.identifier))") {
                                    timezone = TimeZone.autoupdatingCurrent.identifier
                                }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Design.Color.pernambuco)
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Design.Color.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, Design.Space.xl)
                .padding(.bottom, Design.Space.xxxl)
                .settlesOnAppear()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppBackground())
            .navigationTitle("Body & goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Body & goal")
                        .font(AccountView.barTitleFont)
                        .foregroundStyle(Design.Color.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Design.Color.textPrimary)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(isSaving)
                }
            }
            .animation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion), value: errorMessage)
            .interactiveDismissDisabled(isSaving)
        }
    }

    private var weightUnit: String { usesMetric ? "kg" : "lb" }

    @ViewBuilder
    private var heightFields: some View {
        if usesMetric {
            measurementField("Height", unit: "cm", text: $heightCentimeters)
        } else {
            SettingsRow(title: "Height") {
                HStack(spacing: 10) {
                    compactNumberField(text: $heightFeet, unit: "ft", label: "Height, feet")
                    compactNumberField(text: $heightInches, unit: "in", label: "Height, inches")
                }
            }
        }
    }

    private func measurementField(
        _ label: String,
        unit: String,
        text: Binding<String>
    ) -> some View {
        SettingsRow(title: label) {
            HStack(spacing: 6) {
                numberField(text: text, label: label)
                    .frame(maxWidth: 90)
                unitLabel(unit)
            }
        }
    }

    private func compactNumberField(text: Binding<String>, unit: String, label: String) -> some View {
        HStack(spacing: 4) {
            numberField(text: text, label: label)
                .frame(width: 40)
            unitLabel(unit)
        }
    }

    private func numberField(text: Binding<String>, label: String) -> some View {
        TextField("—", text: text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .font(Design.Typeface.numeral(.body, weight: .regular))
            .monospacedDigit()
            .foregroundStyle(Design.Color.textPrimary)
            .tint(Design.Color.pernambuco)
            .accessibilityLabel(label)
    }

    private func unitLabel(_ unit: String) -> some View {
        Text(unit)
            .font(.footnote)
            .foregroundStyle(Design.Color.textTertiary)
            .frame(width: 22, alignment: .leading)
    }

    private func menu<Selection: Hashable, Content: View>(
        _ label: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Picker(label, selection: selection, content: content)
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(Design.Color.textSecondary)
            .fixedSize()
    }

    /// "America/New_York" → "New York".
    private static func cityName(_ identifier: String) -> String {
        (identifier.split(separator: "/").last.map(String.init) ?? identifier)
            .replacingOccurrences(of: "_", with: " ")
    }

    private func save() {
        guard !isSaving else { return }
        do {
            let update = try makeUpdate()
            isSaving = true
            errorMessage = nil
            Task {
                do {
                    let updated = try await service.updateProfile(update)
                    await MainActor.run {
                        ProfileCache.save(updated)
                        onSaved(updated)
                        isSaving = false
                        dismiss()
                    }
                } catch {
                    await MainActor.run {
                        isSaving = false
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeUpdate() throws -> ProfileSettingsUpdate {
        let heightCM: Double?
        if usesMetric {
            heightCM = try optionalNumber(heightCentimeters, label: "Height")
        } else {
            let feet = try optionalNumber(heightFeet, label: "Height")
            let inches = try optionalNumber(heightInches, label: "Height")
            if feet == nil && inches == nil {
                heightCM = nil
            } else {
                guard let feet, let inches, feet >= 0, inches >= 0, inches < 12 else {
                    throw ValidationError("Enter height using feet and inches.")
                }
                heightCM = (feet * 12 + inches) * 2.54
            }
        }

        let weightScale = usesMetric ? 1 : 0.453_592_37
        return ProfileSettingsUpdate(
            timezone: timezone,
            units: units,
            displayName: displayName,
            heightCM: heightCM,
            weightKG: try optionalNumber(weight, label: "Current weight").map { $0 * weightScale },
            targetWeightKG: try optionalNumber(targetWeight, label: "Goal weight").map { $0 * weightScale },
            activityLevel: activityLevel,
            goalType: goalType,
            // Free-form context lives in the bio now; keep what's stored.
            goalNotes: profile.goalNotes
        )
    }

    private func convertMeasurements(from previousUnits: String, to updatedUnits: String) {
        guard previousUnits != updatedUnits else { return }

        if updatedUnits == "metric" {
            if let feet = Self.parsedNumber(heightFeet),
               let inches = Self.parsedNumber(heightInches) {
                heightCentimeters = Self.decimalText((feet * 12 + inches) * 2.54)
            }
            weight = Self.convertedText(weight, factor: 0.453_592_37)
            targetWeight = Self.convertedText(targetWeight, factor: 0.453_592_37)
        } else {
            if let centimeters = Self.parsedNumber(heightCentimeters) {
                let totalInches = centimeters / 2.54
                var feet = Int(totalInches / 12)
                var inches = totalInches - Double(feet * 12)
                if inches >= 11.95 {
                    feet += 1
                    inches = 0
                }
                heightFeet = String(feet)
                heightInches = Self.decimalText(inches)
            }
            weight = Self.convertedText(weight, factor: 2.204_622_621_8)
            targetWeight = Self.convertedText(targetWeight, factor: 2.204_622_621_8)
        }
    }

    private func optionalNumber(_ value: String, label: String) throws -> Double? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty else { return nil }
        guard let parsed = Double(normalized), parsed.isFinite else {
            throw ValidationError("Enter a valid number for \(label.lowercased()).")
        }
        return parsed
    }

    private func activityLabel(_ level: ProfileActivityLevel) -> String {
        switch level {
        case .sedentary: return "Sedentary"
        case .light: return "Light"
        case .moderate: return "Moderate"
        case .active: return "Active"
        case .extraActive: return "Very active"
        }
    }

    private static func decimalText(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(0...1)))
    }

    private static func parsedNumber(_ text: String) -> Double? {
        Double(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: ".")
        )
    }

    private static func convertedText(_ text: String, factor: Double) -> String {
        guard let value = parsedNumber(text) else { return text }
        return decimalText(value * factor)
    }
}

private struct ValidationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
