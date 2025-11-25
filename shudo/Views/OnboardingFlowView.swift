import SwiftUI

struct OnboardingFlowView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: Profile
    let onComplete: () -> Void

    @State private var step: Int = 0
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
            VStack(spacing: 0) {
                // Progress indicator
                HStack(spacing: 4) {
                    ForEach(0..<7) { i in
                        Capsule()
                            .fill(i <= step ? Design.Color.accentPrimary : Design.Color.elevated)
                            .frame(height: 3)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                
                ScrollView {
                    VStack(spacing: 24) {
                        content
                        
                        if let e = error {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Design.Color.danger)
                                Text(e)
                                    .font(.caption)
                                    .foregroundStyle(Design.Color.danger)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Design.Color.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: Design.Radius.m))
                        }
                    }
                    .padding(20)
                }
                
                // Footer
                HStack {
                    if step > 0 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { step -= 1 }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    
                    Spacer()
                    
                    Button {
                        Task { await proceed() }
                    } label: {
                        HStack(spacing: 6) {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            }
                            Text(step < 6 ? "Continue" : (isSaving ? "Saving…" : "Get Started"))
                            if step < 6 {
                                Image(systemName: "chevron.right")
                            }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isSaving)
                }
                .padding(20)
                .background(Design.Color.paper)
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .background(Design.Color.paper)
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

    // MARK: - Steps

    private var unitsStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "ruler",
                title: "Measurement Units",
                subtitle: "Choose your preferred units"
            )
            
            VStack(spacing: 8) {
                unitOption("imperial", "Imperial", "Pounds, feet & inches")
                unitOption("metric", "Metric", "Kilograms & centimeters")
            }
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
    
    private func unitOption(_ value: String, _ title: String, _ subtitle: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { units = value }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)
                }
                Spacer()
                Circle()
                    .fill(units == value ? Design.Color.accentPrimary : Design.Color.elevated)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Circle()
                            .fill(.white)
                            .frame(width: 8, height: 8)
                            .opacity(units == value ? 1 : 0)
                    )
            }
            .padding(16)
            .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m))
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.m)
                    .stroke(units == value ? Design.Color.accentPrimary : Design.Color.rule, lineWidth: units == value ? 2 : Design.Stroke.hairline)
            )
        }
        .buttonStyle(.plain)
    }

    private var heightStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "arrow.up.and.down",
                title: "Your Height",
                subtitle: "This helps us calculate your targets"
            )
            
            if units == "imperial" {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Feet")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Design.Color.muted)
                        Stepper(value: $heightFeet, in: 3...7) {
                            Text("\(heightFeet) ft")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(Design.Color.ink)
                        }
                        .padding(12)
                        .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Inches")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Design.Color.muted)
                        Stepper(value: $heightInches, in: 0...11) {
                            Text("\(heightInches) in")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(Design.Color.ink)
                        }
                        .padding(12)
                        .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Centimeters")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Design.Color.muted)
                    HStack {
                        TextField("cm", value: $heightCM, formatter: NumberFormatter())
                            .keyboardType(.decimalPad)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Design.Color.ink)
                        Text("cm")
                            .foregroundStyle(Design.Color.muted)
                    }
                    .padding(16)
                    .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m))
                }
            }
        }
    }

    private var currentWeightStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "scalemass",
                title: "Current Weight",
                subtitle: "Your starting point"
            )
            
            VStack(alignment: .leading, spacing: 6) {
                Text(units == "imperial" ? "Pounds" : "Kilograms")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Design.Color.muted)
                HStack {
                    TextField(units == "imperial" ? "lbs" : "kg", value: units == "imperial" ? $weightLBS : $weightKG, formatter: NumberFormatter())
                        .keyboardType(.decimalPad)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Design.Color.ink)
                    Text(units == "imperial" ? "lb" : "kg")
                        .foregroundStyle(Design.Color.muted)
                }
                .padding(16)
                .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m))
            }
        }
    }

    private var targetWeightStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "target",
                title: "Goal Weight",
                subtitle: "Where you want to be"
            )
            
            VStack(alignment: .leading, spacing: 6) {
                Text(units == "imperial" ? "Pounds" : "Kilograms")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Design.Color.muted)
                HStack {
                    TextField(units == "imperial" ? "lbs" : "kg", value: units == "imperial" ? $targetWeightLBS : $targetWeightKG, formatter: NumberFormatter())
                        .keyboardType(.decimalPad)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Design.Color.ink)
                    Text(units == "imperial" ? "lb" : "kg")
                        .foregroundStyle(Design.Color.muted)
                }
                .padding(16)
                .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m))
            }
        }
    }

    private var activityStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "figure.walk",
                title: "Activity Level",
                subtitle: "Your typical daily activity"
            )
            
            let options: [(String, String, String)] = [
                ("sedentary", "Sedentary", "Desk job, little exercise"),
                ("light", "Light", "Light exercise 1–3 days/week"),
                ("moderate", "Moderate", "Exercise 3–5 days/week"),
                ("active", "Active", "Hard exercise 6–7 days/week"),
                ("extra_active", "Very Active", "Physical job or intense training")
            ]
            
            VStack(spacing: 8) {
                ForEach(options, id: \.0) { key, title, subtitle in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { activityLevel = key }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Design.Color.ink)
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(Design.Color.muted)
                            }
                            Spacer()
                            if activityLevel == key {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Design.Color.accentPrimary)
                            }
                        }
                        .padding(14)
                        .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m))
                        .overlay(
                            RoundedRectangle(cornerRadius: Design.Radius.m)
                                .stroke(activityLevel == key ? Design.Color.accentPrimary : Design.Color.rule, lineWidth: activityLevel == key ? 2 : Design.Stroke.hairline)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var cutoffStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "moon.stars",
                title: "Eating Cutoff",
                subtitle: "When should you stop eating each day?"
            )
            
            DatePicker("", selection: $cutoffTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.l))
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(
                icon: "checkmark.circle",
                title: "Ready to Go!",
                subtitle: "Review your settings"
            )
            
            VStack(spacing: 12) {
                let cm = currentHeightCM
                let kg = currentWeightKG
                let tkg = currentTargetWeightKG
                
                reviewRow("Units", units.capitalized)
                reviewRow("Height", units == "imperial" ? Self.feetInchesString(fromCM: cm) : "\(Int(cm)) cm")
                reviewRow("Current Weight", units == "imperial" ? "\(Int(kg * 2.20462)) lb" : "\(String(format: "%.1f", kg)) kg")
                reviewRow("Goal Weight", units == "imperial" ? "\(Int(tkg * 2.20462)) lb" : "\(String(format: "%.1f", tkg)) kg")
                reviewRow("Activity", activityLevel.replacingOccurrences(of: "_", with: " ").capitalized)
                reviewRow("Eating Cutoff", Self.hhmm(from: cutoffTime))
            }
            .padding(16)
            .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.l))
        }
    }
    
    private func stepHeader(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Design.Color.accentPrimary)
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Design.Color.ink)
            }
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Design.Color.muted)
        }
    }
    
    private func reviewRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Design.Color.muted)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Design.Color.ink)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func proceed() async {
        error = nil
        if step < 6 {
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
            default: break
            }
            withAnimation(.easeInOut(duration: 0.2)) { step += 1 }
            return
        }

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
        return "\(f)' \(i)\""
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
