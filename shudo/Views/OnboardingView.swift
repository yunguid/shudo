import SwiftUI
import UIKit

struct OnboardingView: View {
    private enum Field: Hashable {
        case context
        case displayName
        case height
        case heightFeet
        case heightInches
        case weight
        case targetWeight
        case goalNotes
        case calories
        case protein
        case carbs
        case fat
    }

    private let service: any OnboardingServing
    private let initialProfile: Profile?
    private let onCompleted: (Profile) -> Void

    @StateObject private var audio = AudioRecorder()
    @State private var context = ""
    @State private var clientRequestID = UUID()
    @State private var proposalResult: OnboardingProposalResult?
    @State private var draft: OnboardingDraft?
    @State private var isPreparing = false
    @State private var isApplying = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    init(
        initialProfile: Profile? = nil,
        service: (any OnboardingServing)? = nil,
        onCompleted: @escaping (Profile) -> Void
    ) {
        self.initialProfile = initialProfile
        self.service = service ?? OnboardingService()
        self.onCompleted = onCompleted
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                Group {
                    if let proposalResult, draft != nil {
                        reviewContent(proposalResult)
                    } else {
                        captureContent
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 128)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom) {
            bottomAction
        }
        .onDisappear {
            audio.discardRecording()
        }
    }

    private var captureContent: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Set your daily targets")
                    .font(.system(.largeTitle, design: .default, weight: .bold))
                    .foregroundStyle(Design.Color.ink)

