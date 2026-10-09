import SwiftUI
import UIKit

struct OnboardingView: View {
    fileprivate enum Field: Hashable {
        case displayName
        case height
        case heightFeet
        case heightInches
        case weight
        case targetWeight
        case calories
        case protein
        case carbs
        case fat
    }

    private let service: any OnboardingServing
    private let initialProfile: Profile?
    private let onCompleted: (Profile) -> Void

    /// Held unobserved: only the bottom bar observes it, so meter updates
    /// never re-render the rest of the screen.
    @StateObject private var voiceHolder = UnobservedHolder(VoiceTranscriber(profile: .onboarding))
    @State private var dictatedTakeCount = 0
    @State private var dictatedEngine: SpeechEngineID?
    @State private var context = ""
    @State private var clientRequestID = UUID()
    @State private var proposalResult: OnboardingProposalResult?
    @State private var draft: OnboardingDraft?
    @State private var isPreparing = false
    @State private var isApplying = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        initialProfile: Profile? = nil,
        service: (any OnboardingServing)? = nil,
        onCompleted: @escaping (Profile) -> Void
    ) {
        self.initialProfile = initialProfile
        self.service = service ?? OnboardingService()
        self.onCompleted = onCompleted
        #if DEBUG
            // PolishPreview screenshots: `-shudoOnboardingReview` opens on
            // the review step with a lean-bulk proposal.
            if ProcessInfo.processInfo.arguments.contains("-shudoOnboardingReview") {
                let result = Self.previewProposal
                _proposalResult = State(initialValue: result)
                _draft = State(initialValue: OnboardingDraft(proposal: result.proposal, profileUnits: initialProfile?.units))
            }
        #endif
    }

    #if DEBUG
        private static let previewProposal = OnboardingProposalResult(
            onboardingID: UUID(),
            transcript: "",
            proposal: OnboardingProposal(
                summary: "A lean bulk from 162.5 to 175 lb: a modest surplus on six training days, protein high to keep the gain mostly muscle.",
                displayName: "Luke",
                goalType: .gain,
                goalNotes: "",
                heightCM: 177.8,
                weightKG: 73.7,
                targetWeightKG: 79.4,
                activityLevel: .active,
                caloriesKcal: 2_900,
                proteinG: 175,
                carbsG: 365,
                fatG: 82,
                assumptions: [],
                suggestions: []
            )
        )
    #endif

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                ZStack(alignment: .topLeading) {
                    // Two pages side by side, like shoji panels: the
                    // capture page slides off to the left as the review
                    // slides in from the right (and back on Start over).
                    if let proposalResult, draft != nil {
                        reviewContent(proposalResult)
                            .transition(.shoji(.trailing, reduceMotion: reduceMotion))
                    } else {
                        captureContent
                            .transition(.shoji(.leading, reduceMotion: reduceMotion))
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.horizontal, Design.Space.xl)
                .padding(.top, Design.Space.xl)
                .padding(.bottom, 128)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .safeAreaInset(edge: .bottom) {
            bottomAction
        }
        .animation(Design.Motion.calm(Design.Motion.shoji, reduceMotion: reduceMotion), value: isReviewing)
        .onChange(of: context) { _, value in
            guard value.count > OnboardingCapturePolicy.maximumTextCharacters else { return }
            context = OnboardingCapturePolicy.normalizedText(value)
        }
        .onDisappear {
            voice.cancel()
        }
    }

    private var isReviewing: Bool { proposalResult != nil && draft != nil }

    /// A fresh sheet: the question in serif, set well down the page, and in
    /// the margin the three things worth saying. Everything else is paper
    /// waiting for your words.
    private var captureContent: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxl) {
            CoachAvatar(size: 44, isThinking: isPreparing)

            VStack(alignment: .leading, spacing: Design.Space.m) {
                Text(isPreparing ? "Working out your numbers…" : "Tell me about you")
                    .font(Design.Typeface.display(.largeTitle))
                    .foregroundStyle(Design.Color.textPrimary)
                    .contentTransition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)

                if !isPreparing {
                    Text("Tap the mic and talk it through, or type it below.")
                        .font(Design.Typeface.text(.body))
                        .foregroundStyle(Design.Color.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }

            if !isPreparing {
                marginNotes
                    .transition(.opacity)
            }

            errorView
        }
        .padding(.top, Design.Space.xxl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Design.Motion.calm(Design.Motion.breath, reduceMotion: reduceMotion), value: isPreparing)
    }

    /// What to mention, set against a thin margin rule so it reads as a
    /// note on the page, not as fields to fill.
    private var marginNotes: some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            ForEach(["Height and weight", "How active you are", "What you’re after"], id: \.self) { line in
                Text(line)
                    .font(Design.Typeface.text(.body))
                    .foregroundStyle(Design.Color.textTertiary)
            }
        }
        .padding(.leading, Design.Space.l)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Design.Color.pernambuco.opacity(0.55))
                .frame(width: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mention your height and weight, how active you are, and what you’re after.")
    }

    private var voice: VoiceTranscriber { voiceHolder.value }

    /// The proposal as a ledger: one hero figure (calories), the macros
    /// beneath it, then you.
    private func reviewContent(_ result: OnboardingProposalResult) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.section) {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                Text("Your targets")
                    .font(Design.Typeface.display(.largeTitle))
                    .foregroundStyle(Design.Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                Text(result.proposal.summary)
                    .font(Design.Typeface.text(.body))
                    .foregroundStyle(Design.Color.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Goal", selection: goalSelection) {
                ForEach(NutritionGoalType.allCases, id: \.self) { goal in
                    Text(goal.onboardingTitle).tag(goal)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: Design.Space.l) {
                caloriesFigure
                SettingsGroup {
                    macroRow(title: "Protein", color: Design.Color.macroProtein, keyPath: \.proteinG, field: .protein)
                    macroRow(title: "Carbs", color: Design.Color.macroCarbs, keyPath: \.carbsG, field: .carbs)
                    macroRow(title: "Fat", color: Design.Color.macroFat, keyPath: \.fatG, field: .fat)
                }
            }

            SettingsGroup {
                editableRow(title: "Name", unit: nil) {
                    TextField(
                        "",
                        text: binding(\.displayName, fallback: ""),
                        prompt: Text("Optional").foregroundStyle(Design.Color.textTertiary)
                    )
                    .textContentType(.name)
                    .focused($focusedField, equals: .displayName)
                }

                heightReviewRow

                editableRow(title: "Weight", unit: reviewWeightUnit) {
                    numericField(\.weight, prompt: "—", field: .weight)
                }

                editableRow(title: "Goal weight", unit: reviewWeightUnit) {
                    numericField(\.targetWeight, prompt: "—", field: .targetWeight)
                }

                HStack {
                    Text("Activity")
                        .foregroundStyle(Design.Color.textPrimary)
                    Spacer()
                    SettingsMenuPicker(
                        label: "Activity",
                        selection: binding(\.activityLevel, fallback: .moderate),
                        options: ProfileActivityLevel.allCases,
                        title: \.onboardingTitle
                    )
                }
                .frame(minHeight: SettingsStyle.rowHeight)
            }

            VStack(alignment: .leading, spacing: Design.Space.s) {
                errorView
                Button("Start over") {
                    startOver()
                }
                .font(Design.Typeface.text(.subheadline, weight: .medium))
                .foregroundStyle(Design.Color.textSecondary)
                .frame(minHeight: 44)
                .buttonStyle(.plain)
                .disabled(isApplying)
            }
        }
        .padding(.top, Design.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Calories: the one serif figure on the page, still editable.
    private var caloriesFigure: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            TextField("0", text: binding(\.caloriesKcal, fallback: ""))
                .font(Design.Typeface.figure(.largeTitle))
                .monospacedDigit()
                .foregroundStyle(Design.Color.textPrimary)
                .tint(Design.Color.pernambuco)
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: .calories)
                .fixedSize()
                .accessibilityLabel("Calories, kcal")
            Text("kcal a day")
                .font(Design.Typeface.text(.subheadline))
                .foregroundStyle(Design.Color.textTertiary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { focusedField = .calories }
    }

    private func macroRow(
        title: String,
        color: Color,
        keyPath: WritableKeyPath<OnboardingDraft, String>,
        field: Field
    ) -> some View {
        HStack(spacing: Design.Space.m) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(Design.Color.textPrimary)
            Spacer(minLength: 14)
            TextField("0", text: binding(keyPath, fallback: ""))
                .font(Design.Typeface.numeral(.body, weight: .regular))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Design.Color.textPrimary)
                .tint(Design.Color.pernambuco)
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: field)
                .frame(maxWidth: 96)
                .accessibilityLabel("\(title), grams")
            Text("g")
                .font(Design.Typeface.text(.footnote))
                .foregroundStyle(Design.Color.textTertiary)
                .frame(minWidth: 28, alignment: .leading)
        }
        .frame(minHeight: SettingsStyle.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { focusedField = field }
    }

    private func editableRow<Content: View>(
        title: String,
        unit: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .foregroundStyle(Design.Color.textPrimary)
            Spacer(minLength: 14)
            content()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Design.Color.textPrimary)
                .tint(Design.Color.pernambuco)
            if let unit {
                Text(unit)
                    .font(Design.Typeface.text(.footnote))
                    .foregroundStyle(Design.Color.textTertiary)
                    .frame(minWidth: 28, alignment: .leading)
            }
        }
        .frame(minHeight: SettingsStyle.rowHeight)
    }

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
            .font(Design.Typeface.numeral(.body, weight: .regular))
            .monospacedDigit()
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
                .font(Design.Typeface.numeral(.body, weight: .regular))
                .monospacedDigit()
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: field)
                .frame(width: 42)
            Text(unit)
                .font(Design.Typeface.text(.footnote))
                .foregroundStyle(Design.Color.textTertiary)
        }
    }

    @ViewBuilder
    private var errorView: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                .font(Design.Typeface.text(.footnote))
                .foregroundStyle(Design.Color.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var bottomAction: some View {
        if proposalResult != nil {
            reviewAction
                .transition(.ink(reduceMotion: reduceMotion))
        } else {
            captureBar
                .transition(.ink(reduceMotion: reduceMotion))
        }
    }

    private var reviewAction: some View {
        Button {
            Task { await applyProposal() }
        } label: {
            HStack(spacing: 9) {
                if isApplying {
                    ProgressView().controlSize(.small).tint(Design.Color.onCream)
                }
                Text(isApplying ? "Saving…" : "Use these targets")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isApplying)
        .padding(.horizontal, Design.Space.xl)
        .padding(.top, Design.Space.l)
        .padding(.bottom, Design.Space.s)
        .background {
            LinearGradient(
                colors: [Design.Color.canvas.opacity(0), Design.Color.canvas],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.32)
            )
            .ignoresSafeArea()
        }
    }

    private var captureBar: some View {
        // The capture bar's shape: the first tap on the bottom-left mic
        // records, the second sends everything (typed words plus the
        // take) for targets.
        SheetCaptureBar(
            voice: voice,
            text: $context,
            placeholder: "Or type it",
            canSend: false,
            isSendEnabled: !isPreparing,
            isSending: isPreparing,
            sendLabel: "Create my targets",
            identifierPrefix: "onboarding",
            onWillRecord: {
                errorMessage = nil
                focusedField = nil
            },
            onSend: { Task { await prepareProposal() } },
            onTake: appendTake
        )
    }

    private func appendTake(_ take: VoiceTake) {
        let result = DictationMergePolicy.appending(
            take.text,
            to: context,
            limit: OnboardingCapturePolicy.maximumTextCharacters
        )
        if result.wasTruncated { errorMessage = VoiceCopy.reachedLengthLimit }
        guard result.record != nil else { return }
        context = result.note
        dictatedTakeCount += 1
        dictatedEngine = take.engine
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
    private func prepareProposal() async {
        focusedField = nil
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }

        // A recording still in flight is stopped and transcribed (or a
        // failed upload retried once) and lands in the description first;
        // a warm-up with nothing heard yet is simply dropped.
        let hadTake = voice.hasTakeInFlight
        if let take = await voice.finishPendingTake(finalizationTimeout: 1.5) {
            appendTake(take)
        } else if hadTake, voice.errorMessage != nil {
            // The bar shows the failure (retry or ✕ for a kept recording);
            // don't build targets without Luke's words.
            return
        }
        guard OnboardingCapturePolicy.canSubmit(text: context, isSubmitting: false) else {
            errorMessage = voice.notice == .didNotCatchThat
                ? VoiceCopy.didNotCatchThat
                : OnboardingService.ServiceError.invalidCapture.localizedDescription
            return
        }

        do {
            let result = try await service.createProposal(
                text: OnboardingCapturePolicy.proposalContext(
                    userText: context,
                    preserving: initialProfile
                ),
                speechEngine: dictatedTakeCount > 0 ? dictatedEngine : nil,
                timezone: TimeZone.autoupdatingCurrent.identifier,
                clientRequestID: clientRequestID
            )
            proposalResult = result
            draft = OnboardingDraft(
                proposal: result.proposal,
                profileUnits: initialProfile?.units
            )
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
        voice.cancel()
        proposalResult = nil
        draft = nil
        context = ""
        dictatedTakeCount = 0
        dictatedEngine = nil
        clientRequestID = UUID()
        errorMessage = nil
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
