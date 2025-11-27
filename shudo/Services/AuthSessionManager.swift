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
            do {
                let refreshed = try await service.refresh(refreshToken: s.refreshToken)
                await MainActor.run { self.session = refreshed }
                saveToKeychain(refreshed)
                return refreshed.accessToken
            } catch {
                // Refresh failed - clear stale session and force re-login
                await MainActor.run { self.signOut() }
                throw NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Session expired. Please sign in again."])
            }
        }
        throw NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
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


