import Foundation

/// One saved version of the coach's memory document (`coach_memory_revisions`),
/// shown on the Bio screen as "what changed, when, and why".
struct CoachMemoryRevision: Identifiable, Equatable, Sendable {
    var id: UUID
    var version: Int
    /// `seed` | `onboarding` | `coach_reply` | `bio_update` | `day_digest` | `weekly` | `manual` | `undo`
    var source: String
    var changeSummary: String?
    var createdAt: Date

    /// Who made the change, in Luke's words.
    var sourceLabel: String {
        switch source {
        case "seed", "onboarding": return "Starting bio"
        case "bio_update": return "You, by voice"
        case "coach_reply": return "From a chat"
        case "day_digest": return "Shudo's nightly notes"
        case "weekly": return "Weekly review"
        case "undo": return "Undo"
        case "manual": return "Edited"
        default: return source.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func parse(_ data: Data) throws -> [CoachMemoryRevision] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SupabaseService.ServiceError.parseError(message: "Invalid bio history response")
        }
        return rows.compactMap { row in
            guard let idText = row["id"] as? String, let id = UUID(uuidString: idText),
                  let version = (row["version"] as? NSNumber)?.intValue,
                  let createdText = row["created_at"] as? String,
                  let created = CoachDateCoding.date(from: createdText)
            else { return nil }
            let summary = (row["change_summary"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return CoachMemoryRevision(
                id: id,
                version: version,
                source: row["source"] as? String ?? "manual",
                changeSummary: summary?.isEmpty == false ? summary : nil,
                createdAt: created
            )
        }
    }
}

extension SupabaseService {
    /// Newest revisions of the signed-in user's coach memory (RLS: select own).
    func fetchCoachMemoryRevisions(limit: Int = 8) async throws -> [CoachMemoryRevision] {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        var components = URLComponents(
            url: supabaseUrl.appendingPathComponent("/rest/v1/coach_memory_revisions"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,version,source,change_summary,created_at"),
            URLQueryItem(name: "user_id", value: "eq.\(userId.lowercased())"),
            URLQueryItem(name: "order", value: "version.desc"),
            URLQueryItem(name: "limit", value: "\(max(1, min(limit, 50)))"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.parseError(message: "Couldn’t load your bio history")
        }
        return try CoachMemoryRevision.parse(data)
    }
}
