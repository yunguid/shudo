import Foundation

struct SupabaseService: Sendable, WeeklySummaryProviding {
    static let signedImageConcurrencyLimit = 4
    static let maximumProfilePhotoBytes = 2_097_152
    static let entryListColumns = "id,local_day,occurred_at,created_at,updated_at,status,status_message,analysis_preview,title,raw_text,protein_g,carbs_g,fat_g,calories_kcal,image_path,error_message,processing_attempts"

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
        let activityLevel = (obj["activity_level"] as? String)
            .flatMap(ProfileActivityLevel.init(rawValue:))
        let goalType = (obj["goal_type"] as? String)
            .flatMap(NutritionGoalType.init(rawValue:)) ?? .maintain

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
            targetWeightKG: targetWeightKG,
            displayName: obj["display_name"] as? String,
            activityLevel: activityLevel,
            goalType: goalType,
            goalNotes: obj["goal_notes"] as? String,
            onboardingStatus: (obj["onboarding_status"] as? String)
                .flatMap(OnboardingStatus.init(rawValue:)),
            onboardingCompletedAt: Self.parseDate(obj["onboarding_completed_at"]),
            avatarPath: obj["avatar_path"] as? String
        )
    }

    static func profilePhotoPath(userId: String, fileId: UUID = UUID()) throws -> String {
        guard UUID(uuidString: userId)?.uuidString.lowercased() == userId.lowercased() else {
            throw ServiceError.parseError(message: "Invalid profile photo owner")
        }
        return "\(userId.lowercased())/\(fileId.uuidString.lowercased()).jpg"
    }

    static func profilePhotoDataIsJPEG(_ data: Data) -> Bool {
        data.count >= 4
            && data.starts(with: [0xFF, 0xD8])
            && data.suffix(2).elementsEqual([0xFF, 0xD9])
    }

    func uploadProfilePhoto(_ jpegData: Data, replacing oldPath: String?) async throws -> Profile {
        guard jpegData.count <= Self.maximumProfilePhotoBytes,
              Self.profilePhotoDataIsJPEG(jpegData) else {
            throw ServiceError.parseError(message: "Profile photo must be a JPEG under 2 MB")
        }
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        let newPath = try Self.profilePhotoPath(userId: userId)
        var request = URLRequest(url: storageObjectURL(operation: "object", path: newPath))
        request.httpMethod = "POST"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        request.httpBody = jpegData
        try await performProfilePhotoRequest(request, failureMessage: "Couldn’t upload profile photo")

        do {
            let updated = try await setAvatarPath(newPath, jwt: jwt, userId: userId)
            if let oldPath, oldPath != newPath {
                try? await deleteProfilePhotoObject(path: oldPath, jwt: jwt, userId: userId)
            }
            return updated
        } catch {
            try? await deleteProfilePhotoObject(path: newPath, jwt: jwt, userId: userId)
            throw error
        }
    }

    func removeProfilePhoto(path: String) async throws -> Profile {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        guard Self.profilePhotoPathBelongsToUser(path, userId: userId) else {
            throw ServiceError.parseError(message: "Invalid profile photo path")
        }
        let updated = try await setAvatarPath(nil, jwt: jwt, userId: userId)
        try? await deleteProfilePhotoObject(path: path, jwt: jwt, userId: userId)
        return updated
    }

    func fetchProfilePhoto(path: String) async throws -> Data {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        guard Self.profilePhotoPathBelongsToUser(path, userId: userId) else {
            throw ServiceError.parseError(message: "Invalid profile photo path")
        }
        var request = URLRequest(
            url: storageObjectURL(operation: "object/authenticated", path: path)
        )
        request.httpMethod = "GET"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.parseError(message: "Invalid response type")
        }
        guard (200..<300).contains(http.statusCode),
              data.count <= Self.maximumProfilePhotoBytes,
              Self.profilePhotoDataIsJPEG(data) else {
            throw ServiceError.serverError(
                statusCode: http.statusCode,
                message: "Couldn’t load profile photo"
            )
        }
        return data
    }

    static func profilePhotoPathBelongsToUser(_ path: String, userId: String) -> Bool {
        guard UUID(uuidString: userId) != nil else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].lowercased() == userId.lowercased(),
              parts[1].hasSuffix(".jpg") else { return false }
        return UUID(uuidString: String(parts[1].dropLast(4))) != nil
    }

    private func setAvatarPath(_ path: String?, jwt: String, userId: String) async throws -> Profile {
        var components = URLComponents(
            url: supabaseUrl.appendingPathComponent("/rest/v1/profiles"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "user_id", value: "eq.\(userId)")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        let avatarValue: Any
        if let path {
            avatarValue = path
        } else {
            avatarValue = NSNull()
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "avatar_path": avatarValue
        ])
        try await performProfilePhotoRequest(request, failureMessage: "Couldn’t save profile photo")
        guard let profile = try await fetchProfile(userId: userId) else {
            throw ServiceError.parseError(message: "Updated profile was missing")
        }
        return profile
    }

    private func deleteProfilePhotoObject(path: String, jwt: String, userId: String) async throws {
        guard Self.profilePhotoPathBelongsToUser(path, userId: userId) else { return }
        var request = URLRequest(url: storageObjectURL(operation: "object", path: path))
        request.httpMethod = "DELETE"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        try await performProfilePhotoRequest(request, failureMessage: "Couldn’t remove profile photo")
    }

    private func storageObjectURL(operation: String, path: String) -> URL {
        operation.split(separator: "/").reduce(
            supabaseUrl.appendingPathComponent("storage/v1")
        ) { url, component in
            url.appendingPathComponent(String(component))
        }
        .appendingPathComponent("profile-photos")
        .appendingPathComponent(path)
    }

    private func performProfilePhotoRequest(
        _ request: URLRequest,
        failureMessage: String
    ) async throws {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.parseError(message: "Invalid response type")
        }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let serverMessage = object?["message"] as? String
            throw ServiceError.serverError(
                statusCode: http.statusCode,
                message: serverMessage ?? failureMessage
            )
        }
    }

    static func profileUpdatePayload(_ update: ProfileSettingsUpdate) throws -> [String: Any] {
        func optionalNumber(
            _ value: Double?,
            label: String,
            range: ClosedRange<Double>
        ) throws -> Any {
            guard let value else { return NSNull() }
            guard value.isFinite, range.contains(value) else {
                throw ServiceError.parseError(message: "\(label) is outside the supported range")
            }
            return value
        }

        func optionalText(_ value: String?) -> Any {
            guard let value, !value.isEmpty else { return NSNull() }
            return value
        }

        let displayName = update.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let goalNotes = update.goalNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let timezone = update.timezone?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (displayName?.count ?? 0) <= 80 else {
            throw ServiceError.parseError(message: "Display name is too long")
        }
        guard (goalNotes?.count ?? 0) <= 2_000 else {
            throw ServiceError.parseError(message: "Goal description is too long")
        }

        var payload: [String: Any] = [
            "display_name": optionalText(displayName),
            "height_cm": try optionalNumber(update.heightCM, label: "Height", range: 50...275),
            "weight_kg": try optionalNumber(update.weightKG, label: "Weight", range: 20...500),
            "target_weight_kg": try optionalNumber(
                update.targetWeightKG,
                label: "Target weight",
                range: 20...500
            ),
            "activity_level": optionalText(update.activityLevel?.rawValue),
            "goal_type": update.goalType.rawValue,
            "goal_notes": optionalText(goalNotes)
        ]
        if let timezone {
            guard TimeZone(identifier: timezone) != nil else {
                throw ServiceError.parseError(message: "Choose a valid timezone")
            }
            payload["timezone"] = timezone
        }
        if let units = update.units {
            guard units == "imperial" || units == "metric" else {
                throw ServiceError.parseError(message: "Choose metric or imperial units")
            }
            payload["units"] = units
        }
        if let target = update.dailyMacroTarget {
            guard target.caloriesKcal.isFinite,
                  (500...10_000).contains(target.caloriesKcal),
                  target.proteinG.isFinite,
                  (0...1_000).contains(target.proteinG),
                  target.carbsG.isFinite,
                  (0...1_500).contains(target.carbsG),
                  target.fatG.isFinite,
                  (0...1_000).contains(target.fatG) else {
                throw ServiceError.parseError(message: "Daily targets are outside the supported range")
            }
            payload["daily_macro_target"] = [
                "calories_kcal": target.caloriesKcal,
                "protein_g": target.proteinG,
                "carbs_g": target.carbsG,
                "fat_g": target.fatG
            ]
        }
        return payload
    }

    func updateProfile(_ update: ProfileSettingsUpdate) async throws -> Profile {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        var components = URLComponents(
            url: supabaseUrl.appendingPathComponent("/rest/v1/profiles"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "user_id", value: "eq.\(userId)")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.profileUpdatePayload(update)
        )

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.parseError(message: "Invalid response type")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.serverError(
                statusCode: http.statusCode,
                message: "Couldn’t save profile settings"
            )
        }
        guard let profile = try await fetchProfile(userId: userId) else {
            throw ServiceError.parseError(message: "Updated profile was missing")
        }
        return profile
    }

    func updateDailyMacroTarget(_ target: MacroTarget) async throws -> Profile {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        var components = URLComponents(
            url: supabaseUrl.appendingPathComponent("/rest/v1/profiles"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "user_id", value: "eq.\(userId)")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "daily_macro_target": [
                "calories_kcal": target.caloriesKcal,
                "protein_g": target.proteinG,
                "carbs_g": target.carbsG,
                "fat_g": target.fatG
            ]
        ])

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.parseError(message: "Invalid response type")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.serverError(
                statusCode: http.statusCode,
                message: "Couldn’t save daily targets"
            )
        }
        guard let updated = try await fetchProfile(userId: userId) else {
            throw ServiceError.parseError(message: "Updated profile was missing")
        }
        return updated
    }

    func fetchDailyNutritionTotals(
        timezone: String,
        dayCount: Int = NutritionProgressPolicy.heatmapDayCount
    ) async throws -> [DailyNutritionTotal] {
        guard dayCount > 0 else { return [] }
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .autoupdatingCurrent
        let startDate = calendar.date(
            byAdding: .day,
            value: -(dayCount - 1),
            to: calendar.startOfDay(for: Date())
        ) ?? Date()
        let firstLocalDay = localDayString(for: startDate, timezone: timezone)

        var components = URLComponents(
            url: supabaseUrl.appendingPathComponent("/rest/v1/daily_totals"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "select",
                value: "local_day,protein_g,carbs_g,fat_g,calories_kcal,entry_count"
            ),
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "local_day", value: "gte.\(firstLocalDay)"),
            URLQueryItem(name: "order", value: "local_day.asc")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.parseError(message: "Invalid response type")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.serverError(
                statusCode: http.statusCode,
                message: "Couldn’t load adherence history"
            )
        }
        return try Self.parseDailyNutritionTotals(data)
    }

    static func parseDailyNutritionTotals(_ data: Data) throws -> [DailyNutritionTotal] {
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ServiceError.parseError(message: "Invalid daily totals response")
        }
        return objects.compactMap { object in
            guard let localDay = object["local_day"] as? String, !localDay.isEmpty else {
                return nil
            }
            return DailyNutritionTotal(
                localDay: localDay,
                proteinG: toDouble(object["protein_g"]),
                carbsG: toDouble(object["carbs_g"]),
                fatG: toDouble(object["fat_g"]),
                caloriesKcal: toDouble(object["calories_kcal"]),
                entryCount: Int(toDouble(object["entry_count"]))
            )
        }
    }

    func fetchDailyMacroTargetHistory() async throws -> [DailyMacroTargetSnapshot] {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        var components = URLComponents(
            url: supabaseUrl.appendingPathComponent("/rest/v1/daily_targets"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "select",
                value: "target_day,calories_kcal,protein_g,carbs_g,fat_g"
            ),
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "order", value: "target_day.asc")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.parseError(message: "Invalid response type")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.serverError(
                statusCode: http.statusCode,
                message: "Couldn’t load target history"
            )
        }
        return try Self.parseDailyMacroTargetHistory(data)
    }

    static func parseDailyMacroTargetHistory(_ data: Data) throws -> [DailyMacroTargetSnapshot] {
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ServiceError.parseError(message: "Invalid target history response")
        }
        return objects.compactMap { object in
            guard let targetDay = object["target_day"] as? String,
                  targetDay.count == 10 else { return nil }
            let target = MacroTarget(
                caloriesKcal: toDouble(object["calories_kcal"]),
                proteinG: toDouble(object["protein_g"]),
                carbsG: toDouble(object["carbs_g"]),
                fatG: toDouble(object["fat_g"])
            )
            guard target.caloriesKcal > 0,
                  target.proteinG >= 0,
                  target.carbsG >= 0,
                  target.fatG >= 0 else { return nil }
            return DailyMacroTargetSnapshot(targetDay: targetDay, target: target)
        }
        .sorted { $0.targetDay < $1.targetDay }
    }

    func fetchLatestWeeklySummary() async throws -> WeeklyInsightSummary? {
        let jwt = try await currentJWT()
        let userId = try currentUserId()
        var components = URLComponents(
            url: supabaseUrl.appendingPathComponent("/rest/v1/weekly_summaries"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "select",
                value: "week_start,week_end,headline,narrative,repeated_foods,patterns,suggestions"
            ),
            URLQueryItem(name: "user_id", value: "eq.\(userId)"),
            URLQueryItem(name: "status", value: "eq.complete"),
            URLQueryItem(name: "order", value: "week_start.desc"),
            URLQueryItem(name: "limit", value: "1")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ServiceError.networkError(underlying: error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.parseError(message: "Invalid response type")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.serverError(
                statusCode: http.statusCode,
                message: "Couldn’t load weekly insights"
            )
        }
        return try Self.parseWeeklySummary(data)
    }

    static func parseWeeklySummary(_ data: Data) throws -> WeeklyInsightSummary? {
        guard let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ServiceError.parseError(message: "Invalid weekly summary response")
        }
        guard let object = objects.first else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let startText = object["week_start"] as? String,
              let endText = object["week_end"] as? String,
              let weekStart = formatter.date(from: startText),
              let weekEnd = formatter.date(from: endText) else {
            throw ServiceError.parseError(message: "Weekly summary dates were invalid")
        }
        let repeatedFoods: [WeeklyRepeatedFood] =
            (object["repeated_foods"] as? [[String: Any]] ?? []).compactMap { item in
            guard let name = item["name"] as? String, !name.isEmpty else { return nil }
            let count = Int(Self.toDouble(item["count"]))
            guard count > 0 else { return nil }
            return WeeklyRepeatedFood(name: name, count: count)
            }
        return WeeklyInsightSummary(
            weekStart: weekStart,
            weekEnd: weekEnd,
            headline: object["headline"] as? String ?? "",
            narrative: object["narrative"] as? String ?? "",
            repeatedFoods: repeatedFoods,
            patterns: object["patterns"] as? [String] ?? [],
            suggestions: object["suggestions"] as? [String] ?? []
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
            URLQueryItem(name: "select", value: Self.entryListColumns),
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
            URLQueryItem(name: "select", value: Self.entryListColumns),
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
                processingAttempts: Int(Self.toDouble(object["processing_attempts"])),
                analysisPreview: object["analysis_preview"] as? String
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
