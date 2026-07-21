import Foundation

struct SupabaseService: Sendable {
    static let signedImageConcurrencyLimit = 4

    private struct ParsedEntry {
        var entry: Entry
        let imagePath: String?
    }

    /// Errors that can occur during Supabase operations
    enum ServiceError: LocalizedError {
        case networkError(underlying: Error)
        case serverError(statusCode: Int, message: String?)
        case parseError(message: String)

        var isAuthenticationFailure: Bool {
            guard case .serverError(let statusCode, _) = self else { return false }
            return statusCode == 401 || statusCode == 403
        }

        var errorDescription: String? {
            switch self {
            case .networkError(let underlying):
                return "Network error: \(underlying.localizedDescription)"
            case .serverError(let code, let message):
                return message ?? "Server error (\(code))"
            case .parseError(let message):
                return "Failed to parse response: \(message)"
            }
        }
    }

    let supabaseUrl: URL = AppConfig.supabaseURL
    let anonKey: String = AppConfig.supabaseAnonKey

    func currentJWT() async throws -> String { try await AuthSessionManager.shared.getAccessToken() }
    func currentUserId() throws -> String { guard let id = AuthSessionManager.shared.userId else { throw NSError(domain: "Auth", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing user id"]) }; return id }
    
    // MARK: - Shared Helpers
    
    private static func toDouble(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) ?? 0 }
        return 0
    }
    
    private static func parseJSONIfString(_ any: Any?) -> [String: Any]? {
        if let dict = any as? [String: Any] { return dict }
        if let s = any as? String, let d = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return obj }
        return nil
    }
    
    private static func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    static func boundedConcurrentMap<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        maximumConcurrentTasks: Int,
        operation: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        guard !inputs.isEmpty else { return [] }
        let limit = max(1, min(maximumConcurrentTasks, inputs.count))