                Text("Describe your height, weight, activity, diet, and goal.")
                    .font(.title3)
                    .foregroundStyle(Design.Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            voiceCard

            VStack(alignment: .leading, spacing: 10) {
                Text("Or type a short description")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Design.Color.ink)

                ZStack(alignment: .topLeading) {
                    if context.isEmpty {
                        Text("Example: I’m 5'10\", 165 lb, fairly active, vegetarian, and want to gain muscle slowly.")
                            .font(.body)
                            .foregroundStyle(Design.Color.muted)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 15)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $context)
                        .font(.body)
                        .foregroundStyle(Design.Color.ink)
                        .accessibilityLabel("Profile description")
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .frame(minHeight: 120, maxHeight: 190)
                        .focused($focusedField, equals: .context)
                        .onChange(of: context) { _, value in
                            guard value.count > OnboardingCapturePolicy.maximumTextCharacters else {
                                return
                            }
                            context = OnboardingCapturePolicy.normalizedText(value)
                        }
                }
                .background(
                    Design.Color.elevated,
                    in: RoundedRectangle(cornerRadius: Design.Radius.xl, style: .continuous)
                )
            }

            if isPreparing {
                preparingCard
            }

            errorView
        }
    }

    private var voiceCard: some View {
        VStack(spacing: 18) {
            OnboardingAudioMeter(levels: audio.meterLevels, isActive: audio.isRecording)
                .frame(height: 66)

            VStack(spacing: 4) {
                Text(voiceHeadline)
                    .font(
                        audio.isRecording
                            ? .system(size: 25, weight: .medium)
                            : .headline
                    )
                    .foregroundStyle(Design.Color.ink)
                    .monospacedDigit()

                Text(voiceDetail)
                    .font(.footnote)
                    .foregroundStyle(Design.Color.muted)
                    .monospacedDigit()
            }

            HStack(spacing: 16) {
                if hasAudio && !audio.isRecording {
                    Button {
                        audio.discardRecording()
                    } label: {
                        Image(systemName: "trash")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Design.Color.muted)
                            .frame(width: 48, height: 48)
                            .background(Design.Color.glassFill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Discard voice setup")
                }

                Button {
                    Task { await toggleRecording() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                audio.isRecording
                                    ? AnyShapeStyle(Design.Color.danger)
                                    : AnyShapeStyle(
                                        LinearGradient(
                                            colors: [
                                                Design.Color.accentPrimary,
                                                Design.Color.accentSecondary
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                            .frame(width: 76, height: 76)
                            .shadow(
                                color: Design.Color.accentPrimary.opacity(
                                    audio.isRecording ? 0.12 : 0.28
                                ),
                                radius: 24
                            )

                        Image(systemName: audio.isRecording ? "stop.fill" : "waveform")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isPreparing)
                .accessibilityLabel(audio.isRecording ? "Stop recording" : "Start recording")
            }
        }
        .padding(22)
        .background(
            Design.Color.elevated,
            in: RoundedRectangle(cornerRadius: Design.Radius.hero, style: .continuous)
        )
    }

    private var preparingCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(Design.Color.accentSecondary)
                Text("Building your targets…")
                    .font(.headline)
                    .foregroundStyle(Design.Color.ink)
            }

            VStack(alignment: .leading, spacing: 8) {
                shimmerLine(width: 0.92)
                shimmerLine(width: 0.72)
                shimmerLine(width: 0.84)
            }
        }
        .padding(20)
        .background(
            Design.Color.elevated,
            in: RoundedRectangle(cornerRadius: Design.Radius.xl, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Building your daily targets")
    }

    private func shimmerLine(width: CGFloat) -> some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Design.Color.subtle.opacity(0.45))
                .frame(width: geometry.size.width * width, height: 10)
                .shimmering()
        }
        .frame(height: 10)
    }

    private func reviewContent(_ result: OnboardingProposalResult) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Review your targets")
                    .font(.system(.largeTitle, design: .default, weight: .bold))
                    .foregroundStyle(Design.Color.ink)

                Text(result.proposal.summary)
                    .font(.title3)
                    .foregroundStyle(Design.Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            sectionCard(title: "About you") {
                editableRow(title: "Name", unit: nil) {
                    TextField(
                        "Optional",
                        text: binding(\.displayName, fallback: "")
                    )
                    .textContentType(.name)
                    .focused($focusedField, equals: .displayName)
                }

                rowDivider

                heightReviewRow

                rowDivider

                editableRow(title: "Weight", unit: reviewWeightUnit) {
                    numericField(\.weight, prompt: "—", field: .weight)
                }

                rowDivider

                editableRow(title: "Target", unit: reviewWeightUnit) {
                    numericField(\.targetWeight, prompt: "—", field: .targetWeight)
                }

                rowDivider

                HStack {
                    Text("Activity")
                        .foregroundStyle(Design.Color.ink)
                    Spacer()
                    Picker("Activity", selection: binding(\.activityLevel, fallback: .moderate)) {
                        ForEach(ProfileActivityLevel.allCases, id: \.self) { activity in
                            Text(activity.onboardingTitle).tag(activity)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(Design.Color.accentSecondary)
                }
                .frame(minHeight: 44)
            }

            sectionCard(title: "Goal, diet & preferences") {
                Picker("Goal", selection: goalSelection) {
                    ForEach(NutritionGoalType.allCases, id: \.self) { goal in
                        Text(goal.onboardingTitle).tag(goal)
                    }
                }
                .pickerStyle(.segmented)

                ZStack(alignment: .topLeading) {
                    if draft?.goalNotes.isEmpty != false {
                        Text("Diet, allergies, routine, or goal details")
                            .foregroundStyle(Design.Color.muted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: binding(\.goalNotes, fallback: ""))
                        .foregroundStyle(Design.Color.ink)
                        .accessibilityLabel("Diet, allergies, routine, or goal details")
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 88, maxHeight: 140)
                        .focused($focusedField, equals: .goalNotes)
                }
                .padding(.horizontal, 9)
                .background(
                    Design.Color.glassFill,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Daily targets")
                    .font(.headline)
                    .foregroundStyle(Design.Color.ink)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    macroField(
                        title: "Calories",
                        unit: "kcal",
                        keyPath: \.caloriesKcal,
                        field: .calories
                    )
                    macroField(
                        title: "Protein",
                        unit: "g",
                        keyPath: \.proteinG,
                        field: .protein
                    )
                    macroField(
                        title: "Carbs",
                        unit: "g",
                        keyPath: \.carbsG,
                        field: .carbs
                    )
                    macroField(
                        title: "Fat",
                        unit: "g",
                        keyPath: \.fatG,
                        field: .fat
                    )
                }
            }

            if !result.proposal.assumptions.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(result.proposal.assumptions, id: \.self) { assumption in
                            Label(assumption, systemImage: "circle.fill")
                                .labelStyle(OnboardingBulletLabelStyle())
                                .font(.footnote)
                                .foregroundStyle(Design.Color.muted)
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    Text("How these were estimated")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.ink)
                }
                .tint(Design.Color.accentSecondary)
                .padding(18)
                .background(
                    Design.Color.elevated,
                    in: RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
                )
            }

            Button("Start over") {
                startOver()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Design.Color.muted)
            .frame(maxWidth: .infinity, minHeight: 44)
            .buttonStyle(.plain)
            .disabled(isApplying)

            errorView
        }
    }

    private func sectionCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Design.Color.ink)
            content()
        }
        .padding(18)
        .background(
            Design.Color.elevated,
            in: RoundedRectangle(cornerRadius: Design.Radius.xl, style: .continuous)
        )
    }

    private func editableRow<Content: View>(
        title: String,
        unit: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(Design.Color.ink)
            Spacer(minLength: 14)
            content()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Design.Color.accentSecondary)
            if let unit {
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(Design.Color.muted)
            }
        }
        .frame(minHeight: 44)
    }

    private var rowDivider: some View { HairlineRule() }

    @ViewBuilder
    private var heightReviewRow: some View {
        if reviewUnits == .metric {
            editableRow(title: "Height", unit: "cm") {
                numericField(\.heightCentimeters, prompt: "—", field: .height)
            }
        } else {
            editableRow(title: "Height", unit: nil) {
                HStack(spacing: 10) {
                    compactMeasurementField(
                        \.heightFeet,
                        prompt: "—",
                        unit: "ft",
                        field: .heightFeet
                    )
                    compactMeasurementField(
                        \.heightInches,
                        prompt: "—",
                        unit: "in",
                        field: .heightInches
                    )
                }
            }
        }
    }

    private var reviewUnits: OnboardingUnitPreference {
        draft?.units ?? OnboardingUnitPreference(profileUnits: initialProfile?.units)
    }

    private var reviewWeightUnit: String {
        reviewUnits == .metric ? "kg" : "lb"
    }

    private func numericField(
        _ keyPath: WritableKeyPath<OnboardingDraft, String>,
        prompt: String,
        field: Field
    ) -> some View {
        TextField(prompt, text: binding(keyPath, fallback: ""))
            .keyboardType(.decimalPad)
            .focused($focusedField, equals: field)
            .frame(maxWidth: 120)
    }

    private func compactMeasurementField(
        _ keyPath: WritableKeyPath<OnboardingDraft, String>,
        prompt: String,
        unit: String,
        field: Field
    ) -> some View {
        HStack(spacing: 4) {
            TextField(prompt, text: binding(keyPath, fallback: ""))
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: field)
                .frame(width: 42)
            Text(unit)
                .font(.caption)
                .foregroundStyle(Design.Color.muted)
        }
    }

    private func macroField(
        title: String,
        unit: String,
        keyPath: WritableKeyPath<OnboardingDraft, String>,
        field: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Design.Color.muted)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                TextField("0", text: binding(keyPath, fallback: ""))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Design.Color.ink)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: field)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(Design.Color.muted)
            }
        }
        .padding(16)
        .background(
            Design.Color.elevated,
            in: RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
        )
    }

    @ViewBuilder
    private var errorView: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(Design.Color.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var bottomAction: some View {
        if proposalResult != nil {
            Button {
                Task { await applyProposal() }
            } label: {
                HStack(spacing: 9) {
                    if isApplying {
                        ProgressView().tint(.white)
                    }
                    Text(isApplying ? "Saving…" : "Apply targets")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isApplying)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        } else {
            Button {
                Task { await prepareProposal() }
            } label: {
                HStack(spacing: 9) {
                    if isPreparing {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                    }
                    Text(isPreparing ? "Preparing…" : "Create my targets")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canPrepare)
            .opacity(canPrepare ? 1 : 0.48)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }

    private var hasAudio: Bool {
        audio.recordedFileURL != nil
    }

    private var canPrepare: Bool {
        OnboardingCapturePolicy.canSubmit(
            text: context,
            hasAudio: hasAudio,
            isSubmitting: isPreparing
        )
    }

    private var voiceHeadline: String {
        if audio.isRecording { return formatTime(audio.elapsedTime) }
        return hasAudio ? "Voice setup ready" : "Describe your goals"
    }

    private var voiceDetail: String {
        if audio.isRecording { return "Tap when you’re done" }
        return hasAudio ? formatTime(audio.elapsedTime) : "Tap to record"
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<OnboardingDraft, Value>,
        fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard var updated = draft else { return }
                updated[keyPath: keyPath] = value
                draft = updated
            }
        )
    }

    private var goalSelection: Binding<NutritionGoalType> {
        Binding(
            get: { draft?.goalType ?? .maintain },
            set: { goal in
                guard var updated = draft, updated.goalType != goal else { return }
                updated.applyGoal(goal)
                draft = updated
                errorMessage = nil
                UISelectionFeedbackGenerator().selectionChanged()
            }
        )
    }

    @MainActor
    private func toggleRecording() async {
        errorMessage = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if audio.isRecording {
            audio.stopRecording()
        } else {
            focusedField = nil
            _ = await audio.startRecording()
        }
    }

    @MainActor
    private func prepareProposal() async {
        if audio.isRecording { audio.stopRecording() }
        guard OnboardingCapturePolicy.canSubmit(
            text: context,
            hasAudio: hasAudio,
            isSubmitting: false
        ) else {
            errorMessage = OnboardingService.ServiceError.invalidCapture.localizedDescription
            return
        }

        focusedField = nil
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }

        do {
            let result = try await service.createProposal(
                text: OnboardingCapturePolicy.proposalContext(
                    userText: context,
                    preserving: initialProfile
                ),
                audioData: audio.recordedData(),
                timezone: TimeZone.autoupdatingCurrent.identifier,
                clientRequestID: clientRequestID
            )
            proposalResult = result
            draft = OnboardingDraft(
                proposal: result.proposal,
                profileUnits: initialProfile?.units
            )
            audio.discardRecording()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch OnboardingService.ServiceError.alreadyApplied {
            await finishWithAuthoritativeProfile()
        } catch OnboardingService.ServiceError.analysisFailed {
            clientRequestID = UUID()
            errorMessage = OnboardingService.ServiceError.analysisFailed.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        } catch {
            errorMessage = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    @MainActor
    private func applyProposal() async {
        guard let proposalResult, let draft else { return }
        let overrides: OnboardingOverrides
        do {
            overrides = try draft.validatedOverrides()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        focusedField = nil
        isApplying = true
        errorMessage = nil
        defer { isApplying = false }

        do {
            try await service.applyProposal(
                onboardingID: proposalResult.onboardingID,
                overrides: overrides
            )
            await finishWithAuthoritativeProfile()
        } catch {
            errorMessage = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    @MainActor
    private func finishWithAuthoritativeProfile() async {
        do {
            let profile = try await service.fetchAuthoritativeProfile()
            ProfileCache.save(profile)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCompleted(profile)
        } catch {
            errorMessage = "Your targets were saved, but the profile couldn’t refresh. Try again."
        }
    }

    private func startOver() {
        proposalResult = nil
        draft = nil
        context = ""
        clientRequestID = UUID()
        errorMessage = nil
    }

    private func formatTime(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct OnboardingAudioMeter: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let levels: [CGFloat]
    let isActive: Bool

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 4
            let count = max(1, levels.count)
            let available = geometry.size.width - spacing * CGFloat(count - 1)
            let width = max(2, available / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(
                            isActive
                                ? Design.Color.accentPrimary
                                : Design.Color.subtle.opacity(0.55)
                        )
                        .frame(width: width, height: max(4, geometry.size.height * level))
                        .animation(reduceMotion ? nil : .linear(duration: 0.055), value: level)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

private struct OnboardingBulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            configuration.icon
                .font(.system(size: 5))
                .foregroundStyle(Design.Color.accentSecondary)
            configuration.title
        }
    }
}

private extension ProfileActivityLevel {
    var onboardingTitle: String {
        switch self {
        case .sedentary: return "Mostly seated"
        case .light: return "Light"
        case .moderate: return "Moderate"
        case .active: return "Active"
        case .extraActive: return "Very active"
        }
    }
}

private extension NutritionGoalType {
    var onboardingTitle: String {
        switch self {
        case .maintain: return "Maintain"
        case .lose: return "Cut"
        case .gain: return "Bulk"
        }
    }
}
