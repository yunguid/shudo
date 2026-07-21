import Foundation

// AppConfig defined in AppConfig.swift

struct SupabaseAuthService {
    struct FriendlyAuthError: LocalizedError {
        let httpStatus: Int
        let supabaseErrorCode: String?
        let serverMessage: String?
        let friendlyMessage: String
        var errorDescription: String? { friendlyMessage }
    }
    struct Session: Codable, Equatable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date
        let userId: String?
    }

    func signIn(email: String, password: String) async throws -> Session {
        let json = try await makeRequest(path: "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "password")], body: [
            "email": email,
            "password": password
        ])
        let accessToken = json["access_token"] as? String ?? ""
        let refreshToken = json["refresh_token"] as? String ?? ""
        let expiresIn = json["expires_in"] as? Int ?? 3600
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let userId = try await fetchUserId(accessToken: accessToken)
        return Session(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, userId: userId)
    }

    func refresh(refreshToken: String) async throws -> Session {
        let json = try await makeRequest(path: "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")], body: [
            "refresh_token": refreshToken
        ])
        let accessToken = json["access_token"] as? String ?? ""
        let newRefresh = json["refresh_token"] as? String ?? refreshToken
        let expiresIn = json["expires_in"] as? Int ?? 3600
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let userId = try await fetchUserId(accessToken: accessToken)
        return Session(accessToken: accessToken, refreshToken: newRefresh, expiresAt: expiresAt, userId: userId)
    }

    private func makeRequest(path: String, query: [URLQueryItem]?, body: [String: Any]) async throws -> [String: Any] {
        var comps = URLComponents(url: AppConfig.supabaseURL, resolvingAgainstBaseURL: false)!
        comps.path = path.hasPrefix("/") ? path : "/\(path)"
        comps.queryItems = query
        guard let url = comps.url else { throw NSError(domain: "Auth", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid URL components"]) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        Self.configurePublicHeaders(on: &req, apiKey: AppConfig.supabaseAnonKey)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var obj: [String: Any] = [:]
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { obj = json }
            let supaCode = (obj["error_code"] as? String) ?? (obj["error"] as? String)
            let rawMsg = (obj["msg"] as? String) ?? (obj["error_description"] as? String) ?? (obj["message"] as? String)
            let friendly = mapFriendlyMessage(httpStatus: http.statusCode, supabaseErrorCode: supaCode, serverMessage: rawMsg)
            throw FriendlyAuthError(httpStatus: http.statusCode, supabaseErrorCode: supaCode, serverMessage: rawMsg, friendlyMessage: friendly)
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return obj
    }

    /// Supabase publishable keys are gateway credentials, not JWTs. Public Auth
    /// requests carry them only in `apikey`; authenticated requests use the
    /// user's access token in `Authorization` separately.
    static func configurePublicHeaders(on request: inout URLRequest, apiKey: String) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
    }

    private func fetchUserId(accessToken: String) async throws -> String? {
        var req = URLRequest(url: AppConfig.supabaseURL.appendingPathComponent("/auth/v1/user"))
        req.httpMethod = "GET"
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = obj["id"] as? String { return id }
        return nil
    }

    private func mapFriendlyMessage(httpStatus: Int, supabaseErrorCode: String?, serverMessage: String?) -> String {
        let code = (supabaseErrorCode ?? "").lowercased()
        let msg = (serverMessage ?? "").lowercased()
        // Supabase common error codes/messages
        if code.contains("email_not_confirmed") || msg.contains("email not confirmed") {
            return "This account still needs email confirmation in Supabase."
        }
        if code.contains("invalid_grant") || code.contains("invalid_credentials") || msg.contains("invalid login") {
            return "Incorrect email or password."
        }
        if code.contains("user_not_found") || msg.contains("user not found") {
            return "No account found for this email."
        }
        if httpStatus == 429 || msg.contains("too many requests") {
            return "Too many attempts. Please try again in a few minutes."
        }
        if msg.isEmpty == false { return serverMessage! }
        return "Something went wrong. Please try again."
    }
}
