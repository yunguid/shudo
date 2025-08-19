import Foundation
import UIKit

@MainActor
final class TodayViewModel: ObservableObject {
    @Published var profile: Profile?
    @Published var todayTotals: DayTotals = .empty
    @Published var entries: [Entry] = []
    @Published var currentDay: Date = Date()
    @Published var isPresentingComposer = false
    @Published var isSubmitting = false
    @Published var submittingEntryId: UUID?
    @Published var errorMessage: String?
    @Published var isPinnedToToday: Bool = true

    let api: APIService
    let sb = SupabaseService()

    init(profile: Profile, api: APIService) {
        self.api = api
        self.profile = profile
        Task { await loadFor(profile: profile) }
    }

    func loadFor(profile: Profile) async {
        do {
            let (target, totals) = try await sb.fetchTodayStatus()
            self.profile?.dailyMacroTarget = target
            self.todayTotals = totals
            let todayEntries = try await sb.fetchEntriesForToday(timezone: profile.timezone)
            self.entries = todayEntries
            self.currentDay = Date()
            self.isPinnedToToday = true
        } catch {
            self.todayTotals = .empty
        }
    }

    func load(day: Date) async {
        guard let tz = profile?.timezone ?? TimeZone.autoupdatingCurrent.identifier as String? else { return }
        do {
            currentDay = day
            let items = try await sb.fetchEntries(for: day, timezone: tz)
            let totals = items.reduce(DayTotals.empty) { acc, e in
                DayTotals(
                    proteinG: acc.proteinG + e.proteinG,
                    carbsG: acc.carbsG + e.carbsG,
                    fatG: acc.fatG + e.fatG,
                    caloriesKcal: acc.caloriesKcal + e.caloriesKcal,
                    entryCount: acc.entryCount + 1
                )
            }
            await MainActor.run {
                self.entries = items
                self.todayTotals = totals
            }
        } catch {
            await MainActor.run { self.entries = [] }
        }
    }

    func jumpToToday() async {
        guard let tz = profile?.timezone ?? TimeZone.autoupdatingCurrent.identifier as String? else { return }
        isPinnedToToday = true
        currentDay = Date()
        await load(day: currentDay)
    }

    func deleteEntry(_ entry: Entry) async {
        guard let tz = profile?.timezone ?? TimeZone.autoupdatingCurrent.identifier as String? else { return }
        // Optimistic UI: remove locally and adjust totals
        let previous = entries
        entries.removeAll { $0.id == entry.id }
        todayTotals = DayTotals(
            proteinG: todayTotals.proteinG - entry.proteinG,
            carbsG: todayTotals.carbsG - entry.carbsG,
            fatG: todayTotals.fatG - entry.fatG,
            caloriesKcal: todayTotals.caloriesKcal - entry.caloriesKcal,
            entryCount: max(0, todayTotals.entryCount - 1)
        )
        do {
            let jwt = try await sb.currentJWT()
            var comps = URLComponents(url: sb.supabaseUrl.appendingPathComponent("/rest/v1/entries"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "id", value: "eq.\(entry.id.uuidString)")]
            var req = URLRequest(url: comps.url!)
            req.httpMethod = "DELETE"
            req.setValue(sb.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
            // Refresh authoritative entries/totals for the day
            await load(day: currentDay)
        } catch {
            // Revert on failure
            entries = previous
        }
    }

    func submitEntry(text: String?, audioURL: URL?, image: UIImage?) async {
        guard let tz = profile?.timezone ?? TimeZone.autoupdatingCurrent.identifier as String? else { return }
        isSubmitting = true; errorMessage = nil
        do {
            let newId = try await api.createEntry(text: text, audioURL: audioURL, image: image, timezone: tz)
            submittingEntryId = newId
            // Optimistically add a placeholder pending entry to the list
            let placeholder = Entry(id: newId, createdAt: Date(), summary: text?.components(separatedBy: "\n").first ?? "Processing…", imageURL: nil, proteinG: 0, carbsG: 0, fatG: 0, caloriesKcal: 0)
            entries.insert(placeholder, at: 0)
            // Poll for completion for up to ~20 seconds
            try await pollUntilComplete(entryId: newId, timeoutSeconds: 120)
            if let p = profile { await loadFor(profile: p) }
        } catch {
            errorMessage = (error as NSError).userInfo["body"] as? String ?? error.localizedDescription
        }
        isSubmitting = false
    }

    private func pollUntilComplete(entryId: UUID, timeoutSeconds: Int) async throws {
        let jwt = try await sb.currentJWT()
        var comps = URLComponents(url: sb.supabaseUrl.appendingPathComponent("/rest/v1/entries"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "select", value: "id,status,protein_g,carbs_g,fat_g,calories_kcal,raw_text"),
            URLQueryItem(name: "id", value: "eq.\(entryId.uuidString)")
        ]
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            var req = URLRequest(url: comps.url!)
            req.httpMethod = "GET"
            req.setValue(sb.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                   let obj = arr.first, let status = obj["status"] as? String {
                    if status == "complete" || status == "error" {
                        return
                    }
                }
            } catch { }
            try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s
        }
    }
}


