import SwiftUI
import UIKit
import PhotosUI

enum ProfilePhotoInputPolicy {
    static let maximumSourceBytes = 25_000_000
    static let maximumPixelDimension: CGFloat = 12_000
    static let maximumPixelCount: CGFloat = 50_000_000

    static func accepts(byteCount: Int, pixelWidth: CGFloat, pixelHeight: CGFloat) -> Bool {
        guard byteCount > 0, byteCount <= maximumSourceBytes,
              pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth >= 1, pixelHeight >= 1,
              pixelWidth <= maximumPixelDimension,
              pixelHeight <= maximumPixelDimension else { return false }
        return pixelWidth * pixelHeight <= maximumPixelCount
    }
}

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
    @State private var error: String?
    @State private var savedMessage: String?
    @State private var email = "-"
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var cropSource: ProfilePhotoCropSource?
    @State private var profilePhoto: UIImage?
    @State private var isLoadingProfilePhoto = false
    @State private var isSavingProfilePhoto = false
    @State private var isShowingRemovePhotoConfirmation = false
    @AppStorage(AppTheme.storageKey) private var selectedTheme = AppTheme.defaultTheme.rawValue

    private let service: SupabaseService
    private let weeklySummaryProvider: any WeeklySummaryProviding
    private let accountDeletionService: any AccountDeletionServing
    private let onProfileUpdated: (Profile) -> Void
    private let loadsRemotely: Bool

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
        loadsRemotely = true
    }

    #if DEBUG
    init(
        previewProfile: Profile,
        profilePhoto: UIImage,
        dailyTotals: [DailyNutritionTotal]
    ) {
        _profile = State(initialValue: previewProfile)
        _targetDraft = State(initialValue: MacroTargetDraft(target: previewProfile.dailyMacroTarget))
        _dailyTotals = State(initialValue: dailyTotals)
        _profilePhoto = State(initialValue: profilePhoto)
        _isLoading = State(initialValue: false)
        _isLoadingWeeklySummary = State(initialValue: false)
        service = SupabaseService()
        weeklySummaryProvider = EmptyWeeklySummaryProvider()
        accountDeletionService = PolishPreviewAccountDeletionService()
        onProfileUpdated = { _ in }
        loadsRemotely = false
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                profileHeader
                themeSelector
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
        .task {
            guard loadsRemotely else { return }
            await load()
        }
        .sheet(isPresented: $isShowingProfileEditor) {
            ProfileSettingsEditorView(profile: profile, service: service) { updated in
                profile = updated
                targetDraft = MacroTargetDraft(target: updated.dailyMacroTarget)
                onProfileUpdated(updated)
            }
        }
        .sheet(item: $cropSource) { source in
            ProfilePhotoCropView(image: source.image) { croppedImage in
                cropSource = nil
                saveProfilePhoto(croppedImage)
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
        .confirmationDialog(
            "Remove profile photo?",
            isPresented: $isShowingRemovePhotoConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove photo", role: .destructive) { removeProfilePhoto() }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: profile.avatarPath) {
            guard loadsRemotely else { return }
            await loadProfilePhoto()
        }
    }

    private var profileHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                profileIdentity
                Spacer(minLength: 8)
                profilePhotoActions
            }
            VStack(alignment: .leading, spacing: 12) {
                profileIdentity
                profilePhotoActions
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.top, 6)
    }

    private var profileIdentity: some View {
        HStack(spacing: 14) {
            profilePhotoView
            VStack(alignment: .leading, spacing: 4) {
                if let displayName = profile.displayName, !displayName.isEmpty {
                    Text(displayName)
                        .font(.headline)
                        .foregroundStyle(Design.Color.ink)
                        .lineLimit(1)
                }
                Text(email)
                    .font(profile.displayName?.isEmpty == false ? .caption : .headline)
                    .foregroundStyle(profile.displayName?.isEmpty == false ? Design.Color.muted : Design.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var profilePhotoActions: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Text(profile.avatarPath == nil ? "Add photo" : "Replace photo")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Design.Color.accentPrimary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(isSavingProfilePhoto)
            .onChange(of: selectedPhotoItem) { _, item in
                prepareSelectedPhoto(item)
            }

            if profile.avatarPath != nil {
                Button("Remove", role: .destructive) {
                    isShowingRemovePhotoConfirmation = true
                }
                .font(.caption)
                .foregroundStyle(Design.Color.danger)
                .disabled(isSavingProfilePhoto)
            }
        }
    }

    private var profilePhotoView: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Design.Color.elevated,
                            Design.Color.accentPrimary.opacity(0.12)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            if let profilePhoto {
                Image(uiImage: profilePhoto)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.title2)
                    .foregroundStyle(Design.Color.accentPrimary)
            }
            if isLoadingProfilePhoto || isSavingProfilePhoto {
                Circle().fill(.black.opacity(0.45))
                ProgressView().tint(.white)
            }
        }
        .frame(width: 68, height: 68)
        .clipShape(Circle())
        .overlay(Circle().stroke(Design.Color.rule, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(profile.avatarPath == nil ? "No profile photo" : "Profile photo")
    }

    private var themeSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel("APPEARANCE")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 96), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(AppTheme.allCases) { theme in
                    let isSelected = selectedTheme == theme.rawValue
                    Button {
                        selectedTheme = theme.rawValue
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        VStack(alignment: .leading, spacing: 11) {
                            LinearGradient(
                                colors: [
                                    theme.palette.accentPrimary,
                                    theme.palette.accentSecondary
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(height: 5)
                            .clipShape(Capsule())

                            HStack(spacing: 6) {
                                Text(theme.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(theme.palette.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(theme.palette.accentPrimary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(
                            theme.palette.elevated,
                            in: RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: Design.Radius.m, style: .continuous)
                                .stroke(
                                    isSelected ? theme.palette.accentPrimary : Design.Color.rule,
                                    lineWidth: 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(theme.title) theme")
                    .accessibilityValue(isSelected ? "Selected" : theme.accessibilityDescription)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
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
                HairlineRule()
                infoRow(icon: "ruler", label: "Units", value: profile.units.capitalized)
                if let height = profile.heightCM {
                    HairlineRule()
                    infoRow(
                        icon: "arrow.up.and.down",
                        label: "Height",
                        value: heightText(height, units: profile.units)
                    )
                }
                if let weight = profile.weightKG {
                    HairlineRule()
                    infoRow(
                        icon: "scalemass",
                        label: "Weight",
                        value: weightText(weight, units: profile.units)
                    )
                }
                if let targetWeight = profile.targetWeightKG {
                    HairlineRule()
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
                HairlineRule().padding(.leading, 42)
                targetRow(
                    label: "Protein",
                    unit: "g",
                    color: Design.Color.ringProtein,
                    text: $targetDraft.protein,
                    field: .protein
                )
                HairlineRule().padding(.leading, 42)
                targetRow(
                    label: "Carbs",
                    unit: "g",
                    color: Design.Color.ringCarb,
                    text: $targetDraft.carbs,
                    field: .carbs
                )
                HairlineRule().padding(.leading, 42)
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
            // Totals need the fresh profile's timezone; the remaining loads are
            // independent, so run them together instead of as four round trips.
            async let totalsRequest = service.fetchDailyNutritionTotals(timezone: profile.timezone)
            async let historyRequest = service.fetchDailyMacroTargetHistory()
            async let emailRequest = try? loadEmail()
            async let weeklyRequest: Void = loadWeeklySummary()
            dailyTotals = try await totalsRequest
            targetHistory = try await historyRequest
            if let loadedEmail = await emailRequest {
                email = loadedEmail
            }
            await weeklyRequest
        } catch {
            self.error = error.localizedDescription
            if let loadedEmail = try? await loadEmail() {
                email = loadedEmail
            }
            await loadWeeklySummary()
        }
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

    private func prepareSelectedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      !data.isEmpty,
                      data.count <= ProfilePhotoInputPolicy.maximumSourceBytes,
                      let image = UIImage(data: data),
                      ProfilePhotoInputPolicy.accepts(
                        byteCount: data.count,
                        pixelWidth: image.size.width * image.scale,
                        pixelHeight: image.size.height * image.scale
                      ) else {
                    throw SupabaseService.ServiceError.parseError(
                        message: "Choose a valid photo under 25 MB and 50 megapixels"
                    )
                }
                await MainActor.run {
                    selectedPhotoItem = nil
                    cropSource = ProfilePhotoCropSource(image: image.normalizedForDisplay())
                }
            } catch {
                await MainActor.run {
                    selectedPhotoItem = nil
                    self.error = "That photo couldn’t be opened. Try another image."
                }
            }
        }
    }

    private func saveProfilePhoto(_ image: UIImage) {
        guard !isSavingProfilePhoto else { return }
        guard let jpegData = image.profilePhotoJPEG() else {
            error = "That photo couldn’t be prepared. Try another image."
            return
        }
        isSavingProfilePhoto = true
        error = nil
        let oldPath = profile.avatarPath
        Task {
            do {
                let updated = try await service.uploadProfilePhoto(jpegData, replacing: oldPath)
                await MainActor.run {
                    profile = updated
                    profilePhoto = image
                    if let path = updated.avatarPath {
                        ProfilePhotoCache.save(jpegData, userId: updated.userId, path: path)
                    }
                    ProfileCache.save(updated)
                    onProfileUpdated(updated)
                    isSavingProfilePhoto = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                await MainActor.run {
                    isSavingProfilePhoto = false
                    self.error = error.localizedDescription
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private func removeProfilePhoto() {
        guard let path = profile.avatarPath, !isSavingProfilePhoto else { return }
        isSavingProfilePhoto = true
        error = nil
        Task {
            do {
                let updated = try await service.removeProfilePhoto(path: path)
                await MainActor.run {
                    profile = updated
                    profilePhoto = nil
                    ProfilePhotoCache.clear(userId: updated.userId)
                    ProfileCache.save(updated)
                    onProfileUpdated(updated)
                    isSavingProfilePhoto = false
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch {
                await MainActor.run {
                    isSavingProfilePhoto = false
                    self.error = error.localizedDescription
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private func loadProfilePhoto() async {
        guard let path = profile.avatarPath else {
            profilePhoto = nil
            ProfilePhotoCache.clear(userId: profile.userId)
            return
        }
        if let cached = ProfilePhotoCache.load(userId: profile.userId, expectedPath: path),
           let image = UIImage(data: cached) {
            profilePhoto = image
            return
        }
        isLoadingProfilePhoto = true
        defer { isLoadingProfilePhoto = false }
        do {
            let data = try await service.fetchProfilePhoto(path: path)
            guard let image = UIImage(data: data) else { return }
            profilePhoto = image
            ProfilePhotoCache.save(data, userId: profile.userId, path: path)
        } catch {
            // Keep Settings usable on a transient image failure; a later visit retries.
        }
    }
}

private struct ProfilePhotoCropSource: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct ProfilePhotoCropView: View {
    @Environment(\.dismiss) private var dismiss
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero

    let image: UIImage
    let onUse: (UIImage) -> Void

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let side = min(geometry.size.width - 40, geometry.size.height - 130)
                VStack(spacing: 22) {
                    Spacer(minLength: 8)
                    cropCanvas(side: side)
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: "minus.magnifyingglass")
                            Slider(value: $zoom, in: 1...4)
                                .accessibilityLabel("Photo zoom")
                            Image(systemName: "plus.magnifyingglass")
                        }
                        .foregroundStyle(Design.Color.muted)
                        Text("Drag and zoom to frame your photo")
                            .font(.caption)
                            .foregroundStyle(Design.Color.muted)
                    }
                    .padding(.horizontal, 28)
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: zoom) { _, updated in
                    offset = clampedOffset(offset, side: side, zoom: updated)
                }
                .safeAreaInset(edge: .bottom) {
                    Button("Use photo") {
                        onUse(renderedCrop(side: side))
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Design.Color.paper.opacity(0.94))
                }
            }
            .background(Design.Color.paper)
            .navigationTitle("Crop photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func cropCanvas(side: CGFloat) -> some View {
        let liveZoom = min(max(zoom * magnification, 1), 4)
        let liveOffset = clampedOffset(
            CGSize(
                width: offset.width + dragTranslation.width,
                height: offset.height + dragTranslation.height
            ),
            side: side,
            zoom: liveZoom
        )
        return Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .scaleEffect(liveZoom)
            .offset(liveOffset)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.hero, style: .continuous))
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.86), lineWidth: 1.5)
                    .padding(10)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.hero, style: .continuous)
                    .stroke(Design.Color.rule, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($dragTranslation) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        offset = clampedOffset(
                            CGSize(
                                width: offset.width + value.translation.width,
                                height: offset.height + value.translation.height
                            ),
                            side: side,
                            zoom: zoom
                        )
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($magnification) { value, state, _ in state = value.magnification }
                    .onEnded { value in
                        zoom = min(max(zoom * value.magnification, 1), 4)
                        offset = clampedOffset(offset, side: side, zoom: zoom)
                    }
            )
            .accessibilityLabel("Profile photo crop area")
            .accessibilityHint("Drag to reposition the photo, or use the zoom slider")
    }

    private func clampedOffset(_ proposed: CGSize, side: CGFloat, zoom: CGFloat) -> CGSize {
        let imageAspect = image.size.width / max(image.size.height, 1)
        let baseWidth = imageAspect >= 1 ? side * imageAspect : side
        let baseHeight = imageAspect >= 1 ? side : side / max(imageAspect, 0.001)
        let maximumX = max(0, (baseWidth * zoom - side) / 2)
        let maximumY = max(0, (baseHeight * zoom - side) / 2)
        return CGSize(
            width: min(max(proposed.width, -maximumX), maximumX),
            height: min(max(proposed.height, -maximumY), maximumY)
        )
    }

    private func renderedCrop(side: CGFloat) -> UIImage {
        let outputSide: CGFloat = 512
        let imageAspect = image.size.width / max(image.size.height, 1)
        let baseWidth = imageAspect >= 1 ? outputSide * imageAspect : outputSide
        let baseHeight = imageAspect >= 1 ? outputSide : outputSide / max(imageAspect, 0.001)
        let outputOffset = CGSize(
            width: offset.width / max(side, 1) * outputSide,
            height: offset.height / max(side, 1) * outputSide
        )
        return UIGraphicsImageRenderer(size: CGSize(width: outputSide, height: outputSide)).image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: CGSize(width: outputSide, height: outputSide)))
            image.draw(in: CGRect(
                x: (outputSide - baseWidth * zoom) / 2 + outputOffset.width,
                y: (outputSide - baseHeight * zoom) / 2 + outputOffset.height,
                width: baseWidth * zoom,
                height: baseHeight * zoom
            ))
        }
    }
}

private extension UIImage {
    func normalizedForDisplay() -> UIImage {
        guard imageOrientation != .up else { return self }
        return UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func profilePhotoJPEG() -> Data? {
        let maxBytes = 2_000_000
        for quality in [0.86, 0.74, 0.62, 0.50] {
            if let data = jpegData(compressionQuality: quality), data.count <= maxBytes {
                return data
            }
        }
        return nil
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
