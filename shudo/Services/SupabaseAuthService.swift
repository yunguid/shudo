import Foundation
import CryptoKit
import Security

// AppConfig defined in AppConfig.swift

protocol AccountDeletionServicing {
    func deleteAccount(accessToken: String) async throws
}

struct SupabaseAuthService: AccountDeletionServicing {
    static let passwordRecoveryRedirectURL = URL(
        string: "https://shudo.yng.sh/reset-password"
    )!
    static let emailConfirmationRedirectURL = URL(
        string: "https://shudo.yng.sh/auth/confirm"
    )!
    static let oauthCallbackURL = URL(string: "shudo://auth/callback")!

    enum OAuthProvider: String, CaseIterable, Hashable, Sendable {
        case apple
        case google
    }

    struct OAuthFlow: Equatable {
        let provider: OAuthProvider
        let authorizationURL: URL
        let codeVerifier: String
    }

    enum OAuthProviderDiscoveryError: LocalizedError, Equatable {
        case invalidResponse
        case httpStatus(Int)
        case invalidPayload
        case unavailable

        var errorDescription: String? {
            "Social sign-in options couldn’t load."
        }
    }

    private struct AuthSettingsPayload: Decodable {
        struct External: Decodable {
            let apple: Bool?
            let google: Bool?
        }

        let external: External
    }

    enum SignUpOutcome: Equatable {
        case signedIn(Session)
        case confirmationRequired
    }

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

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func signUp(
        email: String,
        password: String,
        redirectURL: URL = Self.emailConfirmationRedirectURL
    ) async throws -> SignUpOutcome {
        let request = try Self.makeSignUpRequest(
            email: email,
            password: password,
            redirectURL: redirectURL,
            baseURL: AppConfig.supabaseURL,
            apiKey: AppConfig.supabaseAnonKey
        )
        let json = try await performPublicRequest(request)
        if let session = session(from: json) {
            return .signedIn(session)
        }
        return .confirmationRequired
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
        let userId = Self.userId(fromTokenResponse: json, accessToken: accessToken)
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
        // The token response already carries the user; deriving the id locally
        // avoids a second network hop and, critically, means no request can
        // fail *after* the refresh token has rotated (which previously made a
        // transient network error consume the token and force a sign-out).
        let userId = Self.userId(fromTokenResponse: json, accessToken: accessToken)
        return Session(accessToken: accessToken, refreshToken: newRefresh, expiresAt: expiresAt, userId: userId)
    }

    /// GoTrue token responses embed the user record; the JWT `sub` claim is
    /// the fallback. Neither requires a network round trip.
    static func userId(fromTokenResponse json: [String: Any], accessToken: String) -> String? {
        if let user = json["user"] as? [String: Any],
           let id = user["id"] as? String,
           !id.isEmpty {
            return id
        }
        return AuthSessionManager.subject(fromJWT: accessToken)
    }

    func makeOAuthFlow(
        provider: OAuthProvider,
        redirectURL: URL = Self.oauthCallbackURL
    ) throws -> OAuthFlow {
        let verifier = try Self.makePKCEVerifier()
        return OAuthFlow(
            provider: provider,
            authorizationURL: try Self.makeOAuthAuthorizationURL(
                provider: provider,
                redirectURL: redirectURL,
                codeVerifier: verifier,
                baseURL: AppConfig.supabaseURL
            ),
            codeVerifier: verifier
        )
    }

    func fetchEnabledOAuthProviders() async throws -> [OAuthProvider] {
        let request = Self.makeOAuthProviderSettingsRequest(
            baseURL: AppConfig.supabaseURL,
            apiKey: AppConfig.supabaseAnonKey
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw OAuthProviderDiscoveryError.unavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw OAuthProviderDiscoveryError.invalidResponse
        }
        return try Self.parseEnabledOAuthProviders(data, statusCode: http.statusCode)
    }

    static func makeOAuthProviderSettingsRequest(baseURL: URL, apiKey: String) -> URLRequest {
        let url = baseURL
            .appendingPathComponent("auth")
            .appendingPathComponent("v1")
            .appendingPathComponent("settings")
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        return request
    }

