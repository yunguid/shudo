import Foundation

struct SupabaseService {
    struct TodayStatusDTO: Decodable { /* unused; keeping for reference */
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
            "units": "imperial",
            "cutoff_time_local": "20:00",
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
            func toDouble(_ any: Any?) -> Double {
                if let d = any as? Double { return d }
                if let i = any as? Int { return Double(i) }
                if let s = any as? String { return Double(s) ?? 0 }
                return 0
            }
            func parseJSONIfString(_ any: Any?) -> [String: Any]? {
                if let dict = any as? [String: Any] { return dict }
                if let s = any as? String, let d = s.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return obj }
                return nil
            }
            let tz = obj["timezone"] as? String ?? TimeZone.autoupdatingCurrent.identifier

            var targetDict: [String: Any] = [:]
            if let d = parseJSONIfString(obj["daily_macro_target"]) { targetDict = d }

            let units = (obj["units"] as? String) ?? "imperial"
            let activity = obj["activity_level"] as? String
            let cutoffRaw = obj["cutoff_time_local"] as? String
            let cutoff = cutoffRaw.flatMap { String($0.prefix(5)) }
            let heightCM = toDouble(obj["height_cm"]) == 0 ? nil : toDouble(obj["height_cm"]) 
            let weightKG = toDouble(obj["weight_kg"]) == 0 ? nil : toDouble(obj["weight_kg"]) 
            let targetWeightKG = toDouble(obj["target_weight_kg"]) == 0 ? nil : toDouble(obj["target_weight_kg"]) 

