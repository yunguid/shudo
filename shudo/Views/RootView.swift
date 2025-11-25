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
                loadingView
            } else if let p = profile {
                if needsOnboarding(p) {
                    OnboardingFlowView(profile: p) {
                        reloadProfile()
                    }
                } else {
                    TodayView(profile: p)
                }
            } else {
                errorView
            }
        }
        .background(AppBackground())
        .preferredColorScheme(.dark)
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
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(Design.Color.accentPrimary)
            Text("Loading your profile…")
                .font(.subheadline)
                .foregroundStyle(Design.Color.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var errorView: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Design.Color.warning)
                
                if let err = profileLoadError {
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.muted)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Something went wrong")
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.muted)
                }
            }
            
            HStack(spacing: 12) {
                Button("Try Again") { reloadProfile() }
                    .buttonStyle(PrimaryButtonStyle())
                
                Button("Sign Out") { AuthSessionManager.shared.signOut() }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Design.Color.muted)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
