import SwiftUI

struct RootView: View {
    @ObservedObject private var session = AuthSessionManager.shared
    @State private var profile: Profile?
    @State private var isLoadingProfile = false
    @State private var profileLoadError: String?

    var body: some View {
        Group {
            if session.session == nil {
                AuthView()
            } else if isLoadingProfile {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let p = profile {
                if needsOnboarding(p) {
                    OnboardingFlowView(profile: p) {
                        reloadProfile()
                    }
                } else {
                    TodayView(profile: p)
                }
            } else {
                VStack(spacing: 12) {
                    if let err = profileLoadError {
                        Text(err)
                            .foregroundStyle(.red)
                    } else {
                        Text("Loading…")
                            .foregroundStyle(Design.Color.muted)
                    }
                    HStack(spacing: 12) {
                        Button("Try Again") { reloadProfile() }
                            .buttonStyle(.bordered)
                        Button("Sign Out") { AuthSessionManager.shared.signOut() }
                            .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if session.session != nil {
                reloadProfile()
            }
        }
        .onChange(of: session.session) { newVal in
            if newVal != nil {
                reloadProfile()
            } else {
                profile = nil
                profileLoadError = nil
            }
        }
    }

    // MARK: - Gating

    private func needsOnboarding(_ p: Profile) -> Bool {
        let invalidNumbers = (p.heightCM ?? 0) <= 0 || (p.weightKG ?? 0) <= 0 || (p.targetWeightKG ?? 0) <= 0
        let validActivities = ["sedentary","light","moderate","active","extra_active"]
        let invalidActivity = !(p.activityLevel.flatMap { validActivities.contains($0) } ?? false)
        let cutoffEmpty = (p.cutoffTimeLocal?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return invalidNumbers || invalidActivity || cutoffEmpty
    }

    private func reloadProfile() {
        isLoadingProfile = true
        profileLoadError = nil
        Task {
            defer { isLoadingProfile = false }
            do {
                let p = try await SupabaseService().ensureProfileDefaults()
                await MainActor.run { self.profile = p }
            } catch {
                // If auth is invalid (deleted user, invalid JWT), sign out
                if let fe = error as? SupabaseAuthService.FriendlyAuthError, fe.httpStatus == 401 || fe.httpStatus == 403 {
                    await MainActor.run { AuthSessionManager.shared.signOut() }
                    return
                }
                let ns = error as NSError
                if ns.domain == "Auth" || ns.code == -1 {
                    await MainActor.run { AuthSessionManager.shared.signOut() }
                    return
                }
                await MainActor.run {
                    self.profile = nil
                    self.profileLoadError = "Failed to load your profile. Please try again."
                }
            }
        }
    }
}