            let profile = Profile(
                userId: userId,
                timezone: tz,
                dailyMacroTarget: MacroTarget(
                    caloriesKcal: toDouble(targetDict["calories_kcal"]) != 0 ? toDouble(targetDict["calories_kcal"]) : 2800,
                    proteinG: toDouble(targetDict["protein_g"]) != 0 ? toDouble(targetDict["protein_g"]) : 180,
                    carbsG: toDouble(targetDict["carbs_g"]) != 0 ? toDouble(targetDict["carbs_g"]) : 360,
                    fatG: toDouble(targetDict["fat_g"]) != 0 ? toDouble(targetDict["fat_g"]) : 72
                ),
                units: units,
                heightCM: heightCM,
                weightKG: weightKG,
                targetWeightKG: targetWeightKG,
                activityLevel: activity,
                cutoffTimeLocal: cutoff
            )
            return profile
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
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let row = arr.first else {
            return (MacroTarget(caloriesKcal: 2800, proteinG: 180, carbsG: 360, fatG: 72), .empty)
        }
        func toDouble(_ any: Any?) -> Double { if let d = any as? Double { return d }; if let s = any as? String { return Double(s) ?? 0 }; return 0 }
        let target = MacroTarget(
            caloriesKcal: toDouble(row["target_calories_kcal"]) != 0 ? toDouble(row["target_calories_kcal"]) : 2800,
            proteinG: toDouble(row["target_protein_g"]) != 0 ? toDouble(row["target_protein_g"]) : 180,
            carbsG: toDouble(row["target_carbs_g"]) != 0 ? toDouble(row["target_carbs_g"]) : 360,
            fatG: toDouble(row["target_fat_g"]) != 0 ? toDouble(row["target_fat_g"]) : 72
        )
        let totals = DayTotals(
            proteinG: toDouble(row["consumed_protein_g"]),
            carbsG: toDouble(row["consumed_carbs_g"]),
            fatG: toDouble(row["consumed_fat_g"]),
            caloriesKcal: toDouble(row["consumed_calories_kcal"]),
            entryCount: 0
        )
        return (target, totals)
    }

    func fetchEntriesForToday(timezone: String) async throws -> [Entry] {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        let localDay = localDayString(for: Date(), timezone: timezone)
        var comps = URLComponents(url: supabaseUrl.appendingPathComponent("/rest/v1/entries"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "select", value: "id,created_at,raw_text,model_output,protein_g,carbs_g,fat_g,calories_kcal,image_path"),
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
        func toDouble(_ any: Any?) -> Double { if let d = any as? Double { return d }; if let s = any as? String { return Double(s) ?? 0 }; return 0 }
        func parseJSONIfString(_ any: Any?) -> Any? {
            if let dict = any as? [String: Any] { return dict }
            if let s = any as? String, let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
            return nil
        }
        func summarize(from modelOutput: Any?, rawText: String?) -> String {
            if let mo = parseJSONIfString(modelOutput) as? [String: Any] {
                let parsed = (mo["parsed"] as? [String: Any]) ?? mo
                if let name = parsed["food_name"] as? String, !name.isEmpty { return name }
                if let name = parsed["name"] as? String, !name.isEmpty { return name }
                if let item = parsed["item"] as? [String: Any], let n = item["name"] as? String, !n.isEmpty { return n }
                if let items = parsed["items"] as? [[String: Any]], !items.isEmpty {
                    let names = items.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
                    if names.isEmpty == false {
                        if names.count <= 2 { return names.joined(separator: ", ") }
                        return names.prefix(2).joined(separator: ", ") + " + \(names.count - 2) more"
                    }
                }
                if let raw = parsed["raw_text"] as? String, let nested = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                    if let nestedItems = nested["items"] as? [[String: Any]] {
                        let names: [String] = nestedItems.compactMap { $0["name"] as? String }
                        if !names.isEmpty {
                            if names.count <= 2 { return names.joined(separator: ", ") }
                            return names.prefix(2).joined(separator: ", ") + " + \(names.count - 2) more"
                        }
                    }
                    if let n = nested["food_name"] as? String, !n.isEmpty { return n }
                }
            }
            return (rawText?.components(separatedBy: "\n").first ?? "Entry")
        }

        var results: [Entry] = []
        for obj in arr {
            guard let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr) else { continue }
            let createdAtStr = obj["created_at"] as? String ?? ""
            let createdAt = ISO8601DateFormatter().date(from: createdAtStr) ?? Date()
            let summary = summarize(from: obj["model_output"], rawText: obj["raw_text"] as? String)
            let protein = toDouble(obj["protein_g"]) 
            let carbs = toDouble(obj["carbs_g"]) 
            let fat = toDouble(obj["fat_g"]) 
            let kcal = toDouble(obj["calories_kcal"]) 
            var imageURL: URL? = nil
            if let path = obj["image_path"] as? String { imageURL = await signImageURL(path: path, jwt: jwt) }
            results.append(Entry(id: id, createdAt: createdAt, summary: summary, imageURL: imageURL, proteinG: protein, carbsG: carbs, fatG: fat, caloriesKcal: kcal))
        }
        return results
    }

    func localDayString(for date: Date, timezone: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = calendar.date(from: comps) ?? date
        return formatter.string(from: day)
    }

    func fetchEntries(for date: Date, timezone: String) async throws -> [Entry] {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        let localDay = localDayString(for: date, timezone: timezone)
        var comps = URLComponents(url: supabaseUrl.appendingPathComponent("/rest/v1/entries"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "select", value: "id,created_at,raw_text,model_output,protein_g,carbs_g,fat_g,calories_kcal,image_path"),
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

        func toDouble(_ any: Any?) -> Double { if let d = any as? Double { return d }; if let s = any as? String { return Double(s) ?? 0 }; return 0 }
        func parseJSONIfString(_ any: Any?) -> Any? {
            if let dict = any as? [String: Any] { return dict }
            if let s = any as? String, let data = s.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
            return nil
        }
        func summarize(from modelOutput: Any?, rawText: String?) -> String {
            if let mo = parseJSONIfString(modelOutput) as? [String: Any] {
                let parsed = (mo["parsed"] as? [String: Any]) ?? mo
                if let name = parsed["food_name"] as? String, !name.isEmpty { return name }
                if let name = parsed["name"] as? String, !name.isEmpty { return name }
                if let item = parsed["item"] as? [String: Any], let n = item["name"] as? String, !n.isEmpty { return n }
                if let items = parsed["items"] as? [[String: Any]], !items.isEmpty {
                    let names = items.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
                    if names.isEmpty == false {
                        if names.count <= 2 { return names.joined(separator: ", ") }
                        return names.prefix(2).joined(separator: ", ") + " + \(names.count - 2) more"
                    }
                }
                if let raw = parsed["raw_text"] as? String, let nested = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                    if let nestedItems = nested["items"] as? [[String: Any]] {
                        let names: [String] = nestedItems.compactMap { $0["name"] as? String }
                        if !names.isEmpty {
                            if names.count <= 2 { return names.joined(separator: ", ") }
                            return names.prefix(2).joined(separator: ", ") + " + \(names.count - 2) more"
                        }
                    }
                    if let n = nested["food_name"] as? String, !n.isEmpty { return n }
                }
            }
            return (rawText?.components(separatedBy: "\n").first ?? "Entry")
        }

        var results: [Entry] = []
        for obj in arr {
            guard let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr) else { continue }
            let createdAtStr = obj["created_at"] as? String ?? ""
            let createdAt = ISO8601DateFormatter().date(from: createdAtStr) ?? Date()
            let summary = summarize(from: obj["model_output"], rawText: obj["raw_text"] as? String)
            let protein = toDouble(obj["protein_g"]) 
            let carbs = toDouble(obj["carbs_g"]) 
            let fat = toDouble(obj["fat_g"]) 
            let kcal = toDouble(obj["calories_kcal"]) 
            var imageURL: URL? = nil
            if let path = obj["image_path"] as? String { imageURL = await signImageURL(path: path, jwt: jwt) }
            results.append(Entry(id: id, createdAt: createdAt, summary: summary, imageURL: imageURL, proteinG: protein, carbsG: carbs, fatG: fat, caloriesKcal: kcal))
        }
        return results
    }

    private func signImageURL(path: String, jwt: String) async -> URL? {
        // Build path without encoding slashes in the object key
        var url = supabaseUrl.appendingPathComponent("storage/v1/object/sign/entry-images")
        for segment in path.split(separator: "/") {
            url.appendPathComponent(String(segment))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["expiresIn": 600])
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Normalize possible response shapes from Storage REST
            let strCandidates: [String] = [
                obj["signedURL"] as? String,
                obj["signedUrl"] as? String,
                obj["url"] as? String
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }

            func absolutize(_ s: String) -> URL? {
                if let u = URL(string: s), u.scheme != nil { return u }
                // Build base https://host/storage/v1
                var base = supabaseUrl.appendingPathComponent("storage/v1")
                if s.hasPrefix("/") { return URL(string: base.absoluteString + s) }
                if s.hasPrefix("object/") || s.hasPrefix("object/sign/") { return URL(string: base.appendingPathComponent(s).absoluteString) }
                if s.hasPrefix("entry-images/") { return URL(string: base.appendingPathComponent("object/sign").appendingPathComponent(s).absoluteString) }
                // Fallback: treat as already rooted
                return URL(string: base.appendingPathComponent(s).absoluteString)
            }

            for s in strCandidates { if let u = absolutize(s) { return u } }

            if let arr = obj["signedUrls"] as? [[String: Any]] {
                if let s = (arr.first?["signedUrl"] as? String) ?? (arr.first?["signedURL"] as? String) {
                    if let u = absolutize(s) { return u }
                }
            }
        }
        return nil
    }

    // MARK: - Onboarding persistence

    /// Update user personalization fields. Only non-nil parameters are sent.
    func updateProfilePersonalization(
        units: String? = nil,
        heightCM: Double? = nil,
        weightKG: Double? = nil,
        targetWeightKG: Double? = nil,
        activityLevel: String? = nil,
        cutoffTimeLocal: String? = nil
    ) async throws {
        let jwt = try await currentJWT()
        let userId = try currentUserId()

        var payload: [String: Any] = [:]
        if let units = units { payload["units"] = units }
        if let heightCM = heightCM { payload["height_cm"] = heightCM }
        if let weightKG = weightKG { payload["weight_kg"] = weightKG }
        if let targetWeightKG = targetWeightKG { payload["target_weight_kg"] = targetWeightKG }
        if let activityLevel = activityLevel { payload["activity_level"] = activityLevel }
        if let cutoffTimeLocal = cutoffTimeLocal { payload["cutoff_time_local"] = cutoffTimeLocal }

        // Nothing to update
        if payload.isEmpty { return }

        var comps = URLComponents(url: supabaseUrl.appendingPathComponent("/rest/v1/profiles"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "user_id", value: "eq.\(userId)")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
    }

    /// Compute daily macro targets and persist them to profiles.daily_macro_target.
    /// - Returns: The computed MacroTarget
    func computeAndSaveDailyTargets(
        weightKG: Double,
        targetWeightKG: Double,
        activityLevel: String
    ) async throws -> MacroTarget {
        // Very simple energy model for now: BMR ~ 24 * weight (kcal), times activity multiplier
        let multipliers: [String: Double] = [
            "sedentary": 1.2,
            "light": 1.375,
            "moderate": 1.55,
            "active": 1.725,
            "extra_active": 1.9
        ]
        let activity = multipliers[activityLevel] ?? 1.55
        let baseBMR = 24.0 * max(30.0, weightKG) // clamp to reasonable minimum weight
        let maintenanceKcal = baseBMR * activity

        // Macro allocations
        let proteinG = 1.8 * max(0, targetWeightKG)
        let fatG = 0.8 * max(0, targetWeightKG)
        let kcalMinusPF = max(0, maintenanceKcal - (proteinG * 4 + fatG * 9))
        let carbsG = max(0, kcalMinusPF / 4.0)

        let target = MacroTarget(caloriesKcal: maintenanceKcal, proteinG: proteinG, carbsG: carbsG, fatG: fatG)

        // Persist
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        var comps = URLComponents(url: supabaseUrl.appendingPathComponent("/rest/v1/profiles"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "user_id", value: "eq.\(userId)")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "daily_macro_target": [
                "calories_kcal": target.caloriesKcal,
                "protein_g": target.proteinG,
                "carbs_g": target.carbsG,
                "fat_g": target.fatG
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }

        return target
    }
}


