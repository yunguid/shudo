import SwiftUI

struct RootView: View {
    @ObservedObject private var session = AuthSessionManager.shared
    @State private var profile: Profile?
    @State private var refreshGeneration = UUID()
    @State private var profileError: String?

    var body: some View {
        Group {
            #if DEBUG
            if let previewScreen = PolishPreviewScreen.launchValue {
                PolishPreviewView(screen: previewScreen)
            } else {
                sessionContent
            }
            #else
            sessionContent
            #endif
        }
        .background(AppBackground())
        .preferredColorScheme(.dark)
        .onAppear {
            #if DEBUG
            guard PolishPreviewScreen.launchValue == nil else { return }
            #endif
            if session.session != nil { prepareProfile() }
        }
        .onChange(of: session.session) { _, newSession in
            #if DEBUG
            guard PolishPreviewScreen.launchValue == nil else { return }
            #endif
            if newSession == nil {
                // Any sign-out path (Settings, an expired session): drop the
                // coach queue and pending coach notifications with it.
                Task { await CoachSync.shared.reset() }
                profile = nil
                profileError = nil
                refreshGeneration = UUID()
            } else {
                prepareProfile()
            }
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        if session.session == nil {
            AuthView()
        } else if let profile {
            switch ProfileLaunchPolicy.destination(for: profile) {
            case .onboarding:
                OnboardingView(initialProfile: profile) { updatedProfile in
                    ProfileCache.save(updatedProfile)
                    self.profile = updatedProfile
                }
                .id("onboarding-\(profile.userId)")
            case .loading:
                loadingView
            case .today:
                AppShell(profile: profile)
                    .id(profile.userId)
            }
        } else {
            loadingView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            CoachAvatar(size: 56, isThinking: profileError == nil)
                .accessibilityLabel(profileError == nil ? "Opening Shudo" : "Shudo")
            if let profileError {
                Text(profileError)
                    .font(.headline)
                    .foregroundStyle(Design.Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { prepareProfile() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 6)
                Button("Sign out") {
                    Task { await CoachSync.shared.reset() }
                    AuthSessionManager.shared.signOut()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Design.Color.textTertiary)
                .frame(minHeight: 44)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func prepareProfile() {
        profileError = nil
        let userId = session.userId
        // Cached profiles render immediately while the authoritative row is
        // refreshed for onboarding status, targets, timezone, and units.
        profile = ProfileCache.load(userId: userId)

        let generation = UUID()
        refreshGeneration = generation
        Task {
            do {
                let fresh = try await SupabaseService().ensureProfileDefaults()
                guard refreshGeneration == generation else { return }
                ProfileCache.save(fresh)
                await MainActor.run { profile = fresh }
            } catch {
                guard refreshGeneration == generation else { return }
                let friendlyStatus = (error as? SupabaseAuthService.FriendlyAuthError)?.httpStatus
                let serviceAuthenticationFailure =
                    (error as? SupabaseService.ServiceError)?.isAuthenticationFailure == true
                if friendlyStatus == 401 || friendlyStatus == 403 || serviceAuthenticationFailure {
                    await MainActor.run { AuthSessionManager.shared.signOut() }
                } else if profile == nil {
                    await MainActor.run {
                        profileError = "Can’t reach Shudo right now."
                    }
                }
                // Keep the cached/default profile on transient network or server failure.
            }
        }
    }
}
