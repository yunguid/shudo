import Foundation

final class AuthSessionManager: ObservableObject {
    static let shared = AuthSessionManager()
    @Published private(set) var session: SupabaseAuthService.Session?
    var userId: String? { session?.userId }

    private let service = SupabaseAuthService()
    private let keychainKey = "shudo.supabase.session"

    private init() { loadFromKeychain() }

    func signIn(email: String, password: String) async throws {
        let s = try await service.signIn(email: email, password: password)
        await MainActor.run { self.session = s }
        saveToKeychain(s)
    }

    func signUp(email: String, password: String) async throws -> SupabaseAuthService.SignUpResult {
        let result = try await service.signUp(email: email, password: password)
        switch result {
        case .confirmationSent:
            return result
        case .didSignIn(let session):
            await MainActor.run { self.session = session }
            saveToKeychain(session)
            return result
        }
    }

    func signOut() {
        session = nil
        deleteFromKeychain()
    }

    func setSession(_ s: SupabaseAuthService.Session) {
        session = s
        saveToKeychain(s)
    }

    func getAccessToken() async throws -> String {
        // If token is valid for more than 5 minutes, use it
        if let s = session, s.expiresAt.timeIntervalSinceNow > 300 { return s.accessToken }

        // Try to refresh if we have a session
        if let s = session {
            return try await refreshWithRetry(session: s)
        }
        throw NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
    }

    /// Refresh token with exponential backoff retry for transient network errors.
    /// Only signs out on definitive auth failures (401/403), not network issues.
    private func refreshWithRetry(session s: SupabaseAuthService.Session, maxRetries: Int = 4) async throws -> String {
        var lastError: Error?
        var delay: UInt64 = 2_000_000_000 // Start at 2 seconds

        for attempt in 0..<maxRetries {
            do {
                let refreshed = try await service.refresh(refreshToken: s.refreshToken)
                await MainActor.run { self.session = refreshed }
                saveToKeychain(refreshed)
                return refreshed.accessToken
            } catch let error as NSError {
                lastError = error

                // Check if this is a definitive auth failure (not a network issue)
                if isAuthenticationError(error) {
                    // Token is definitely invalid - sign out
                    await MainActor.run { self.signOut() }
                    throw NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Session expired. Please sign in again."])
                }

                // Network or transient error - retry with backoff
                if attempt < maxRetries - 1 {
                    try? await Task.sleep(nanoseconds: delay)
                    delay *= 2 // Exponential backoff: 2s, 4s, 8s, 16s
                }
            }
        }

        // All retries exhausted but NOT a definitive auth failure
        // Keep the session - it might work when network recovers
        throw lastError ?? NSError(domain: "Auth", code: -2, userInfo: [NSLocalizedDescriptionKey: "Network error. Please check your connection."])
    }

    /// Determines if an error indicates the token is definitively invalid (vs network issues)
    private func isAuthenticationError(_ error: NSError) -> Bool {
        // Check for HTTP 401/403 status codes
        if error.domain == NSURLErrorDomain {
            // Network-level errors are NOT auth errors
            return false
        }

        // Check for auth-specific error codes from Supabase
        let authErrorCodes = [401, 403]
        if authErrorCodes.contains(error.code) {
            return true
        }

        // Check error message for auth-related keywords
        let message = error.localizedDescription.lowercased()
        let authKeywords = ["invalid_grant", "token expired", "invalid refresh token", "unauthorized", "forbidden"]
        return authKeywords.contains { message.contains($0) }
    }
    
    /// Call on app foreground to proactively refresh token if needed
    func refreshIfNeeded() async {
        guard let s = session else { return }
        // Refresh if token expires within 10 minutes
        guard s.expiresAt.timeIntervalSinceNow < 600 else { return }
        do {
            let refreshed = try await service.refresh(refreshToken: s.refreshToken)
            await MainActor.run { self.session = refreshed }
            saveToKeychain(refreshed)
        } catch {
            // Silent fail - will force re-login on next API call
        }
    }

    private func saveToKeychain(_ s: SupabaseAuthService.Session) {
        do {
            let data = try JSONEncoder().encode(s)
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: keychainKey,
                                    kSecValueData as String: data]
            SecItemDelete(q as CFDictionary)
            SecItemAdd(q as CFDictionary, nil)
        } catch { }
    }

    private func loadFromKeychain() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: keychainKey,
                                kSecReturnData as String: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            if let s = try? JSONDecoder().decode(SupabaseAuthService.Session.self, from: data) {
                self.session = s
            }
        }
    }

    private func deleteFromKeychain() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: keychainKey]
        SecItemDelete(q as CFDictionary)
    }
}


