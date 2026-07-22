import SwiftUI
import UIKit

struct AccountView: View {
    private enum TargetField: Hashable { case calories, protein, carbs, fat }

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedTarget: TargetField?
    @State private var profile: Profile
    @State private var targetDraft: MacroTargetDraft
    @State private var dailyTotals: [DailyNutritionTotal] = []
    @State private var targetHistory: [DailyMacroTargetSnapshot] = []
    @State private var weeklySummary: WeeklyInsightSummary?
    @State private var weeklySummaryError: String?
    @State private var isLoading = true
    @State private var isLoadingWeeklySummary = true
    @State private var isSavingTargets = false
    @State private var isShowingProfileEditor = false
    @State private var isShowingTargetRecalculation = false
    @State private var isShowingDeleteAccount = false
    @State private var isSendingPasswordReset = false
    @State private var accountMessage: String?
    @State private var error: String?
    @State private var savedMessage: String?
    @State private var email = "-"

    private let service: SupabaseService
    private let weeklySummaryProvider: any WeeklySummaryProviding
    private let accountDeletionService: any AccountDeletionServing
    private let onProfileUpdated: (Profile) -> Void

    init(
        initialProfile: Profile,
        service: SupabaseService = SupabaseService(),
        weeklySummaryProvider: (any WeeklySummaryProviding)? = nil,
        accountDeletionService: (any AccountDeletionServing)? = nil,
        onProfileUpdated: @escaping (Profile) -> Void = { _ in }
    ) {
        _profile = State(initialValue: initialProfile)
        _targetDraft = State(initialValue: MacroTargetDraft(target: initialProfile.dailyMacroTarget))
        self.service = service
        self.weeklySummaryProvider = weeklySummaryProvider ?? service
        self.accountDeletionService = accountDeletionService ?? APIService(
            supabaseUrl: AppConfig.supabaseURL,
            supabaseAnonKey: AppConfig.supabaseAnonKey,
            sessionJWTProvider: { try await AuthSessionManager.shared.getAccessToken() }
        )
        self.onProfileUpdated = onProfileUpdated
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                profileHeader
                profileDetails
                targetEditor
                AdherenceHeatmapView(
                    totals: dailyTotals,
                    target: profile.dailyMacroTarget,
                    targetHistory: targetHistory,
                    timezone: profile.timezone
                )
                NutrientTrendsView(
                    totals: dailyTotals,
                    target: profile.dailyMacroTarget,
                    targetHistory: targetHistory,
                    timezone: profile.timezone
                )
                WeeklyInsightsView(
                    summary: weeklySummary,
                    isLoading: isLoadingWeeklySummary,
                    errorMessage: weeklySummaryError,
                    onRetry: { Task { await loadWeeklySummary() } }
                )
                accountActions
                supportLinks

                if isLoading {
                    ProgressView()
                        .tint(Design.Color.accentPrimary)
                        .padding(.vertical, 8)
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Design.Color.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            Design.Color.danger.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: Design.Radius.m)
                        )
                }

                Button {
                    AuthSessionManager.shared.signOut()
                    dismiss()
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            Design.Color.danger.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: Design.Radius.m)
                        )
                }
                .buttonStyle(.plain)
                .padding(.top, 12)

                Button(role: .destructive) {
                    isShowingDeleteAccount = true
                } label: {
                    Label("Delete account", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Permanently deletes your meal log and account")
            }
            .padding(20)
            .padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .background(Design.Color.paper)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .foregroundStyle(Design.Color.accentPrimary)
            }
        }
        .task { await load() }
        .sheet(isPresented: $isShowingProfileEditor) {
            ProfileSettingsEditorView(profile: profile, service: service) { updated in
                profile = updated
                targetDraft = MacroTargetDraft(target: updated.dailyMacroTarget)
                onProfileUpdated(updated)
            }
        }
        .fullScreenCover(isPresented: $isShowingTargetRecalculation) {
            NavigationStack {
                OnboardingView(initialProfile: profile) { updated in
                    profile = updated
                    targetDraft = MacroTargetDraft(target: updated.dailyMacroTarget)
                    ProfileCache.save(updated)
                    onProfileUpdated(updated)
                    isShowingTargetRecalculation = false
                    Task {
                        if let refreshedHistory = try? await service.fetchDailyMacroTargetHistory() {
                            targetHistory = refreshedHistory
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isShowingTargetRecalculation = false }
                            .foregroundStyle(Design.Color.accentPrimary)
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingDeleteAccount) {
            AccountDeletionSheet {
                try await accountDeletionService.deleteAccount(
                    confirmation: AccountDeletionPolicy.confirmation
                )
                await MainActor.run {
                    AuthSessionManager.shared.signOut()
                    isShowingDeleteAccount = false
                    dismiss()
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var profileHeader: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Design.Color.accentPrimary.opacity(0.22),
                            Design.Color.accentPrimary.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 58, height: 58)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.title3)
                        .foregroundStyle(Design.Color.accentPrimary)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(email)
                    .font(.headline)
                    .foregroundStyle(Design.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Voice-first nutrition log")
                    .font(.caption)
                    .foregroundStyle(Design.Color.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private var profileDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("PROFILE")
                Spacer()
                Button("Edit") { isShowingProfileEditor = true }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Design.Color.accentPrimary)
                    .buttonStyle(.plain)
                    .accessibilityHint("Edit goals, body measurements, and activity")
            }
            VStack(spacing: 0) {
                infoRow(icon: "globe", label: "Timezone", value: profile.timezone)
                Divider().background(Design.Color.rule)
                infoRow(icon: "ruler", label: "Units", value: profile.units.capitalized)
                if let height = profile.heightCM {
                    Divider().background(Design.Color.rule)
                    infoRow(
                        icon: "arrow.up.and.down",
                        label: "Height",
                        value: heightText(height, units: profile.units)
                    )
                }
                if let weight = profile.weightKG {
                    Divider().background(Design.Color.rule)
                    infoRow(
                        icon: "scalemass",
                        label: "Weight",
                        value: weightText(weight, units: profile.units)
                    )
                }
                if let targetWeight = profile.targetWeightKG {
                    Divider().background(Design.Color.rule)
                    infoRow(
                        icon: "target",
                        label: "Target weight",
                        value: weightText(targetWeight, units: profile.units)
                    )
                }
            }
            .background(
                Design.Color.elevated,
                in: RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous)
            )
        }
    }

    private var targetEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionLabel("DAILY TARGETS")
                Spacer()
                Button("Recalculate") { isShowingTargetRecalculation = true }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Design.Color.accentPrimary)
                    .buttonStyle(.plain)
                    .accessibilityHint("Use voice or text to propose updated daily targets")
                if let savedMessage {
                    Text(savedMessage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Design.Color.success)
                }
            }

            VStack(spacing: 0) {
                targetRow(
                    label: "Calories",
                    unit: "kcal",
                    color: Design.Color.warning,
                    text: $targetDraft.calories,
                    field: .calories
                )
                Divider().background(Design.Color.rule).padding(.leading, 42)
                targetRow(
                    label: "Protein",
                    unit: "g",
                    color: Design.Color.ringProtein,
                    text: $targetDraft.protein,
                    field: .protein
                )
                Divider().background(Design.Color.rule).padding(.leading, 42)
                targetRow(
                    label: "Carbs",
                    unit: "g",
                    color: Design.Color.ringCarb,
                    text: $targetDraft.carbs,
                    field: .carbs
                )
                Divider().background(Design.Color.rule).padding(.leading, 42)
                targetRow(
                    label: "Fat",
                    unit: "g",
                    color: Design.Color.ringFat,
                    text: $targetDraft.fat,
                    field: .fat
                )
            }
            .background(
                Design.Color.elevated,
                in: RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous)
            )

            if targetDraft.validatedTarget == nil {
                Text("Use realistic positive targets: 500–10,000 kcal and at least 1 g per macro.")
                    .font(.caption)
                    .foregroundStyle(Design.Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button { saveTargets() } label: {
                HStack(spacing: 8) {
                    if isSavingTargets { ProgressView().tint(.white) }
                    Text(isSavingTargets ? "Saving…" : "Save targets")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    LinearGradient(
                        colors: canSaveTargets
                            ? [Design.Color.ctaPrimary, Design.Color.ctaSecondary]
                            : [Design.Color.subtle, Design.Color.subtle],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .disabled(!canSaveTargets)
        }
    }

    private var supportLinks: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("ABOUT")
            VStack(spacing: 0) {
                externalLinkRow(
                    title: "Terms",
                    systemImage: "doc.text",
                    url: "https://shudo.yng.sh/terms"
                )
                Divider().background(Design.Color.rule).padding(.leading, 42)
                externalLinkRow(
                    title: "Support",
                    systemImage: "questionmark.circle",
                    url: "https://shudo.yng.sh/support"
                )
            }
            .background(
                Design.Color.elevated,
                in: RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous)
            )
        }
    }

    private var accountActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("ACCOUNT")
            VStack(spacing: 0) {
                Button { sendPasswordReset() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill")
                            .frame(width: 20)
                            .foregroundStyle(Design.Color.accentPrimary)
                        Text(isSendingPasswordReset ? "Sending…" : "Send password reset")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Design.Color.ink)
                        Spacer(minLength: 12)
                        if isSendingPasswordReset {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSendingPasswordReset || email == "-")
            }
            .background(
                Design.Color.elevated,
                in: RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous)
            )

            if let accountMessage {
                Text(accountMessage)
                    .font(.caption)
                    .foregroundStyle(Design.Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func externalLinkRow(title: String, systemImage: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(Design.Color.accentPrimary)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Design.Color.ink)
                Spacer(minLength: 12)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Design.Color.muted)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sendPasswordReset() {
        guard !isSendingPasswordReset, email != "-" else { return }
        isSendingPasswordReset = true
        accountMessage = nil
        error = nil
        Task {
            do {
                try await SupabaseAuthService().requestPasswordRecovery(email: email)
                await MainActor.run {
                    isSendingPasswordReset = false
                    accountMessage = "Password reset link sent to \(email)."
                }
            } catch {
                await MainActor.run {
                    isSendingPasswordReset = false
                    self.error = "Couldn’t send a password reset link. Try again."
                }
            }
        }
    }

    private var canSaveTargets: Bool {
        guard !isSavingTargets, let target = targetDraft.validatedTarget else { return false }
        return target != profile.dailyMacroTarget
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Design.Color.muted)
            .tracking(0.5)
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(Design.Color.muted)
                    .frame(width: 20)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.muted)
            }
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Design.Color.ink)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func targetRow(
        label: String,
        unit: String,
        color: Color,
        text: Binding<String>,
        field: TargetField
    ) -> some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Design.Color.ink)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(.body.weight(.semibold))
                .foregroundStyle(Design.Color.ink)
                .monospacedDigit()
                .frame(width: 82)
                .focused($focusedTarget, equals: field)
                .onChange(of: text.wrappedValue) { _, updated in
                    let filtered = updated.filter { $0.isNumber || $0 == "," }
                    if filtered != updated { text.wrappedValue = filtered }
                    savedMessage = nil
                }
            Text(unit)
                .font(.caption)
                .foregroundStyle(Design.Color.muted)
                .frame(width: 30, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    private func heightText(_ centimeters: Double, units: String) -> String {
        guard units.lowercased() == "imperial" else {
            return "\(Int(centimeters.rounded())) cm"
        }
        let totalInches = Int((centimeters / 2.54).rounded())
        return "\(totalInches / 12)′ \(totalInches % 12)″"
    }

    private func weightText(_ kilograms: Double, units: String) -> String {
        let value = units.lowercased() == "imperial" ? kilograms * 2.20462 : kilograms
        let suffix = units.lowercased() == "imperial" ? "lb" : "kg"
        return "\(String(format: "%.1f", value)) \(suffix)"
    }

    private func saveTargets() {
        guard let target = targetDraft.validatedTarget, canSaveTargets else { return }
        focusedTarget = nil
        isSavingTargets = true
        error = nil
        savedMessage = nil
        Task {
            do {
                let updated = try await service.updateDailyMacroTarget(target)
                let updatedTargetHistory = try? await service.fetchDailyMacroTargetHistory()
                await MainActor.run {
                    profile = updated
                    if let updatedTargetHistory {
                        targetHistory = updatedTargetHistory
                    }
                    targetDraft = MacroTargetDraft(target: updated.dailyMacroTarget)
                    ProfileCache.save(updated)
                    onProfileUpdated(updated)
                    isSavingTargets = false
                    savedMessage = "Saved"
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                await MainActor.run {
                    isSavingTargets = false
                    self.error = error.localizedDescription
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        error = nil
        let userId = AuthSessionManager.shared.userId ?? profile.userId

        do {
            if let fresh = try await service.fetchProfile(userId: userId) {
                profile = fresh
                targetDraft = MacroTargetDraft(target: fresh.dailyMacroTarget)
                ProfileCache.save(fresh)
                onProfileUpdated(fresh)
            }
            dailyTotals = try await service.fetchDailyNutritionTotals(timezone: profile.timezone)
            targetHistory = try await service.fetchDailyMacroTargetHistory()
        } catch {
            self.error = error.localizedDescription
        }

        if let loadedEmail = try? await loadEmail() {
            email = loadedEmail
        }
        await loadWeeklySummary()
        isLoading = false
    }

    private func loadWeeklySummary() async {
        isLoadingWeeklySummary = true
        weeklySummaryError = nil
        do {
            weeklySummary = try await weeklySummaryProvider.fetchLatestWeeklySummary()
        } catch {
            weeklySummaryError = "Weekly insights couldn’t be loaded."
        }
        isLoadingWeeklySummary = false
    }

    private func loadEmail() async throws -> String {
        let token = try await AuthSessionManager.shared.getAccessToken()
        var request = URLRequest(url: AppConfig.supabaseURL.appendingPathComponent("/auth/v1/user"))
        request.httpMethod = "GET"
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = object["email"] as? String else { throw URLError(.cannotParseResponse) }
        return email
    }
}

private struct AccountDeletionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?

    let onDelete: () async throws -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: "trash.slash.fill")
                        .font(.title2)
                        .foregroundStyle(Design.Color.danger)
                        .frame(width: 48, height: 48)
                        .background(
                            Design.Color.danger.opacity(0.1),
                            in: Circle()
                        )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Permanently delete your account?")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Design.Color.ink)
                        Text("This permanently removes your meals, photos, profile, and sign-in. It cannot be undone.")
                            .font(.subheadline)
                            .foregroundStyle(Design.Color.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Type DELETE to confirm")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Design.Color.muted)
                        TextField("DELETE", text: $confirmation)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced().weight(.semibold))
                            .foregroundStyle(Design.Color.ink)
                            .padding(.horizontal, 16)
                            .frame(height: 50)
                            .background(
                                Design.Color.elevated,
                                in: RoundedRectangle(
                                    cornerRadius: Design.Radius.m,
                                    style: .continuous
                                )
                            )
                            .disabled(isDeleting)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Design.Color.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(role: .destructive) {
                        deleteAccount()
                    } label: {
                        HStack(spacing: 8) {
                            if isDeleting { ProgressView().tint(.white) }
                            Text(isDeleting ? "Deleting…" : "Delete account permanently")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            canDelete ? Design.Color.danger : Design.Color.subtle,
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canDelete)
                }
                .padding(20)
            }
            .background(Design.Color.paper)
            .navigationTitle("Delete account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isDeleting)
                }
            }
            .interactiveDismissDisabled(isDeleting)
        }
    }

    private var canDelete: Bool {
        !isDeleting && AccountDeletionPolicy.isConfirmed(confirmation)
    }

    private func deleteAccount() {
        guard canDelete else { return }
        isDeleting = true
        errorMessage = nil
        Task {
            do {
                try await onDelete()
            } catch {
                await MainActor.run {
                    isDeleting = false
                    errorMessage = error.localizedDescription
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }
}
