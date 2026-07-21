import SwiftUI

struct RootView: View {
    @ObservedObject private var session = AuthSessionManager.shared
    @State private var profile: Profile?
    @State private var refreshGeneration = UUID()

    var body: some View {
        Group {
            if session.session == nil {
                AuthView()
            } else if let profile {
                TodayView(profile: profile)
                    .id(profile.userId)
            } else {
                loadingView
            }
        }
        .background(AppBackground())
        .preferredColorScheme(.dark)
        .onAppear {
            if session.session != nil { prepareProfile() }
        }
        .onChange(of: session.session) { _, newSession in
            if newSession == nil {
                profile = nil
                refreshGeneration = UUID()
            } else {
                prepareProfile()
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(Design.Color.accentPrimary)
            Text("Opening Shudo…")
                .font(.subheadline)
                .foregroundStyle(Design.Color.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func prepareProfile() {
        let userId = session.userId
        profile = ProfileCache.load(userId: userId) ?? ProfileCache.fallback(userId: userId)

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
                }
                // Keep the cached/default profile on transient network or server failure.
            }
        }
    }
}
