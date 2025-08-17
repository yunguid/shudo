import SwiftUI

struct OnboardingFlowView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: Profile
    let onComplete: () -> Void

    @State private var step: Int = 0 // 0..6, 7=review
    @State private var units: String
    @State private var heightFeet: Int = 5
    @State private var heightInches: Int = 10
    @State private var heightCM: Double
    @State private var weightKG: Double
    @State private var weightLBS: Double
    @State private var targetWeightKG: Double
    @State private var targetWeightLBS: Double
    @State private var activityLevel: String
    @State private var cutoffTime: Date
    @State private var isSaving = false
    @State private var error: String?

    init(profile: Profile, onComplete: @escaping () -> Void) {
        self.profile = profile
        self.onComplete = onComplete
        _units = State(initialValue: profile.units)
        let cm = profile.heightCM ?? 170
        _heightCM = State(initialValue: cm)
        let kg = profile.weightKG ?? 75
        _weightKG = State(initialValue: kg)
        _weightLBS = State(initialValue: kg * 2.20462)
        let tkg = profile.targetWeightKG ?? max(kg - 5, 50)
        _targetWeightKG = State(initialValue: tkg)
        _targetWeightLBS = State(initialValue: tkg * 2.20462)
        _activityLevel = State(initialValue: profile.activityLevel ?? "moderate")
        let cutoff = profile.cutoffTimeLocal ?? "20:00"
        _cutoffTime = State(initialValue: Self.timeFromHHmm(cutoff) ?? Self.timeFromHHmm("20:00")!)
        let (ft, inch) = Self.feetInches(fromCM: cm)
        _heightFeet = State(initialValue: ft)
        _heightInches = State(initialValue: inch)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                content
                if let e = error { Text(e).font(.caption).foregroundStyle(.red) }
                footer
            }
            .padding(20)
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: unitsStep
        case 1: heightStep
        case 2: currentWeightStep
        case 3: targetWeightStep
        case 4: activityStep
        case 5: cutoffStep
        case 6: reviewStep
        default: reviewStep
        }
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if step > 0 { Button("Back") { step -= 1 } }
            Spacer()
            Button(step < 6 ? "Next" : (isSaving ? "Saving…" : "Save & Continue")) {
                Task { await proceed() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving)
        }
    }

    // MARK: - Steps

    private var unitsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Units")
            Picker("Units", selection: $units) {
                Text("Imperial (lb, ft/in)").tag("imperial")
                Text("Metric (kg, cm)").tag("metric")
            }
            .pickerStyle(.segmented)
            .onChange(of: units) { new in
                if new == "imperial" {
                    let (ft, inch) = Self.feetInches(fromCM: heightCM)
                    heightFeet = ft; heightInches = inch
                } else {
                    heightCM = Self.cm(fromFeet: heightFeet, inches: heightInches)
                }
            }
        }
    }

    private var heightStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Height")
            if units == "imperial" {
                HStack {
                    Stepper(value: $heightFeet, in: 3...7) { Text("\(heightFeet) ft") }
                    Stepper(value: $heightInches, in: 0...11) { Text("\(heightInches) in") }
                }
            } else {
                HStack {
                    TextField("cm", value: $heightCM, formatter: NumberFormatter())
                        .keyboardType(.decimalPad)
                        .fieldStyle()
                    Text("cm").foregroundStyle(Design.Color.muted)
                }
            }
        }
    }

    private var currentWeightStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Current weight")
            if units == "imperial" {
                HStack {
                    TextField("lbs", value: $weightLBS, formatter: NumberFormatter())
                        .keyboardType(.decimalPad)
                        .fieldStyle()
                    Text("lb").foregroundStyle(Design.Color.muted)
                }
            } else {
                HStack {
                    TextField("kg", value: $weightKG, formatter: NumberFormatter())
                        .keyboardType(.decimalPad)
                        .fieldStyle()
                    Text("kg").foregroundStyle(Design.Color.muted)
                }
            }
        }
    }

    private var targetWeightStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Target weight")
            if units == "imperial" {
                HStack {
                    TextField("lbs", value: $targetWeightLBS, formatter: NumberFormatter())
                        .keyboardType(.decimalPad)
                        .fieldStyle()
                    Text("lb").foregroundStyle(Design.Color.muted)
                }
            } else {
                HStack {
                    TextField("kg", value: $targetWeightKG, formatter: NumberFormatter())
                        .keyboardType(.decimalPad)
                        .fieldStyle()
                    Text("kg").foregroundStyle(Design.Color.muted)
                }
            }
        }
    }

    private var activityStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Activity level", subtitle: "Typical daily activity")
            let options: [(String, String)] = [
                ("sedentary", "Desk job, little exercise"),
                ("light", "Light exercise 1–3 days/week"),
                ("moderate", "Moderate exercise 3–5 days/week"),
                ("active", "Hard exercise 6–7 days/week"),
                ("extra_active", "Very hard exercise/physical job")
            ]
            ForEach(options, id: \.0) { key, subtitle in
                Button {
                    activityLevel = key
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(key.replacingOccurrences(of: "_", with: " ").capitalized)
                            Text(subtitle).font(.caption).foregroundStyle(Design.Color.muted)
                        }
                        Spacer()
                        if activityLevel == key { Image(systemName: "checkmark.circle.fill") }
                    }
                }
                .buttonStyle(.plain)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous)
                        .fill(Design.Color.fill)
                )
            }
        }
    }

    private var cutoffStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Eating cutoff time")
            DatePicker("Cutoff", selection: $cutoffTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Review")
            SectionCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Units: \(units)")
                    let cm = currentHeightCM
                    let kg = currentWeightKG
                    let tkg = currentTargetWeightKG
                    Text("Height: \(Int(cm)) cm (\(Self.feetInchesString(fromCM: cm)))")
                    Text("Weight: \(String(format: "%.1f", kg)) kg (\(String(format: "%.0f", kg*2.20462)) lb)")
                    Text("Target: \(String(format: "%.1f", tkg)) kg (\(String(format: "%.0f", tkg*2.20462)) lb)")
                    Text("Activity: \(activityLevel)")
                    Text("Cutoff: \(Self.hhmm(from: cutoffTime))")
                }
            }
        }
    }

    // MARK: - Actions

    private func proceed() async {
        error = nil
        if step < 6 {
            // Validate minimal constraints per step
            switch step {
            case 1:
                let cm = currentHeightCM
                if cm < 120 || cm > 250 { error = "Enter height between 120–250 cm"; return }
            case 2:
                let kg = currentWeightKG
                if kg < 35 || kg > 200 { error = "Enter weight between 35–200 kg"; return }
            case 3:
                let t = currentTargetWeightKG
                if t <= 0 || t < 35 || t > 250 { error = "Target weight must be 35–250 kg"; return }
            case 4:
                let valid = ["sedentary","light","moderate","active","extra_active"]
                if valid.contains(activityLevel) == false { error = "Pick an activity level"; return }
            case 5:
                // Any time ok
                break
            default: break
            }
            step += 1
            return
        }

        // Save
        isSaving = true
        let cm = currentHeightCM
        let kg = currentWeightKG
        let tkg = currentTargetWeightKG
        let cutoff = Self.hhmm(from: cutoffTime)
        do {
            let svc = SupabaseService()
            try await svc.updateProfilePersonalization(
                units: units,
                heightCM: cm,
                weightKG: kg,
                targetWeightKG: tkg,
                activityLevel: activityLevel,
                cutoffTimeLocal: cutoff
            )
            _ = try await svc.computeAndSaveDailyTargets(
                weightKG: kg,
                targetWeightKG: tkg,
                activityLevel: activityLevel
            )
            isSaving = false
            onComplete()
        } catch {
            isSaving = false
            self.error = error.localizedDescription
        }
    }

    // MARK: - Helpers
    private var currentHeightCM: Double {
        units == "imperial" ? Self.cm(fromFeet: heightFeet, inches: heightInches) : heightCM
    }
    private var currentWeightKG: Double {
        units == "imperial" ? max(0, weightLBS / 2.20462) : weightKG
    }
    private var currentTargetWeightKG: Double {
        units == "imperial" ? max(0, targetWeightLBS / 2.20462) : targetWeightKG
    }

    private static func cm(fromFeet feet: Int, inches: Int) -> Double {
        let totalInches = Double(feet * 12 + inches)
        return totalInches * 2.54
    }
    private static func feetInches(fromCM cm: Double) -> (Int, Int) {
        let totalInches = cm / 2.54
        let ft = Int(totalInches / 12.0)
        let inch = Int(round(totalInches.truncatingRemainder(dividingBy: 12)))
        return (ft, min(max(inch, 0), 11))
    }
    private static func feetInchesString(fromCM cm: Double) -> String {
        let (f, i) = feetInches(fromCM: cm)
        return "\(f) ft \(i) in"
    }
    private static func hhmm(from date: Date) -> String {
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"; fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }
    private static func timeFromHHmm(_ s: String) -> Date? {
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"; fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.date(from: s)
    }
}


