import Foundation

struct SupabaseService {
    struct TodayStatusDTO: Decodable {
        let user_id: String
        let target_protein_g: Double
        let target_carbs_g: Double
        let target_fat_g: Double
        let target_calories_kcal: Double
        let consumed_protein_g: Double?
        let consumed_carbs_g: Double?
        let consumed_fat_g: Double?
        let consumed_calories_kcal: Double?
    }

    let supabaseUrl: URL = AppConfig.supabaseURL
    let anonKey: String = AppConfig.supabaseAnonKey

    func currentJWT() async throws -> String { try await AuthSessionManager.shared.getAccessToken() }
    func currentUserId() throws -> String { guard let id = AuthSessionManager.shared.userId else { throw NSError(domain: "Auth", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing user id"]) }; return id }

    func ensureProfileDefaults() async throws -> Profile {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        if let p = try await fetchProfile(userId: userId) { return p }
        let timezone = TimeZone.autoupdatingCurrent.identifier
        let target = [
            "calories_kcal": 2800,
            "protein_g": 180,
            "carbs_g": 360,
            "fat_g": 72
        ] as [String : Any]
        var req = URLRequest(url: supabaseUrl.appendingPathComponent("/rest/v1/profiles"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "user_id": userId,
            "timezone": timezone,
            "daily_macro_target": target
        ])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return Profile(userId: userId, timezone: timezone, dailyMacroTarget: MacroTarget(caloriesKcal: 2800, proteinG: 180, carbsG: 360, fatG: 72))
    }

    func fetchProfile(userId: String) async throws -> Profile? {
        let jwt = try await currentJWT()
        var comps = URLComponents(url: supabaseUrl.appendingPathComponent("/rest/v1/profiles"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "user_id", value: "eq.\(userId)")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let obj = arr.first {
            let tz = obj["timezone"] as? String ?? TimeZone.autoupdatingCurrent.identifier
            if let target = obj["daily_macro_target"] as? [String: Any] {
                let profile = Profile(userId: userId, timezone: tz, dailyMacroTarget: MacroTarget(
                    caloriesKcal: (target["calories_kcal"] as? Double) ?? 2800,
                    proteinG: (target["protein_g"] as? Double) ?? 180,
                    carbsG: (target["carbs_g"] as? Double) ?? 360,
                    fatG: (target["fat_g"] as? Double) ?? 72
                ))
                return profile
            }
        }
        return nil
    }

    func fetchTodayStatus() async throws -> (MacroTarget, DayTotals) {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        var comps = URLComponents(url: supabaseUrl.appendingPathComponent("/rest/v1/today_status"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "user_id", value: "eq.\(userId)")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let arr = try JSONDecoder().decode([TodayStatusDTO].self, from: data)
        let row = arr.first
        let target = MacroTarget(
            caloriesKcal: row?.target_calories_kcal ?? 2800,
            proteinG: row?.target_protein_g ?? 180,
            carbsG: row?.target_carbs_g ?? 360,
            fatG: row?.target_fat_g ?? 72
        )
        let totals = DayTotals(
            proteinG: row?.consumed_protein_g ?? 0,
            carbsG: row?.consumed_carbs_g ?? 0,
            fatG: row?.consumed_fat_g ?? 0,
            caloriesKcal: row?.consumed_calories_kcal ?? 0,
            entryCount: 0
        )
        return (target, totals)
    }

    func fetchEntriesForToday(timezone: String) async throws -> [Entry] {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        let localDay = localDayString(timezone: timezone)
        var comps = URLComponents(url: supabaseUrl.appendingPathComponent("/rest/v1/entries"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "select", value: "id,created_at,raw_text,protein_g,carbs_g,fat_g,calories_kcal,image_path"),
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "local_day", value: "eq.\(localDay)"),
            URLQueryItem(name: "status", value: "eq.complete"),
            URLQueryItem(name: "order", value: "created_at.desc")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { obj in
            guard let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr) else { return nil }
            let createdAtStr = obj["created_at"] as? String ?? ""
            let createdAt = ISO8601DateFormatter().date(from: createdAtStr) ?? Date()
            let summary = (obj["raw_text"] as? String)?.components(separatedBy: "\n").first ?? "Entry"
            let protein = (obj["protein_g"] as? Double) ?? 0
            let carbs = (obj["carbs_g"] as? Double) ?? 0
            let fat = (obj["fat_g"] as? Double) ?? 0
            let kcal = (obj["calories_kcal"] as? Double) ?? 0
            return Entry(id: id, createdAt: createdAt, summary: summary, imageURL: nil, proteinG: protein, carbsG: carbs, fatG: fat, caloriesKcal: kcal)
        }
    }

    private func localDayString(timezone: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let comps = calendar.dateComponents([.year, .month, .day], from: Date())
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let date = calendar.date(from: comps) ?? Date()
        return formatter.string(from: date)
    }
}


