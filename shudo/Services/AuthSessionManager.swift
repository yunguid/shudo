import Foundation
import Security

private actor SessionRefreshGate {
    typealias Session = SupabaseAuthService.Session
    private var inFlight: Task<Session, Error>?

    func run(_ operation: @escaping @Sendable () async throws -> Session) async throws -> Session {
        if let inFlight { return try await inFlight.value }

        let task = Task { try await operation() }
        inFlight = task
        do {
            let session = try await task.value
            inFlight = nil
            return session
        } catch {
            inFlight = nil
            throw error
        }
    }
}

final class AuthSessionManager: ObservableObject {
    struct PersistedSessionEnvelope: Codable, Equatable {
        let schemaVersion: Int
        let projectScope: String
        let session: SupabaseAuthService.Session
    }

    struct PersistedSessionResolution: Equatable {
        let session: SupabaseAuthService.Session
        let requiresRewrite: Bool
    }

    static let shared = AuthSessionManager()
    @Published private(set) var session: SupabaseAuthService.Session?
    var userId: String? {
        guard let session else { return nil }
        return session.userId ?? Self.subject(fromJWT: session.accessToken)
    }

    private let service = SupabaseAuthService()
    private let refreshGate = SessionRefreshGate()
    private let keychainKey = "shudo.supabase.session"
    private static let persistedSessionSchemaVersion = 1

    private init() { loadFromKeychain() }

    func signIn(email: String, password: String) async throws {
        let session = try await service.signIn(email: email, password: password)
        await apply(session)
    }

    @discardableResult
    func signUp(
        email: String,
        password: String
    ) async throws -> SupabaseAuthService.SignUpOutcome {
        let outcome = try await service.signUp(email: email, password: password)
        if case let .signedIn(session) = outcome {
            await apply(session)
        }
        return outcome
    }

    func completeOAuth(
        callbackURL: URL,
        codeVerifier: String
    ) async throws {
        let session = try await service.exchangeOAuthCallback(
            callbackURL,
            codeVerifier: codeVerifier
        )
        await apply(session)
    }

    /// Deletes the remote account first, then clears Keychain/local state only
    /// after the server confirms success. The protocol parameter keeps the
    /// destructive boundary deterministic in unit tests.
    func deleteAccount(
        using accountService: AccountDeletionServicing = SupabaseAuthService()
    ) async throws {
        let accessToken = try await getAccessToken()
        try await Self.completeAccountDeletion(
            accessToken: accessToken,
            using: accountService
        ) {
            await MainActor.run { self.signOut() }
        }
    }

    static func completeAccountDeletion(
        accessToken: String,
        using accountService: AccountDeletionServicing,
        clearLocalSession: () async -> Void
    ) async throws {
        try await accountService.deleteAccount(accessToken: accessToken)
        await clearLocalSession()
    }

    @MainActor
    func signOut() {
        session = nil
        deleteFromKeychain()
        ProfileCache.clearAll()
    }

