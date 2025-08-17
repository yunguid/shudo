import Foundation

// AppConfig defined in AppConfig.swift

struct SupabaseAuthService {
    enum SignUpResult {
        case confirmationSent
    }
    struct Session: Codable, Equatable {
        let accessToken: String
        let refreshToken: String
        let tokenType: String
        let expiresIn: Int
        let expiresAt: Date
        let userId: String?
    }

    func signUp(email: String, password: String) async throws -> SignUpResult {
        _ = try await makeRequest(path: "/auth/v1/signup", query: nil, body: [
            "email": email,
            "password": password
        ])
        // If email confirmation is enabled, no session should be established here.
        return .confirmationSent
    }

    func signIn(email: String, password: String) async throws -> Session {
        let json = try await makeRequest(path: "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "password")], body: [
            "email": email,
            "password": password
        ])
        let accessToken = json["access_token"] as? String ?? ""
        let refreshToken = json["refresh_token"] as? String ?? ""
        let tokenType = json["token_type"] as? String ?? "bearer"
        let expiresIn = json["expires_in"] as? Int ?? 3600
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let userId = try await fetchUserId(accessToken: accessToken)
        return Session(accessToken: accessToken, refreshToken: refreshToken, tokenType: tokenType, expiresIn: expiresIn, expiresAt: expiresAt, userId: userId)
    }

    func refresh(refreshToken: String) async throws -> Session {
        let json = try await makeRequest(path: "/auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "refresh_token")], body: [
            "refresh_token": refreshToken
        ])
        let accessToken = json["access_token"] as? String ?? ""
        let newRefresh = json["refresh_token"] as? String ?? refreshToken
        let tokenType = json["token_type"] as? String ?? "bearer"
        let expiresIn = json["expires_in"] as? Int ?? 3600
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let userId = try await fetchUserId(accessToken: accessToken)
        return Session(accessToken: accessToken, refreshToken: newRefresh, tokenType: tokenType, expiresIn: expiresIn, expiresAt: expiresAt, userId: userId)
    }

    func signInWithApple(idToken: String, nonce: String?) async throws -> Session {
        let json = try await makeRequest(path: "/auth/v1/token", query: [
            URLQueryItem(name: "grant_type", value: "id_token"),
            URLQueryItem(name: "provider", value: "apple")
        ], body: [
            "id_token": idToken,
            "nonce": nonce ?? NSNull()
        ])
        let accessToken = json["access_token"] as? String ?? ""
        let refreshToken = json["refresh_token"] as? String ?? ""
        let tokenType = json["token_type"] as? String ?? "bearer"
        let expiresIn = json["expires_in"] as? Int ?? 3600
        let expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
        let userId = try await fetchUserId(accessToken: accessToken)
        return Session(accessToken: accessToken, refreshToken: refreshToken, tokenType: tokenType, expiresIn: expiresIn, expiresAt: expiresAt, userId: userId)
    }

    func resendSignUpConfirmation(email: String) async throws {
        _ = try await makeRequest(path: "/auth/v1/resend", query: nil, body: [
            "type": "signup",
            "email": email
        ])
    }

    private func makeRequest(path: String, query: [URLQueryItem]?, body: [String: Any]) async throws -> [String: Any] {
        var comps = URLComponents(url: AppConfig.supabaseURL, resolvingAgainstBaseURL: false)!
        comps.path = path.hasPrefix("/") ? path : "/\(path)"
        comps.queryItems = query
        guard let url = comps.url else { throw NSError(domain: "Auth", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid URL components"]) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(AppConfig.supabaseAnonKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let str = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Auth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: str])
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return obj
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
}


