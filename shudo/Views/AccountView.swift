import PhotosUI
import SwiftUI
import UIKit

/// The settings sheet behind the avatar: who you are, what Shudo knows, how
/// the coach behaves, your daily targets, and the account itself.
struct AccountView: View {
    private enum TargetField: Hashable { case calories, protein, carbs, fat }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedTarget: TargetField?
    @State private var profile: Profile
    @State private var targetDraft: MacroTargetDraft
    @State private var isSavingTargets = false
    @State private var savedTargetsTick = 0
    @State private var showsSavedTargets = false
    @State private var isShowingProfileEditor = false
    @State private var isShowingDeleteAccount = false
    @State private var isShowingSignOut = false
    @State private var isShowingPhotoOptions = false
    @State private var isShowingPhotoPicker = false
    @State private var error: String?
    @State private var email: String?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var cropSource: ProfilePhotoCropSource?
    @State private var profilePhoto: UIImage?
    @State private var isLoadingProfilePhoto = false
    @State private var isSavingProfilePhoto = false

    /// What Settings needs from the app shell (coach settings, bio, sign-out
    /// cleanup).
    struct ShellHooks {
        var coachService: any CoachServing
        var loadsRemotely: Bool
        /// Opened from the iOS "Shudo Notification Settings" link.
        var scrollToCoach = false
        var onProfileUpdated: (Profile) -> Void
        var onSettingsChanged: (CoachSettings) -> Void
        var openBio: () -> Void
        var bioDestination: () -> AnyView
        /// Sign-out / account deletion: forget the coach queue and caches.
        var onSignOut: () -> Void
    }

    private let service: SupabaseService
    private let accountDeletionService: any AccountDeletionServing
    private let hooks: ShellHooks
    private let loadsRemotely: Bool

    init(
        initialProfile: Profile,
        service: SupabaseService = SupabaseService(),
        accountDeletionService: (any AccountDeletionServing)? = nil,
        hooks: ShellHooks
    ) {
        _profile = State(initialValue: initialProfile)
        _targetDraft = State(initialValue: MacroTargetDraft(target: initialProfile.dailyMacroTarget))
        self.service = service
        self.accountDeletionService =
            accountDeletionService
            ?? APIService(
                supabaseUrl: AppConfig.supabaseURL,
                supabaseAnonKey: AppConfig.supabaseAnonKey,
                sessionJWTProvider: { try await AuthSessionManager.shared.getAccessToken() }
            )
        self.hooks = hooks
        loadsRemotely = true
    }

    #if DEBUG
        init(
            previewProfile: Profile,
            profilePhoto: UIImage,
            hooks: ShellHooks
        ) {
            _profile = State(initialValue: previewProfile)
            _targetDraft = State(initialValue: MacroTargetDraft(target: previewProfile.dailyMacroTarget))
            _profilePhoto = State(initialValue: profilePhoto)
            _email = State(initialValue: "luke@example.com")
            // PolishPreview screenshots: `-shudoSettingsSheet editor|delete`.
            let arguments = ProcessInfo.processInfo.arguments
            let sheet = arguments.firstIndex(of: "-shudoSettingsSheet").flatMap {
                arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
            }
            _isShowingProfileEditor = State(initialValue: sheet == "editor")
            _isShowingDeleteAccount = State(initialValue: sheet == "delete")
            service = SupabaseService()
            accountDeletionService = PolishPreviewAccountDeletionService()
            self.hooks = hooks
            loadsRemotely = false
        }
    #endif

