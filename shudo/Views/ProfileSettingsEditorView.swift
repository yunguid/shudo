import SwiftUI

struct ProfileSettingsEditorView: View {
    @Environment(\.dismiss) private var dismiss

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
    @State private var goalNotes: String
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
        _goalNotes = State(initialValue: profile.goalNotes ?? "")
    }

    private var usesMetric: Bool { units == "metric" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    fieldGroup("PREFERENCES") {
                        pickerRow("Units", selection: $units) {
                            Text("Imperial").tag("imperial")
                            Text("Metric").tag("metric")
                        }
                        .onChange(of: units) { previous, updated in
                            convertMeasurements(from: previous, to: updated)
                        }
                        rowDivider
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Timezone")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Design.Color.ink)
                                Text(timezone)
                                    .font(.caption)
                                    .foregroundStyle(Design.Color.muted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 10)
                            Button("Use current") {
                                timezone = TimeZone.autoupdatingCurrent.identifier
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Design.Color.accentPrimary)
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 58)
                    }

                    fieldGroup("PROFILE") {
                        textField("Name (optional)", text: $displayName)
                        rowDivider
                        heightFields
                        rowDivider
                        measurementField(
                            "Current weight",
                            unit: usesMetric ? "kg" : "lb",
                            text: $weight
                        )
                        rowDivider
                        measurementField(
                            "Goal weight",
                            unit: usesMetric ? "kg" : "lb",
                            text: $targetWeight
                        )
                    }

                    fieldGroup("DIRECTION") {
                        pickerRow("Goal", selection: $goalType) {
                            Text("Maintain").tag(NutritionGoalType.maintain)
                            Text("Lose").tag(NutritionGoalType.lose)
                            Text("Gain").tag(NutritionGoalType.gain)
                        }
                        rowDivider
                        pickerRow("Activity", selection: $activityLevel) {
                            ForEach(ProfileActivityLevel.allCases, id: \.self) { level in
                                Text(activityLabel(level)).tag(level)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("CONTEXT")
                            .font(.caption.weight(.semibold))
                            .tracking(1.2)
                            .foregroundStyle(Design.Color.muted)
                        TextField(
                            "Anything useful about your goal, routine, or diet",
                            text: $goalNotes,
                            axis: .vertical
                        )
                        .lineLimit(4...8)
                        .foregroundStyle(Design.Color.ink)
                        .padding(14)
                        .background(
                            Design.Color.elevated,
                            in: RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous)
                        )
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Design.Color.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Daily calories and macros stay independently editable in Settings.")
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)
                }
                .padding(20)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Design.Color.paper)
            .navigationTitle("Goals & profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Design.Color.muted)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .foregroundStyle(Design.Color.accentPrimary)
                        .disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    @ViewBuilder
    private var heightFields: some View {
        if usesMetric {
            measurementField("Height", unit: "cm", text: $heightCentimeters)
        } else {
            HStack(spacing: 12) {
                Text("Height")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Design.Color.ink)
                Spacer(minLength: 12)
                compactNumberField(text: $heightFeet, unit: "ft")
                compactNumberField(text: $heightInches, unit: "in")
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
        }
    }

    private func fieldGroup<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(Design.Color.muted)
            VStack(spacing: 0) { content() }
                .background(
                    Design.Color.elevated,
                    in: RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous)
                )
        }
    }

    private func textField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textInputAutocapitalization(.words)
            .foregroundStyle(Design.Color.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 54)
    }

    private func measurementField(
        _ label: String,
        unit: String,
        text: Binding<String>
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Design.Color.ink)
            Spacer(minLength: 12)
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Design.Color.ink)
                .frame(width: 92)
            Text(unit)
                .font(.caption)
                .foregroundStyle(Design.Color.muted)
                .frame(width: 24, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 54)
    }

    private func compactNumberField(text: Binding<String>, unit: String) -> some View {
        HStack(spacing: 5) {
            TextField("—", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Design.Color.ink)
                .frame(width: 42)
            Text(unit)
                .font(.caption)
                .foregroundStyle(Design.Color.muted)
        }
    }

    private func pickerRow<Selection: Hashable, Content: View>(
        _ label: String,
        selection: Binding<Selection>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Design.Color.ink)
            Spacer(minLength: 12)
            Picker(label, selection: selection, content: content)
                .labelsHidden()
                .tint(Design.Color.accentPrimary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 54)
    }

    private var rowDivider: some View {
        Divider().background(Design.Color.rule).padding(.leading, 14)
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
            goalNotes: goalNotes
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