    static func parseEnabledOAuthProviders(
        _ data: Data,
        statusCode: Int = 200
    ) throws -> [OAuthProvider] {
        guard (200..<300).contains(statusCode) else {
            throw OAuthProviderDiscoveryError.httpStatus(statusCode)
        }
        let payload: AuthSettingsPayload
        do {
            payload = try JSONDecoder().decode(AuthSettingsPayload.self, from: data)
        } catch {
            throw OAuthProviderDiscoveryError.invalidPayload
        }
        return OAuthProvider.allCases.filter { provider in
            switch provider {
            case .apple: return payload.external.apple == true
            case .google: return payload.external.google == true
            }
        }
    }

    func exchangeOAuthCallback(
        _ callbackURL: URL,
        codeVerifier: String
    ) async throws -> Session {
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        if let providerError = components?.queryItems?.first(where: { $0.name == "error_description" })?.value
            ?? components?.queryItems?.first(where: { $0.name == "error" })?.value {
            throw FriendlyAuthError(
                httpStatus: 400,
                supabaseErrorCode: "oauth_callback_error",
                serverMessage: providerError,
                friendlyMessage: "Couldn’t finish social sign-in. Please try again."
            )
        }
        guard callbackURL.scheme?.lowercased() == Self.oauthCallbackURL.scheme,
              callbackURL.host?.lowercased() == Self.oauthCallbackURL.host,
              callbackURL.path == Self.oauthCallbackURL.path,
              let code = components?.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else {
            throw FriendlyAuthError(
                httpStatus: 400,
                supabaseErrorCode: "invalid_oauth_callback",
                serverMessage: nil,
                friendlyMessage: "The social sign-in callback was invalid. Please try again."
            )
        }
        let json = try await makeRequest(
            path: "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "pkce")],
            body: ["auth_code": code, "code_verifier": codeVerifier]
        )
        guard let session = session(from: json) else {
            throw FriendlyAuthError(
                httpStatus: 502,
                supabaseErrorCode: "missing_oauth_session",
                serverMessage: nil,
                friendlyMessage: "Social sign-in did not return a session. Please try again."
            )
        }
        return session
    }

    func deleteAccount(accessToken: String) async throws {
        let request = try Self.makeDeleteAccountRequest(
            accessToken: accessToken,
            baseURL: AppConfig.supabaseURL,
            apiKey: AppConfig.supabaseAnonKey
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let serverMessage = object?["error"] as? String
            throw FriendlyAuthError(
                httpStatus: status,
                supabaseErrorCode: "account_deletion_failed",
                serverMessage: serverMessage,
                friendlyMessage: serverMessage ?? "Couldn’t delete your account. Please try again."
            )
        }
    }

    func requestPasswordRecovery(
        email: String,
        redirectURL: URL = Self.passwordRecoveryRedirectURL
    ) async throws {
        do {
            _ = try await makeRequest(
                path: "/auth/v1/recover",
                query: [URLQueryItem(name: "redirect_to", value: redirectURL.absoluteString)],
                body: ["email": email]
            )
        } catch let error as FriendlyAuthError where Self.masksRecoveryLookupFailure(error) {
            // Recovery must not reveal whether a particular email is registered.
            return
        }
    }

    func resendSignUpConfirmation(
        email: String,
        redirectURL: URL = Self.emailConfirmationRedirectURL
    ) async throws {
        let request = try Self.makeSignUpConfirmationRequest(
            email: email,
            redirectURL: redirectURL,
            baseURL: AppConfig.supabaseURL,
            apiKey: AppConfig.supabaseAnonKey
        )
        _ = try await performPublicRequest(request)
    }

    static func makePasswordRecoveryRequest(
        email: String,
        redirectURL: URL,
        baseURL: URL,
        apiKey: String
    ) throws -> URLRequest {
        try makePublicPOSTRequest(
            path: "/auth/v1/recover",
            query: [URLQueryItem(name: "redirect_to", value: redirectURL.absoluteString)],
            body: ["email": email],
            baseURL: baseURL,
            apiKey: apiKey
        )
    }

    static func makeSignUpRequest(
        email: String,
        password: String,
        redirectURL: URL,
        baseURL: URL,
        apiKey: String
    ) throws -> URLRequest {
        try makePublicPOSTRequest(
            path: "/auth/v1/signup",
            query: [URLQueryItem(name: "redirect_to", value: redirectURL.absoluteString)],
            body: ["email": email, "password": password],
            baseURL: baseURL,
            apiKey: apiKey
        )
    }

