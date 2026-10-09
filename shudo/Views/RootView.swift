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

    /// Which room the app is in. Moving between them is a slow crossfade
    /// (ink drying), never a hard cut.
    private enum Stage: Hashable { case auth, loading, onboarding, today }

    private var stage: Stage {
        guard session.session != nil else { return .auth }
        guard let profile else { return .loading }
        switch ProfileLaunchPolicy.destination(for: profile) {
        case .onboarding: return .onboarding
        case .loading: return .loading
        case .today: return .today
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        Group {
            if session.session == nil {
                AuthView()
                    .transition(.opacity)
            } else if let profile {
                switch ProfileLaunchPolicy.destination(for: profile) {
                case .onboarding:
                    OnboardingView(initialProfile: profile) { updatedProfile in
                        ProfileCache.save(updatedProfile)
                        self.profile = updatedProfile
                    }
                    .id("onboarding-\(profile.userId)")
                    .transition(.opacity)
                case .loading:
                    loadingView
                        .transition(.opacity)
                case .today:
                    AppShell(profile: profile)
                        .id(profile.userId)
                        .transition(.opacity)
                }
            } else {
                loadingView
                    .transition(.opacity)
            }
        }
        .animation(Design.Motion.breath, value: stage)
    }

    private var loadingView: some View {
        LaunchStateView(
            errorMessage: profileError,
            onRetry: prepareProfile,
            onSignOut: {
                Task { await CoachSync.shared.reset() }
                AuthSessionManager.shared.signOut()
            }
        )
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

/// Between rooms: Shudo's mark breathing slowly on the walnut while the
/// profile loads (a fade only under Reduce Motion), and a calm way back
/// when it can't.
struct LaunchStateView: View {
    var errorMessage: String?
    var onRetry: () -> Void
    var onSignOut: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One slow breath every 4.4 s.
    private static let breathPeriod: Double = 4.4

    var body: some View {
        VStack(spacing: Design.Space.xl) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isBreathing)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let depth = isBreathing ? (1 - cos(t * 2 * .pi / Self.breathPeriod)) / 2 : 0
                CoachAvatar(size: 56)
                    .opacity(1 - 0.45 * depth)
                    .scaleEffect(reduceMotion ? 1 : 1 - 0.04 * depth)
            }
            .accessibilityElement()
            .accessibilityLabel(errorMessage == nil ? "Opening Shudo" : "Shudo")

            if let errorMessage {
                VStack(spacing: Design.Space.l) {
                    Text(errorMessage)
                        .font(Design.Typeface.display(.title3))
                        .foregroundStyle(Design.Color.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again", action: onRetry)
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Sign out", action: onSignOut)
                        .font(Design.Typeface.text(.subheadline, weight: .medium))
                        .foregroundStyle(Design.Color.textSecondary)
                        .frame(minHeight: 44)
                        .buttonStyle(.plain)
                }
                .transition(.ink(reduceMotion: reduceMotion))
            }
        }
        .padding(Design.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Design.Motion.calm(Design.Motion.arrive, reduceMotion: reduceMotion), value: errorMessage)
    }

    private var isBreathing: Bool { errorMessage == nil }
}