    func getAccessToken() async throws -> String {
        guard let current = await MainActor.run(body: { self.session }) else {
            throw NSError(
                domain: "Auth",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Not authenticated"]
            )
        }
        if current.expiresAt.timeIntervalSinceNow > 300 { return current.accessToken }

        do {
            let refreshed = try await refreshGate.run { [service] in
                try await Self.refreshWithRetry(service: service, session: current)
            }
            guard await applyRefresh(refreshed, replacing: current) else {
                throw CancellationError()
            }
            return refreshed.accessToken
        } catch {
            if Self.isAuthenticationError(error) {
                await MainActor.run { self.signOut() }
                throw NSError(
                    domain: "Auth",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "Session expired. Please sign in again."]
                )
            }
            throw error
        }
    }

    func refreshIfNeeded() async {
        guard let current = await MainActor.run(body: { self.session }),
              current.expiresAt.timeIntervalSinceNow < 300 else { return }
        _ = try? await getAccessToken()
    }

    /// Returns whether a failed refresh proves that the persisted session can
    /// no longer be used. Keep this deliberately narrower than "any auth-ish
    /// error": transient transport/server failures must leave the local
    /// session intact so a later refresh can recover.
    static func isAuthenticationError(_ error: Error) -> Bool {
        if let friendly = error as? SupabaseAuthService.FriendlyAuthError {
            return friendlyAuthErrorInvalidatesSession(friendly)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return false }
        if [401, 403].contains(nsError.code) { return true }
        if nsError.code == 429 || (500...599).contains(nsError.code) { return false }

        return containsTerminalRefreshSignal(nsError.localizedDescription)
    }

    private static func friendlyAuthErrorInvalidatesSession(
        _ error: SupabaseAuthService.FriendlyAuthError
    ) -> Bool {
        // A rate limit or server failure is retryable even if its prose happens
        // to mention a token. GoTrue's terminal refresh failures are 4xx.
        guard (400..<500).contains(error.httpStatus), error.httpStatus != 429 else {
            return false
        }
        if [401, 403].contains(error.httpStatus) { return true }

        let code = error.supabaseErrorCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let terminalCodes: Set<String> = [
            // Legacy OAuth response shape.
            "invalid_grant",
            // Current GoTrue error-code response shapes.
            "refresh_token_already_used",
            "refresh_token_not_found",
            "session_expired",
            "session_not_found",
            "user_banned",
            "user_not_found",
        ]
        if let code, terminalCodes.contains(code) { return true }

        // Some GoTrue/proxy versions put OAuth's `invalid_grant` only in
        // `error_description`/`msg`. Inspect the original server text rather
        // than the friendly login copy, which intentionally hides that code.
        return containsTerminalRefreshSignal(error.serverMessage ?? "")
    }

    private static func containsTerminalRefreshSignal(_ value: String) -> Bool {
        let message = value.lowercased()
        let tokens = message.split { character in
            !(character.isLetter || character.isNumber || character == "_")
        }
        let terminalCodeTokens: Set<Substring> = [
            "invalid_grant",
            "refresh_token_already_used",
            "refresh_token_not_found",
            "session_expired",
            "session_not_found",
        ]
        if tokens.contains(where: terminalCodeTokens.contains) { return true }

        let terminalPhrases = [
            "invalid refresh token",
            "refresh token already used",
            "refresh token has already been used",
            "refresh token not found",
            "refresh token revoked",
            "refresh token has been revoked",
            "refresh token expired",
            "session expired",
            "session not found",
            // Preserve support for the legacy NSError emitted by older builds.
            "token expired",
        ]
        return terminalPhrases.contains { message.contains($0) }
    }

    static func subject(fromJWT token: String) -> String? {
        claims(fromJWT: token)?["sub"] as? String
    }

    static func projectScope(for url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return url.absoluteString.lowercased()
        }
        var scope = "\(scheme)://\(host)"
        if let port = url.port { scope += ":\(port)" }
        return scope
    }

    static func projectScope(fromJWT token: String) -> String? {
        guard let issuer = claims(fromJWT: token)?["iss"] as? String,
              let issuerURL = URL(string: issuer) else { return nil }
        return projectScope(for: issuerURL)
    }

    static func resolvePersistedSession(
        _ data: Data,
        currentProjectURL: URL
    ) -> PersistedSessionResolution? {
        let currentScope = projectScope(for: currentProjectURL)
        let decoder = JSONDecoder()

        if let envelope = try? decoder.decode(PersistedSessionEnvelope.self, from: data) {
            guard envelope.schemaVersion == persistedSessionSchemaVersion,
                  envelope.projectScope == currentScope,
                  projectScope(fromJWT: envelope.session.accessToken) == currentScope else {
                return nil
            }
            return PersistedSessionResolution(
                session: envelope.session,
                requiresRewrite: false
            )
        }

        // Legacy builds stored the bare session with no project identity. Keep
        // it only when its access-token issuer proves that it belongs to the
        // currently configured Supabase origin, then rewrite it immediately.
        guard let legacy = try? decoder.decode(SupabaseAuthService.Session.self, from: data),
              projectScope(fromJWT: legacy.accessToken) == currentScope else {
            return nil
        }
        return PersistedSessionResolution(session: legacy, requiresRewrite: true)
    }

    static func canApplyRefresh(
        current: SupabaseAuthService.Session?,
        expected: SupabaseAuthService.Session,
        refreshed: SupabaseAuthService.Session
    ) -> Bool {
        current == expected || current == refreshed
    }

    private static func claims(fromJWT token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count > 1 else { return nil }
        var value = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder > 0 { value += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func refreshWithRetry(
        service: SupabaseAuthService,
        session: SupabaseAuthService.Session,
        maxRetries: Int = 4
    ) async throws -> SupabaseAuthService.Session {
        var lastError: Error?
        var delay: UInt64 = 750_000_000

        for attempt in 0..<maxRetries {
            do {
                return try await service.refresh(refreshToken: session.refreshToken)
            } catch {
                lastError = error
                if isAuthenticationError(error) { throw error }
                if attempt < maxRetries - 1 {
                    try await Task.sleep(nanoseconds: delay)
                    delay = min(delay * 2, 4_000_000_000)
                }
            }
        }
        throw lastError ?? NSError(
            domain: "Auth",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Network error. Please check your connection."]
        )
    }

    private func apply(_ session: SupabaseAuthService.Session) async {
        await MainActor.run {
            self.session = session
            self.saveToKeychain(session)
        }
    }

    private func applyRefresh(
        _ refreshed: SupabaseAuthService.Session,
        replacing expected: SupabaseAuthService.Session
    ) async -> Bool {
        await MainActor.run {
            guard Self.canApplyRefresh(
                current: self.session,
                expected: expected,
                refreshed: refreshed
            ) else { return false }
            self.session = refreshed
            self.saveToKeychain(refreshed)
            return true
        }
    }

    private var baseKeychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainKey
        ]
    }

    private func saveToKeychain(_ session: SupabaseAuthService.Session) {
        let envelope = PersistedSessionEnvelope(
            schemaVersion: Self.persistedSessionSchemaVersion,
            projectScope: Self.projectScope(for: AppConfig.supabaseURL),
            session: session
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(baseKeychainQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseKeychainQuery
            attributes.forEach { addQuery[$0.key] = $0.value }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("Keychain add failed: \(addStatus)")
            }
        } else if updateStatus != errSecSuccess {
            print("Keychain update failed: \(updateStatus)")
        }
    }

    private func loadFromKeychain() {
        var query = baseKeychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data else { return }
        guard let restored = Self.resolvePersistedSession(
            data,
            currentProjectURL: AppConfig.supabaseURL
        ) else {
            deleteFromKeychain()
            return
        }
        session = restored.session
        if restored.requiresRewrite { saveToKeychain(restored.session) }
    }

    private func deleteFromKeychain() {
        let status = SecItemDelete(baseKeychainQuery as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            print("Keychain delete failed: \(status)")
        }
    }
}
