import SwiftUI
import UIKit

enum AppTab: String, Hashable, CaseIterable {
    case today, body, train
}

/// Everything the app shell needs from the outside world. `live` talks to
/// Supabase and the coach backend; PolishPreview swaps in fixtures so the
/// whole shell (Today thread, capture bar, Body, Train, Settings) renders
/// offline and deterministically for screenshots and UI tests.
@MainActor
struct ShellDependencies {
    var loadsRemotely: Bool
    var makeToday: () -> TodayViewModel
    var makeCoach: () -> CoachViewModel
    var coachService: any CoachServing
    var trainService: any TrainServing
    var bodyService: any BodyServicing
    /// `CoachSync.shared.record` live; a no-op offline.
    var recordEvent: (CoachSync.LocalEvent) -> Void
    var bioRevisions: () async throws -> [CoachMemoryRevision]
    /// Signed URL for a chat photo / activity photo in `coach-media`.
    var coachMediaURL: (String) async -> URL?
    var makeBodyScreen: (Profile, @escaping (WeightCheckIn) -> Void) -> AnyView
    var makeTrainViewModel: (Profile, ActivityLoggingController) -> TrainViewModel
    var makeAccountView: (Profile, AccountView.ShellHooks) -> AnyView
    /// Preview/UI tests: meal detail rendered from a fixture (offline).
    var previewEntryDetail: SupabaseService.EntryDetail?
    var composerSeedImages: [UIImage] = []
    var now: () -> Date = { Date() }
    var initialTab: AppTab = .today
    var initialHeaderExpanded = false
    /// Preview scripts (e.g. start a turn so the typing indicator shows).
    var onLaunch: ((CoachViewModel) -> Void)?

    static func live(profile: Profile) -> ShellDependencies {
        let supabase = SupabaseService()
        let api = APIService(
            supabaseUrl: AppConfig.supabaseURL,
            supabaseAnonKey: AppConfig.supabaseAnonKey,
            sessionJWTProvider: { try await AuthSessionManager.shared.getAccessToken() }
        )
        return ShellDependencies(
            loadsRemotely: true,
            makeToday: { TodayViewModel(profile: profile, api: api, supabase: supabase) },
            makeCoach: {
                CoachViewModel.live(timeZone: {
                    TimeZone(identifier: ProfileCache.load(userId: profile.userId)?.timezone ?? profile.timezone)
                        ?? .autoupdatingCurrent
                })
            },
            coachService: CoachService.live,
            trainService: supabase,
            bodyService: LiveBodyService(),
            recordEvent: { event in Task { await CoachSync.shared.record(event) } },
            bioRevisions: { try await supabase.fetchCoachMemoryRevisions() },
            coachMediaURL: { path in await supabase.signedActivityImageURL(path: path) },
            makeBodyScreen: { profile, onSaved in
                AnyView(BodyScreen(profile: profile, onCheckInSaved: onSaved))
            },
            makeTrainViewModel: { profile, logging in
                TrainViewModel(profile: profile, service: supabase, logging: logging)
            },
            makeAccountView: { profile, hooks in
                AnyView(AccountView(initialProfile: profile, hooks: hooks))
            },
            previewEntryDetail: nil
        )
    }
}