        return await withTaskGroup(of: (Int, Output).self) { group in
            var nextIndex = 0
            var results = Array<Output?>(repeating: nil, count: inputs.count)

            while nextIndex < limit {
                let index = nextIndex
                let input = inputs[index]
                group.addTask { (index, await operation(input)) }
                nextIndex += 1
            }

            while let (index, output) = await group.next() {
                // `.some` preserves a legitimate nil when Output itself is Optional.
                results[index] = .some(output)

                if nextIndex < inputs.count {
                    let pendingIndex = nextIndex
                    let input = inputs[pendingIndex]
                    group.addTask { (pendingIndex, await operation(input)) }
                    nextIndex += 1
                }
            }

            return results.enumerated().map { index, result in
                guard let result else {
                    preconditionFailure("Missing bounded map result at index \(index)")
                }
                return result
            }
        }
    }

    func ensureProfileDefaults() async throws -> Profile {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        if let p = try await fetchProfile(userId: userId) { return p }
        let timezone = TimeZone.autoupdatingCurrent.identifier
        let defaults = MacroTarget.defaultDaily
        let target = [
            "calories_kcal": defaults.caloriesKcal,
            "protein_g": defaults.proteinG,
            "carbs_g": defaults.carbsG,
            "fat_g": defaults.fatG
        ]
        var comps = URLComponents(url: supabaseUrl.appendingPathComponent("/rest/v1/profiles"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "on_conflict", value: "user_id")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        // If a row already exists, ignore duplicate and do not error
        req.setValue("resolution=ignore-duplicates, return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "user_id": userId,
            "timezone": timezone,
            "units": "imperial",
            "cutoff_time_local": "20:00",
            "daily_macro_target": target
        ])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        // Fetch authoritative row to return consistent state
        if let fetched = try await fetchProfile(userId: userId) {
            return fetched
        }
        // Fallback to defaults if fetch somehow fails
        return Profile(
            userId: userId,
            timezone: timezone,
            dailyMacroTarget: .defaultDaily
        )
    }

    func fetchProfile(userId: String) async throws -> Profile? {
        let jwt = try await currentJWT()
        var comps = URLComponents(url: supabaseUrl.appendingPathComponent("/rest/v1/profiles"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "select", value: "*"), URLQueryItem(name: "user_id", value: "eq.\(userId)")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw ServiceError.networkError(underlying: error)
        }

        guard let http = resp as? HTTPURLResponse else {
            throw ServiceError.parseError(message: "Invalid response type")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.serverError(statusCode: http.statusCode, message: "Failed to fetch profile")
        }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ServiceError.parseError(message: "Invalid JSON response")
        }
        guard let obj = arr.first else { return nil } // No profile found is valid (not an error)
        
        let tz = obj["timezone"] as? String ?? TimeZone.autoupdatingCurrent.identifier
        let targetDict = Self.parseJSONIfString(obj["daily_macro_target"]) ?? [:]
        let defaults = MacroTarget.defaultDaily

        let units = (obj["units"] as? String) ?? "imperial"
        let heightCM = Self.toDouble(obj["height_cm"]) == 0 ? nil : Self.toDouble(obj["height_cm"])
        let weightKG = Self.toDouble(obj["weight_kg"]) == 0 ? nil : Self.toDouble(obj["weight_kg"])
        let targetWeightKG = Self.toDouble(obj["target_weight_kg"]) == 0 ? nil : Self.toDouble(obj["target_weight_kg"])

        return Profile(
            userId: userId,
            timezone: tz,
            dailyMacroTarget: MacroTarget(
                caloriesKcal: Self.toDouble(targetDict["calories_kcal"]) != 0
                    ? Self.toDouble(targetDict["calories_kcal"])
                    : defaults.caloriesKcal,
                proteinG: Self.toDouble(targetDict["protein_g"]) != 0
                    ? Self.toDouble(targetDict["protein_g"])
                    : defaults.proteinG,
                carbsG: Self.toDouble(targetDict["carbs_g"]) != 0
                    ? Self.toDouble(targetDict["carbs_g"])
                    : defaults.carbsG,
                fatG: Self.toDouble(targetDict["fat_g"]) != 0
                    ? Self.toDouble(targetDict["fat_g"])
                    : defaults.fatG
            ),
            units: units,
            heightCM: heightCM,
            weightKG: weightKG,
            targetWeightKG: targetWeightKG
        )
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
            URLQueryItem(name: "select", value: "id,local_day,occurred_at,created_at,updated_at,status,status_message,title,raw_text,protein_g,carbs_g,fat_g,calories_kcal,image_path,error_message,processing_attempts"),
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "local_day", value: "eq.\(localDay)"),
            URLQueryItem(name: "order", value: "occurred_at.desc.nullslast,created_at.desc")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw ServiceError.networkError(underlying: error)
        }

        guard let http = resp as? HTTPURLResponse else {
            throw ServiceError.parseError(message: "Invalid response type")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.serverError(statusCode: http.statusCode, message: "Failed to fetch entries")
        }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ServiceError.parseError(message: "Invalid JSON response")
        }

        let parsed = arr.compactMap(parseEntry)
        let imageURLs: [URL?] = await Self.boundedConcurrentMap(
            parsed.map(\.imagePath),
            maximumConcurrentTasks: Self.signedImageConcurrencyLimit
        ) { path in
            guard let path else { return nil }
            return await signImageURL(path: path, jwt: jwt)
        }

        return zip(parsed, imageURLs).map { parsedEntry, imageURL in
            var entry = parsedEntry.entry
            entry.imageURL = imageURL
            return entry
        }
    }

    func fetchEntry(id: UUID) async throws -> Entry? {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        var comps = URLComponents(url: supabaseUrl.appendingPathComponent("/rest/v1/entries"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "select", value: "id,local_day,occurred_at,created_at,updated_at,status,status_message,title,raw_text,protein_g,carbs_g,fat_g,calories_kcal,image_path,error_message,processing_attempts"),
            URLQueryItem(name: "id", value: "eq.\(id.uuidString)"),
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "limit", value: "1")
        ]
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "GET"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.serverError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1,
                message: "Failed to refresh meal status"
            )
        }
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let object = objects.first,
              var parsed = parseEntry(object) else { return nil }
        if let imagePath = parsed.imagePath {
            parsed.entry.imageURL = await signImageURL(path: imagePath, jwt: jwt)
        }
        return parsed.entry
    }

    private func parseEntry(_ object: [String: Any]) -> ParsedEntry? {
        guard let idString = object["id"] as? String,
              let id = UUID(uuidString: idString) else { return nil }

        let rawText = object["raw_text"] as? String
        let serverTitle = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSummary = rawText?.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = [serverTitle, rawSummary]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? "Meal"
        let status = (object["status"] as? String).flatMap(EntryStatus.init(rawValue:)) ?? .complete
        let createdAt = Self.parseDate(object["occurred_at"])
            ?? Self.parseDate(object["created_at"])
            ?? Date()

        let imagePath = status == .complete
            ? (object["image_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        return ParsedEntry(
            entry: Entry(
                id: id,
                createdAt: createdAt,
                summary: summary,
                imageURL: nil,
                proteinG: Self.toDouble(object["protein_g"]),
                carbsG: Self.toDouble(object["carbs_g"]),
                fatG: Self.toDouble(object["fat_g"]),
                caloriesKcal: Self.toDouble(object["calories_kcal"]),
                localDay: object["local_day"] as? String,
                status: status,
                statusMessage: object["status_message"] as? String,
                errorMessage: object["error_message"] as? String,
                statusUpdatedAt: Self.parseDate(object["updated_at"]),
                processingAttempts: Int(Self.toDouble(object["processing_attempts"]))
            ),
            imagePath: imagePath?.isEmpty == false ? imagePath : nil
        )
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
                let base = supabaseUrl.appendingPathComponent("storage/v1")
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

    // MARK: - Entry detail fetch
    struct EntryDetailItem {
        let name: String
        let amount: String
        let proteinG: Double
        let carbsG: Double
        let fatG: Double
        let caloriesKcal: Double
    }

    struct EntryDetail {
        let createdAt: Date
        let imageURL: URL?
        let title: String
        let rawText: String?
        let transcript: String?
        let proteinG: Double
        let carbsG: Double
        let fatG: Double
        let caloriesKcal: Double
        let items: [EntryDetailItem]
        let analysisNotes: String?
        let confidence: Double?
    }

    func fetchEntryDetail(id: UUID) async throws -> EntryDetail? {
        let jwt = try await currentJWT()
        var comps = URLComponents(url: supabaseUrl.appendingPathComponent("/rest/v1/entries"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "select", value: "occurred_at,created_at,title,raw_text,transcript,image_path,protein_g,carbs_g,fat_g,calories_kcal,items,analysis_notes,confidence"),
            URLQueryItem(name: "id", value: "eq.\(id.uuidString)")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw ServiceError.networkError(underlying: error)
        }

        guard let http = resp as? HTTPURLResponse else {
            throw ServiceError.parseError(message: "Invalid response type")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.serverError(statusCode: http.statusCode, message: "Failed to fetch entry detail")
        }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ServiceError.parseError(message: "Invalid JSON response")
        }
        guard let obj = arr.first else { return nil } // Entry not found is valid

        let createdAt = Self.parseDate(obj["occurred_at"])
            ?? Self.parseDate(obj["created_at"])
            ?? Date()
        let rawText = obj["raw_text"] as? String
        let transcript = obj["transcript"] as? String
        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (title?.isEmpty == false ? title : nil)
            ?? rawText?.components(separatedBy: "\n").first
            ?? "Meal"
        var imageURL: URL? = nil
        if let path = obj["image_path"] as? String { imageURL = await signImageURL(path: path, jwt: jwt) }

        let itemObjects = obj["items"] as? [[String: Any]] ?? []
        let items = itemObjects.compactMap { item -> EntryDetailItem? in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            return EntryDetailItem(
                name: name,
                amount: item["amount"] as? String ?? "",
                proteinG: Self.toDouble(item["protein_g"]),
                carbsG: Self.toDouble(item["carbs_g"]),
                fatG: Self.toDouble(item["fat_g"]),
                caloriesKcal: Self.toDouble(item["calories_kcal"])
            )
        }

        return EntryDetail(
            createdAt: createdAt,
            imageURL: imageURL,
            title: resolvedTitle,
            rawText: rawText,
            transcript: transcript,
            proteinG: Self.toDouble(obj["protein_g"]),
            carbsG: Self.toDouble(obj["carbs_g"]),
            fatG: Self.toDouble(obj["fat_g"]),
            caloriesKcal: Self.toDouble(obj["calories_kcal"]),
            items: items,
            analysisNotes: obj["analysis_notes"] as? String,
            confidence: obj["confidence"].map(Self.toDouble)
        )
    }
}