    static func makeSignUpConfirmationRequest(
        email: String,
        redirectURL: URL,
        baseURL: URL,
        apiKey: String
    ) throws -> URLRequest {
        try makePublicPOSTRequest(
            path: "/auth/v1/resend",
            query: [URLQueryItem(name: "redirect_to", value: redirectURL.absoluteString)],
            body: ["type": "signup", "email": email],
            baseURL: baseURL,
            apiKey: apiKey
        )
    }

    static func isEmailNotConfirmed(_ error: FriendlyAuthError) -> Bool {
        let code = (error.supabaseErrorCode ?? "").lowercased()
        let message = (error.serverMessage ?? "").lowercased()
        return code.contains("email_not_confirmed") || message.contains("email not confirmed")
    }

    static func makeDeleteAccountRequest(
        accessToken: String,
        baseURL: URL,
        apiKey: String
    ) throws -> URLRequest {
        let url = baseURL
            .appendingPathComponent("functions")
            .appendingPathComponent("v1")
            .appendingPathComponent("delete_account")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["confirmation": "DELETE"])
        return request
    }

    static func makeOAuthAuthorizationURL(
        provider: OAuthProvider,
        redirectURL: URL,
        codeVerifier: String,
        baseURL: URL
    ) throws -> URL {
        guard codeVerifier.count >= 43,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw NSError(
                domain: "Auth",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid OAuth configuration"]
            )
        }
        components.path = "/auth/v1/authorize"
        components.queryItems = [
            URLQueryItem(name: "provider", value: provider.rawValue),
            URLQueryItem(name: "redirect_to", value: redirectURL.absoluteString),
            URLQueryItem(name: "code_challenge", value: pkceChallenge(for: codeVerifier)),
            URLQueryItem(name: "code_challenge_method", value: "s256")
        ]
        guard let url = components.url else {
            throw NSError(
                domain: "Auth",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid OAuth configuration"]
            )
        }
        return url
    }

    static func masksRecoveryLookupFailure(_ error: FriendlyAuthError) -> Bool {
        let code = (error.supabaseErrorCode ?? "").lowercased()
        let message = (error.serverMessage ?? "").lowercased()
        let lookupCodes: Set<String> = [
            "email_not_found",
            "user_not_found",
        ]
        return lookupCodes.contains(code)
            || message.contains("email not found")
            || message.contains("no user found")
            || message.contains("user not found")
    }

    private func makeRequest(path: String, query: [URLQueryItem]?, body: [String: Any]) async throws -> [String: Any] {
        let req = try Self.makePublicPOSTRequest(
            path: path,
            query: query,
            body: body,
            baseURL: AppConfig.supabaseURL,
            apiKey: AppConfig.supabaseAnonKey
        )
        return try await performPublicRequest(req)
    }

    private func performPublicRequest(_ req: URLRequest) async throws -> [String: Any] {
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

    private static func makePublicPOSTRequest(
        path: String,
        query: [URLQueryItem]?,
        body: [String: Any],
        baseURL: URL,
        apiKey: String
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw NSError(
                domain: "Auth",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL components"]
            )
        }
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        components.queryItems = query
        guard let url = components.url else {
            throw NSError(
                domain: "Auth",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid URL components"]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        configurePublicHeaders(on: &request, apiKey: apiKey)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Supabase publishable keys are gateway credentials, not JWTs. Public Auth
    /// requests carry them only in `apikey`; authenticated requests use the
    /// user's access token in `Authorization` separately.
    static func configurePublicHeaders(on request: inout URLRequest, apiKey: String) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "apikey")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
    }

    private static func makePKCEVerifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(
                domain: "Auth",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Could not start secure sign-in"]
            )
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func pkceChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    private func session(from json: [String: Any]) -> Session? {
        guard let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty,
              let refreshToken = json["refresh_token"] as? String,
              !refreshToken.isEmpty else { return nil }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return Session(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            userId: Self.userId(fromTokenResponse: json, accessToken: accessToken)
        )
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
        if code.contains("user_already_exists") || msg.contains("already registered") {
            return "An account already exists for this email."
        }
        if code.contains("weak_password") || msg.contains("password should") {
            return "Choose a stronger password with at least 10 characters."
        }
        if httpStatus == 429 || msg.contains("too many requests") {
            return "Too many attempts. Please try again in a few minutes."
        }
        if msg.isEmpty == false { return serverMessage! }
        return "Something went wrong. Please try again."
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