    var body: some View {
        ScrollViewReader { proxy in
            content
                .task {
                    guard let anchor = initialScrollAnchor else { return }
                    try? await Task.sleep(for: .milliseconds(350))
                    withAnimation(Design.Motion.gated(Design.Motion.settle, reduceMotion: reduceMotion)) {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                }
        }
    }

    private var initialScrollAnchor: String? {
        if hooks.scrollToCoach { return "settings.coach" }
        #if DEBUG
            // PolishPreview screenshots: `-shudoSettingsScroll settings.targets`.
            let arguments = ProcessInfo.processInfo.arguments
            if let flag = arguments.firstIndex(of: "-shudoSettingsScroll"), arguments.indices.contains(flag + 1) {
                return arguments[flag + 1]
            }
        #endif
        return nil
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Design.Color.danger)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                youGroup
                CoachSettingsSection(
                    service: hooks.coachService,
                    loadsRemotely: hooks.loadsRemotely,
                    onSettingsChanged: hooks.onSettingsChanged
                )
                .id("settings.coach")
                targetsGroup
                    .id("settings.targets")
                accountGroup
                    .id("settings.account")
                Text(BuildIdentity.current.displayText)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Design.Color.textTertiary)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("Build identity")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .background(Design.Color.canvas.ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            guard loadsRemotely else { return }
            await load()
        }
        .task(id: profile.avatarPath) {
            guard loadsRemotely else { return }
            await loadProfilePhoto()
        }
        .sheet(isPresented: $isShowingProfileEditor) {
            ProfileSettingsEditorView(profile: profile, service: service) { updated in
                apply(updated)
            }
        }
        .sheet(item: $cropSource) { source in
            ProfilePhotoCropView(image: source.image) { croppedImage in
                cropSource = nil
                saveProfilePhoto(croppedImage)
            }
        }
        .sheet(isPresented: $isShowingDeleteAccount) {
            AccountDeletionSheet {
                try await accountDeletionService.deleteAccount(
                    confirmation: AccountDeletionPolicy.confirmation
                )
                await MainActor.run {
                    isShowingDeleteAccount = false
                    signOut()
                }
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .photosPicker(isPresented: $isShowingPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { _, item in prepareSelectedPhoto(item) }
        .confirmationDialog("Profile photo", isPresented: $isShowingPhotoOptions) {
            Button("Choose a new photo") { isShowingPhotoPicker = true }
            Button("Remove photo", role: .destructive) { removeProfilePhoto() }
        }
        .confirmationDialog("Sign out of Shudo?", isPresented: $isShowingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { signOut() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            Button {
                if profile.avatarPath == nil {
                    isShowingPhotoPicker = true
                } else {
                    isShowingPhotoOptions = true
                }
            } label: {
                avatar
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Design.Color.textPrimary)
                            .frame(width: 26, height: 26)
                            .background(Design.Color.surface3, in: Circle())
                            .overlay(Circle().stroke(Design.Color.canvas, lineWidth: 3))
                            .accessibilityHidden(true)
                    }
            }
            .buttonStyle(.plain)
            .disabled(isSavingProfilePhoto)
            .accessibilityLabel(profile.avatarPath == nil ? "Add profile photo" : "Change profile photo")

            VStack(spacing: 3) {
                Text(displayName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Design.Color.textPrimary)
                    .lineLimit(1)
                if let email, email != displayName {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var displayName: String {
        if let name = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return email ?? "You"
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(Design.Color.surface2)
            if let profilePhoto {
                Image(uiImage: profilePhoto)
                    .resizable()
                    .scaledToFill()
                    // Fill overflow is hit-testable past the clip; keep it
                    // from shadowing the neighboring controls.
                    .allowsHitTesting(false)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Design.Color.textTertiary)
            }
            if isLoadingProfilePhoto || isSavingProfilePhoto {
                Circle().fill(.black.opacity(0.45))
                ProgressView().tint(.white)
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(Circle())
    }

    // MARK: You

    private var youGroup: some View {
        SettingsGroup {
            NavigationLink {
                hooks.bioDestination()
            } label: {
                SettingsValueLabel(title: "What Shudo knows about you")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.bio")

            Button {
                isShowingProfileEditor = true
            } label: {
                SettingsValueLabel(title: "Body & goal", value: goalSummary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.profile")
        }
    }

    /// "Bulk to 175 lb", "Cut to 165 lb", "Maintain".
    private var goalSummary: String {
        let verb: String
        switch profile.goalType {
        case .gain: verb = "Bulk"
        case .lose: verb = "Cut"
        case .maintain: return "Maintain"
        }
        guard let target = profile.targetWeightKG else { return verb }
        let value = BodyUnits.format(BodyUnits.display(target, units: profile.units))
        return "\(verb) to \(value) \(BodyUnits.label(profile.units))"
    }

    // MARK: Targets

    private var targetsGroup: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup(label: "Daily targets") {
                targetRow("Calories", unit: "kcal", color: Design.Color.macroKcal, text: $targetDraft.calories, field: .calories)
                targetRow("Protein", unit: "g", color: Design.Color.macroProtein, text: $targetDraft.protein, field: .protein)
                targetRow("Carbs", unit: "g", color: Design.Color.macroCarbs, text: $targetDraft.carbs, field: .carbs)
                targetRow("Fat", unit: "g", color: Design.Color.macroFat, text: $targetDraft.fat, field: .fat)
            } accessory: {
                if showsSavedTargets {
                    Label("Saved", systemImage: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Design.Color.positive)
                        .transition(.opacity)
                }
            }

            if targetsEdited {
                if targetDraft.validatedTarget == nil {
                    Text("500–10,000 kcal, and at least 1 g of each macro.")
                        .font(.footnote)
                        .foregroundStyle(Design.Color.warning)
                        .padding(.horizontal, 16)
                } else {
                    Button(action: saveTargets) {
                        HStack(spacing: 8) {
                            if isSavingTargets { ProgressView().tint(Design.Color.onEmber) }
                            Text(isSavingTargets ? "Saving…" : "Save targets")
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Design.Color.onEmber)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Design.Color.ember, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSavingTargets)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion), value: targetsEdited)
        .animation(Design.Motion.gated(Design.Motion.snap, reduceMotion: reduceMotion), value: showsSavedTargets)
        .sensoryFeedback(.success, trigger: savedTargetsTick)
    }

    private var targetsEdited: Bool {
        targetDraft != MacroTargetDraft(target: profile.dailyMacroTarget)
    }

    private func targetRow(
        _ label: String,
        unit: String,
        color: Color,
        text: Binding<String>,
        field: TargetField
    ) -> some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.body)
                .foregroundStyle(Design.Color.textPrimary)
            Spacer(minLength: 8)
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(Design.Typeface.numeral(.body))
                .monospacedDigit()
                .foregroundStyle(Design.Color.textPrimary)
                .frame(maxWidth: 96)
                .focused($focusedTarget, equals: field)
                .accessibilityLabel("\(label) target")
                .onChange(of: text.wrappedValue) { _, updated in
                    let filtered = updated.filter { $0.isNumber || $0 == "," }
                    if filtered != updated { text.wrappedValue = filtered }
                }
            Text(unit)
                .font(.footnote)
                .foregroundStyle(Design.Color.textTertiary)
                .fixedSize()
                .frame(minWidth: 30, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .onTapGesture { focusedTarget = field }
    }

    // MARK: Account

    private var accountGroup: some View {
        SettingsGroup {
            Button { isShowingSignOut = true } label: {
                SettingsRow(title: "Sign out") { EmptyView() }
            }
            .buttonStyle(.plain)

            Button { isShowingDeleteAccount = true } label: {
                Text("Delete account")
                    .font(.body)
                    .foregroundStyle(Design.Color.danger)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Permanently deletes your meal log and account")
        }
    }

    // MARK: Flows

    private func apply(_ updated: Profile) {
        profile = updated
        targetDraft = MacroTargetDraft(target: updated.dailyMacroTarget)
        ProfileCache.save(updated)
        hooks.onProfileUpdated(updated)
    }

    private func signOut() {
        hooks.onSignOut()
        AuthSessionManager.shared.signOut()
        dismiss()
    }

    private func saveTargets() {
        guard let target = targetDraft.validatedTarget, targetsEdited, !isSavingTargets else { return }
        focusedTarget = nil
        isSavingTargets = true
        error = nil
        Task { @MainActor in
            do {
                apply(try await service.updateDailyMacroTarget(target))
                savedTargetsTick += 1
                showsSavedTargets = true
                try? await Task.sleep(for: .seconds(2))
                showsSavedTargets = false
            } catch {
                self.error = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isSavingTargets = false
        }
    }

    private func load() async {
        let userId = AuthSessionManager.shared.userId ?? profile.userId
        do {
            if let fresh = try await service.fetchProfile(userId: userId), fresh != profile {
                let keepsDraft = targetsEdited
                let draft = targetDraft
                apply(fresh)
                if keepsDraft { targetDraft = draft }
            }
        } catch {
            // The cached profile is already on screen; a later visit retries.
        }
        email = try? await loadEmail()
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
            let email = object["email"] as? String
        else { throw URLError(.cannotParseResponse) }
        return email
    }

    // MARK: Photo

    private func prepareSelectedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        // Decoding and orientation-normalizing a library photo can be tens of
        // megapixels of CPU work; keep it off the main thread so the picker
        // dismissal stays smooth.
        Task.detached(priority: .userInitiated) {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                    !data.isEmpty,
                    data.count <= ProfilePhotoInputPolicy.maximumSourceBytes,
                    let image = UIImage(data: data),
                    ProfilePhotoInputPolicy.accepts(
                        byteCount: data.count,
                        pixelWidth: image.size.width * image.scale,
                        pixelHeight: image.size.height * image.scale
                    )
                else {
                    throw SupabaseService.ServiceError.parseError(
                        message: "Choose a valid photo under 25 MB and 50 megapixels"
                    )
                }
                let normalized = image.normalizedForDisplay()
                await MainActor.run {
                    selectedPhotoItem = nil
                    cropSource = ProfilePhotoCropSource(image: normalized)
                }
            } catch {
                await MainActor.run {
                    selectedPhotoItem = nil
                    self.error = "That photo couldn’t be opened. Try another one."
                }
            }
        }
    }

    private func saveProfilePhoto(_ image: UIImage) {
        guard !isSavingProfilePhoto else { return }
        isSavingProfilePhoto = true
        error = nil
        let oldPath = profile.avatarPath
        Task {
            do {
                // JPEG encoding (up to four quality passes) is too heavy for
                // the main thread right as the crop sheet dismisses.
                guard
                    let jpegData = await Task.detached(
                        priority: .userInitiated,
                        operation: { image.profilePhotoJPEG() }
                    ).value
                else {
                    await MainActor.run {
                        isSavingProfilePhoto = false
                        error = "That photo couldn’t be prepared. Try another one."
                    }
                    return
                }
                let updated = try await service.uploadProfilePhoto(jpegData, replacing: oldPath)
                await MainActor.run {
                    profilePhoto = image
                    if let path = updated.avatarPath {
                        ProfilePhotoCache.save(jpegData, userId: updated.userId, path: path)
                    }
                    apply(updated)
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
                    profilePhoto = nil
                    ProfilePhotoCache.clear(userId: updated.userId)
                    apply(updated)
                    isSavingProfilePhoto = false
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
            let image = UIImage(data: cached)
        {
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
