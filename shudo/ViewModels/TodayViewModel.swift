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
    let supabase: SupabaseService

    init(profile: Profile, api: APIService, supabase: SupabaseService = SupabaseService()) {
        self.api = api
        self.supabase = supabase
        self.profile = profile
        Task { await loadFor(profile: profile) }
    }

    func loadFor(profile: Profile) async {
        do {
            let (target, totals) = try await supabase.fetchTodayStatus()
            self.profile?.dailyMacroTarget = target
            self.todayTotals = totals
            let todayEntries = try await supabase.fetchEntriesForToday(timezone: profile.timezone)
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
            let items = try await supabase.fetchEntries(for: day, timezone: tz)
            let totals = items.reduce(DayTotals.empty) { acc, e in
                DayTotals(
                    proteinG: acc.proteinG + e.proteinG,
                    carbsG: acc.carbsG + e.carbsG,
                    fatG: acc.fatG + e.fatG,
                    caloriesKcal: acc.caloriesKcal + e.caloriesKcal,
                    entryCount: acc.entryCount + 1
                )
            }
            self.entries = items
            self.todayTotals = totals
        } catch {
            self.entries = []
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
            let jwt = try await supabase.currentJWT()
            var comps = URLComponents(url: supabase.supabaseUrl.appendingPathComponent("/rest/v1/entries"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "id", value: "eq.\(entry.id.uuidString)")]
            var req = URLRequest(url: comps.url!)
            req.httpMethod = "DELETE"
            req.setValue(supabase.anonKey, forHTTPHeaderField: "apikey")
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

    func submitEntry(text: String?, audioData: Data?, image: UIImage?) async {
        guard let tz = profile?.timezone ?? TimeZone.autoupdatingCurrent.identifier as String? else { return }
        isSubmitting = true; errorMessage = nil
        do {
            let newId = try await api.createEntry(text: text, audioData: audioData, image: image, timezone: tz)
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
        var comps = URLComponents(url: supabase.supabaseUrl.appendingPathComponent("/rest/v1/entries"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "select", value: "id,status,protein_g,carbs_g,fat_g,calories_kcal,raw_text"),
            URLQueryItem(name: "id", value: "eq.\(entryId.uuidString)")
        ]
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        var pollInterval: UInt64 = 600_000_000 // Start at 0.6s
        let maxInterval: UInt64 = 3_000_000_000 // Max 3s
        var consecutiveErrors = 0
        
        while Date() < deadline {
            // Refresh JWT each iteration to prevent expiration during long polls
            let jwt = try await supabase.currentJWT()
            
            var req = URLRequest(url: comps.url!)
            req.httpMethod = "GET"
            req.setValue(supabase.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
            
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                consecutiveErrors = 0 // Reset on success
                
                guard let http = resp as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                
                guard (200..<300).contains(http.statusCode) else {
                    throw NSError(domain: "API", code: http.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "Server returned \(http.statusCode)"
                    ])
                }
                
                guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      let obj = arr.first,
                      let status = obj["status"] as? String else {
                    throw URLError(.cannotParseResponse)
                }
                
                switch status {
                case "complete":
                    return
                case "error":
                    throw NSError(domain: "Entry", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "Failed to process entry. Please try again."
                    ])
                default:
                    break // Still processing, continue polling
                }
            } catch {
                consecutiveErrors += 1
                // Allow a few transient failures before giving up
                if consecutiveErrors >= 5 {
                    throw error
                }
            }
            
            try await Task.sleep(nanoseconds: pollInterval)
            // Exponential backoff: increase interval by 50% each iteration, up to max
            pollInterval = min(pollInterval + pollInterval / 2, maxInterval)
        }
        
        // Timeout reached without completion
        throw NSError(domain: "Entry", code: -2, userInfo: [
            NSLocalizedDescriptionKey: "Entry processing timed out. It may still complete in the background."
        ])
    }
}


