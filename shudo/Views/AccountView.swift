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
            _cropSource = State(initialValue: sheet == "crop" ? ProfilePhotoCropSource(image: profilePhoto) : nil)
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
            VStack(alignment: .leading, spacing: Design.Space.section) {
                header
                if let error {
                    Text(error)
                        .font(Design.Typeface.text(.footnote))
                        .foregroundStyle(Design.Color.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
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
                    .font(Design.Typeface.text(.caption2))
                    .foregroundStyle(Design.Color.textTertiary)
                    .accessibilityIdentifier("Build identity")
            }
            .padding(.horizontal, Design.Space.xl)
            .padding(.top, Design.Space.s)
            .padding(.bottom, Design.Space.xxxl)
            .settlesOnAppear()
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .background(AppBackground())
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Settings")
                    .font(Self.barTitleFont)
                    .foregroundStyle(Design.Color.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .tint(Design.Color.textPrimary)
            }
            // Number pads have no return key.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedTarget = nil }
                    .tint(Design.Color.textPrimary)
            }
        }
        .animation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion), value: error)
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

    /// The serif title in a settings sheet's navigation bar.
    static let barTitleFont = Design.Typeface.display(.headline, weight: .medium)

    // MARK: Header

    /// You, quietly: a small portrait and your name, set left like a
    /// signature rather than centred like a profile page.
    private var header: some View {
        HStack(spacing: Design.Space.l) {
            Button {
                if profile.avatarPath == nil {
                    isShowingPhotoPicker = true
                } else {
                    isShowingPhotoOptions = true
                }
            } label: {
                avatar
            }
            .buttonStyle(.plain)
            .disabled(isSavingProfilePhoto)
            .accessibilityLabel(profile.avatarPath == nil ? "Add profile photo" : "Change profile photo")

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(Design.Typeface.display(.title2))
                    .foregroundStyle(Design.Color.textPrimary)
                    .lineLimit(1)
                if let email, email != displayName {
                    Text(email)
                        .font(Design.Typeface.text(.subheadline))
                        .foregroundStyle(Design.Color.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Design.Space.m)
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
                    .font(Design.Typeface.text(.title2))
                    .foregroundStyle(Design.Color.textTertiary)
            }
            if isLoadingProfilePhoto || isSavingProfilePhoto {
                Circle().fill(Design.Color.canvas.opacity(0.55))
                ProgressView().controlSize(.small).tint(Design.Color.textPrimary)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Design.Color.hairline, lineWidth: Design.Stroke.hairline))
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

    /// A ledger: label, figure, unit. The macro colours survive only as a
    /// small mark, so the numbers carry the page.
    private var targetsGroup: some View {
        VStack(alignment: .leading, spacing: Design.Space.l) {
            SettingsGroup(label: "Daily targets") {
                targetRow("Calories", unit: "kcal", color: Design.Color.macroKcal, text: $targetDraft.calories, field: .calories)
                targetRow("Protein", unit: "g", color: Design.Color.macroProtein, text: $targetDraft.protein, field: .protein)
                targetRow("Carbs", unit: "g", color: Design.Color.macroCarbs, text: $targetDraft.carbs, field: .carbs)
                targetRow("Fat", unit: "g", color: Design.Color.macroFat, text: $targetDraft.fat, field: .fat)
            } accessory: {
                if showsSavedTargets {
                    Label("Saved", systemImage: "checkmark")
                        .font(Design.Typeface.text(.caption, weight: .semibold))
                        .foregroundStyle(Design.Color.textSecondary)
                        .transition(.opacity)
                }
            }

            if targetsEdited {
                Group {
                    if targetDraft.validatedTarget == nil {
                        Text("500–10,000 kcal, and at least 1 g of each macro.")
                            .font(Design.Typeface.text(.footnote))
                            .foregroundStyle(Design.Color.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Button(action: saveTargets) {
                            HStack(spacing: 8) {
                                if isSavingTargets {
                                    ProgressView().controlSize(.small).tint(Design.Color.onCream)
                                }
                                Text(isSavingTargets ? "Saving…" : "Save targets")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isSavingTargets)
                    }
                }
                .transition(.shoji(.top, reduceMotion: reduceMotion))
            }
        }
        .animation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion), value: targetsEdited)
        .animation(Design.Motion.calm(Design.Motion.snap, reduceMotion: reduceMotion), value: showsSavedTargets)
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
        HStack(spacing: Design.Space.m) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(label)
                .font(Design.Typeface.text(.body))
                .foregroundStyle(Design.Color.textPrimary)
            Spacer(minLength: 8)
            TextField("0", text: text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .font(Design.Typeface.numeral(.body, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(Design.Color.textPrimary)
                .tint(Design.Color.pernambuco)
                .frame(maxWidth: 96)
                .focused($focusedTarget, equals: field)
                .accessibilityLabel("\(label) target")
                .onChange(of: text.wrappedValue) { _, updated in
                    let filtered = updated.filter { $0.isNumber || $0 == "," }
                    if filtered != updated { text.wrappedValue = filtered }
                }
            Text(unit)
                .font(Design.Typeface.text(.footnote))
                .foregroundStyle(Design.Color.textTertiary)
                .fixedSize()
                .frame(minWidth: 28, alignment: .leading)
        }
        .frame(minHeight: SettingsStyle.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { focusedTarget = field }
    }

    // MARK: Account

    /// Leaving: crimson words, no boxes.
    private var accountGroup: some View {
        SettingsGroup {
            Button { isShowingSignOut = true } label: {
                accountActionLabel("Sign out")
            }
            .buttonStyle(.plain)

            Button { isShowingDeleteAccount = true } label: {
                accountActionLabel("Delete account")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Permanently deletes your meal log and account")
        }
    }

    private func accountActionLabel(_ title: String) -> some View {
        Text(title)
            .font(Design.Typeface.text(.body))
            .foregroundStyle(Design.Color.danger)
            .frame(maxWidth: .infinity, minHeight: SettingsStyle.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
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
