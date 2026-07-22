import SwiftUI

struct RootView: View {
    @ObservedObject private var session = AuthSessionManager.shared
    @AppStorage(AppTheme.storageKey) private var selectedTheme = AppTheme.defaultTheme.rawValue
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
                TodayView(profile: profile)
                    .id(profile.userId)
            }
        } else {
            loadingView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            if let profileError {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(Design.Color.muted)
                Text("Couldn’t open your profile")
                    .font(.headline)
                    .foregroundStyle(Design.Color.ink)
                Text(profileError)
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { prepareProfile() }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 220)
                Button("Sign out") { AuthSessionManager.shared.signOut() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Design.Color.muted)
                    .padding(.top, 4)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(Design.Color.accentPrimary)
                Text("Opening Shudo…")
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.muted)
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
                        profileError = "Check your connection and try again."
                    }
                }
                // Keep the cached/default profile on transient network or server failure.
            }
        }
    }
}
