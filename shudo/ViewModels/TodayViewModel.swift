import Foundation
import UIKit

@MainActor
final class TodayViewModel: ObservableObject {
    @Published var profile: Profile?
    @Published var todayTotals: DayTotals = .empty
    @Published var entries: [Entry] = []
    @Published var isPresentingComposer = false
    @Published var isSubmitting = false
    @Published var errorMessage: String?

    let api: APIService
    let sb = SupabaseService()

    init(api: APIService) {
        self.api = api
        Task { await loadInitial() }
    }

    func loadInitial() async {
        do {
            let prof = try await sb.ensureProfileDefaults()
            self.profile = prof
            let (target, totals) = try await sb.fetchTodayStatus()
            self.profile?.dailyMacroTarget = target
            self.todayTotals = totals
            let todayEntries = try await sb.fetchEntriesForToday(timezone: prof.timezone)
            self.entries = todayEntries
        } catch {
            self.profile = self.profile ?? Profile(userId: AuthSessionManager.shared.userId ?? "", timezone: TimeZone.autoupdatingCurrent.identifier, dailyMacroTarget: MacroTarget(caloriesKcal: 2800, proteinG: 180, carbsG: 360, fatG: 72))
            self.todayTotals = .empty
        }
    }

    func submitEntry(text: String?, audioURL: URL?, image: UIImage?) async {
        guard let tz = profile?.timezone ?? TimeZone.autoupdatingCurrent.identifier as String? else { return }
        isSubmitting = true; errorMessage = nil
        do {
            try await api.createEntry(text: text, audioURL: audioURL, image: image, timezone: tz)
            await loadInitial()
        } catch {
            errorMessage = (error as NSError).userInfo["body"] as? String ?? error.localizedDescription
        }
        isSubmitting = false
    }
}


