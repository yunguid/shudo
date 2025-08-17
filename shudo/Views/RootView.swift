import SwiftUI

struct RootView: View {
    @ObservedObject private var session = AuthSessionManager.shared
    @State private var profile: Profile?
    @State private var isLoadingProfile = false

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
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
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
        Task {
            defer { isLoadingProfile = false }
            do {
                let p = try await SupabaseService().ensureProfileDefaults()
                await MainActor.run { self.profile = p }
            } catch {
                await MainActor.run { self.profile = nil }
            }
        }
    }
}


