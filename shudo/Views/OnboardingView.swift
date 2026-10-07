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
        .onChange(of: context) { _, value in
            guard value.count > OnboardingCapturePolicy.maximumTextCharacters else { return }
            context = OnboardingCapturePolicy.normalizedText(value)
        }
        .onDisappear {
            voice.cancel()
        }
    }

    private var captureContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            CoachAvatar(size: 52, isThinking: isPreparing)

            VStack(alignment: .leading, spacing: 10) {
                Text(isPreparing ? "Working out your numbers…" : "Tell me about you")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Design.Color.textPrimary)
                    .contentTransition(.opacity)
                    .fixedSize(horizontal: false, vertical: true)

                if !isPreparing {
                    Text("Height, weight, how active you are, and what you’re after. Tap the mic and talk.")
                        .font(.title3)
                        .foregroundStyle(Design.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            errorView
        }
        .animation(Design.Motion.snap, value: isPreparing)
    }

    private var voice: VoiceTranscriber { voiceHolder.value }

    private func reviewContent(_ result: OnboardingProposalResult) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Your targets")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Design.Color.textPrimary)

                Text(result.proposal.summary)
                    .font(.body)
                    .foregroundStyle(Design.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 12
            ) {
                macroField(title: "Calories", unit: "kcal", keyPath: \.caloriesKcal, field: .calories)
                macroField(title: "Protein", unit: "g", keyPath: \.proteinG, field: .protein)
                macroField(title: "Carbs", unit: "g", keyPath: \.carbsG, field: .carbs)
                macroField(title: "Fat", unit: "g", keyPath: \.fatG, field: .fat)
            }

            Picker("Goal", selection: goalSelection) {
                ForEach(NutritionGoalType.allCases, id: \.self) { goal in
                    Text(goal.onboardingTitle).tag(goal)
                }
            }
            .pickerStyle(.segmented)

            sectionCard {
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

                editableRow(title: "Goal weight", unit: reviewWeightUnit) {
                    numericField(\.targetWeight, prompt: "—", field: .targetWeight)
                }

                rowDivider

                HStack {
                    Text("Activity")
                        .foregroundStyle(Design.Color.textPrimary)
                    Spacer()
                    Picker("Activity", selection: binding(\.activityLevel, fallback: .moderate)) {
                        ForEach(ProfileActivityLevel.allCases, id: \.self) { activity in
                            Text(activity.onboardingTitle).tag(activity)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(Design.Color.textSecondary)
                }
                .frame(minHeight: 48)
            }

            Button("Start over") {
                startOver()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Design.Color.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .buttonStyle(.plain)
            .disabled(isApplying)

            errorView
        }
    }

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(
                Design.Color.surface1,
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
                .foregroundStyle(Design.Color.textPrimary)
            Spacer(minLength: 14)
            content()
                .multilineTextAlignment(.trailing)
                .foregroundStyle(Design.Color.textPrimary)
            if let unit {
                Text(unit)
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
            }
        }
        .frame(minHeight: 48)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Design.Color.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                TextField("0", text: binding(keyPath, fallback: ""))
                    .font(Design.Typeface.numeral(field == .calories ? .title : .title2))
                    .monospacedDigit()
                    .foregroundStyle(Design.Color.textPrimary)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: field)
                    .accessibilityLabel("\(title), \(unit)")
                Text(unit)
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Design.Color.surface1,
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
                        ProgressView().tint(Design.Color.onEmber)
                    }
                    Text(isApplying ? "Saving…" : "Use these targets")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isApplying)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        } else {
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
