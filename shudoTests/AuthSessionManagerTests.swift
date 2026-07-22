//
//  AuthSessionManagerTests.swift
//  shudoTests
//
//  Tests for AuthSessionManager retry logic and error handling
//

import Testing
import Foundation
@testable import shudo

private enum DeletionTestError: Error {
    case failed
}

private struct DeletionServiceStub: AccountDeletionServicing {
    let error: Error?

    func deleteAccount(accessToken: String) async throws {
        #expect(accessToken == "access-token")
        if let error { throw error }
    }
}

private actor DeletionTestFlag {
    private var cleared = false

    func markCleared() { cleared = true }
    func wasCleared() -> Bool { cleared }
}

struct AuthSessionManagerTests {

    @Test func publicAuthRequestUsesPublishableKeyWithoutBogusBearerToken() throws {
        var request = URLRequest(url: try #require(URL(string: "https://example.supabase.co/auth/v1/token")))
        SupabaseAuthService.configurePublicHeaders(
            on: &request,
            apiKey: "sb_publishable_example"
        )

        #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_example")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func passwordRecoveryUsesCanonicalRedirectAndPublicHeaders() throws {
        let baseURL = try #require(URL(string: "https://example.supabase.co"))
        let redirectURL = SupabaseAuthService.passwordRecoveryRedirectURL
        let request = try SupabaseAuthService.makePasswordRecoveryRequest(
            email: "luke@yng.sh",
            redirectURL: redirectURL,
            baseURL: baseURL,
            apiKey: "sb_publishable_example"
        )

        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let body = try #require(
            JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
        )

        #expect(request.httpMethod == "POST")
        #expect(components.path == "/auth/v1/recover")
        #expect(
            components.queryItems?.first(where: { $0.name == "redirect_to" })?.value
            == "https://shudo.yng.sh/reset-password"
        )
        #expect(body == ["email": "luke@yng.sh"])
        #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_example")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func emailSignUpUsesConfirmationRedirectAndPublicHeaders() throws {
        let baseURL = try #require(URL(string: "https://example.supabase.co"))
        let request = try SupabaseAuthService.makeSignUpRequest(
            email: "new@example.com",
            password: "a-long-test-password",
            redirectURL: SupabaseAuthService.emailConfirmationRedirectURL,
            baseURL: baseURL,
            apiKey: "sb_publishable_example"
        )
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let body = try #require(
            JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
        )

        #expect(components.path == "/auth/v1/signup")
        #expect(
            components.queryItems?.first(where: { $0.name == "redirect_to" })?.value
            == "https://shudo.yng.sh/auth/confirm"
        )
        #expect(body["email"] == "new@example.com")
        #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_example")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func resendConfirmationUsesSignupTypeAndDedicatedLanding() throws {
        let request = try SupabaseAuthService.makeSignUpConfirmationRequest(
            email: "new@example.com",
            redirectURL: SupabaseAuthService.emailConfirmationRedirectURL,
            baseURL: try #require(URL(string: "https://example.supabase.co")),
            apiKey: "sb_publishable_example"
        )
        let components = try #require(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        )
        let body = try #require(
            JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
        )

        #expect(components.path == "/auth/v1/resend")
        #expect(components.queryItems?.first(where: { $0.name == "redirect_to" })?.value
                == "https://shudo.yng.sh/auth/confirm")
        #expect(body == ["type": "signup", "email": "new@example.com"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)

        let error = SupabaseAuthService.FriendlyAuthError(
            httpStatus: 400,
            supabaseErrorCode: "email_not_confirmed",
            serverMessage: "Email not confirmed",
            friendlyMessage: "Confirm your account."
        )
        #expect(SupabaseAuthService.isEmailNotConfirmed(error))
    }

    @Test func oauthAuthorizationUsesPKCEAndNativeCallback() throws {
        let url = try SupabaseAuthService.makeOAuthAuthorizationURL(
            provider: .google,
            redirectURL: SupabaseAuthService.oauthCallbackURL,
            codeVerifier: String(repeating: "v", count: 43),
            baseURL: try #require(URL(string: "https://example.supabase.co"))
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )

        #expect(components.path == "/auth/v1/authorize")
        #expect(query["provider"] == "google")
        #expect(query["redirect_to"] == "shudo://auth/callback")
        #expect(query["code_challenge_method"] == "s256")
        #expect(query["code_challenge"]?.isEmpty == false)
    }

    @Test func authSettingsExposeOnlyConfiguredOAuthProviders() throws {
        let configured = try JSONSerialization.data(withJSONObject: [
            "external": ["email": true, "apple": false, "google": true, "github": true]
        ])
        let disabled = Data("""
            {"external":{"apple":false,"google":false}}
            """.utf8)
        let bothEnabled = Data("""
            {"external":{"google":true,"apple":true}}
            """.utf8)
        let noKnownProviders = Data("""
            {"external":{}}
            """.utf8)

        #expect(try SupabaseAuthService.parseEnabledOAuthProviders(configured) == [.google])
        #expect(
            try SupabaseAuthService.parseEnabledOAuthProviders(bothEnabled) == [.apple, .google]
        )
        #expect(try SupabaseAuthService.parseEnabledOAuthProviders(disabled).isEmpty)
        #expect(try SupabaseAuthService.parseEnabledOAuthProviders(noKnownProviders).isEmpty)

        #expect(throws: SupabaseAuthService.OAuthProviderDiscoveryError.self) {
            try SupabaseAuthService.parseEnabledOAuthProviders(Data("{}".utf8))
        }
        #expect(throws: SupabaseAuthService.OAuthProviderDiscoveryError.self) {
            try SupabaseAuthService.parseEnabledOAuthProviders(
                Data("{\"external\":{\"apple\":\"yes\"}}".utf8)
            )
        }
        #expect(throws: SupabaseAuthService.OAuthProviderDiscoveryError.self) {
            try SupabaseAuthService.parseEnabledOAuthProviders(configured, statusCode: 503)
        }
    }

    @Test func authSettingsRequestUsesPublicGetContractAndFiniteTimeout() throws {
        let request = SupabaseAuthService.makeOAuthProviderSettingsRequest(
            baseURL: try #require(URL(string: "https://example.supabase.co")),
            apiKey: "sb_publishable_example"
        )

        #expect(request.url?.path == "/auth/v1/settings")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_example")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.timeoutInterval == 10)
    }

    @Test func oauthDiscoveryStateKeepsDisabledSeparateFromFailure() {
        let disabled = OAuthProviderDiscoveryState.loaded([])
        #expect(disabled != .failed)
        #expect(disabled != .loading)
    }

    @Test func profileCacheCanBePurgedWithLocalAccountState() throws {
        let userId = "profile-cache-test-\(UUID().uuidString)"
        ProfileCache.save(Profile(
            userId: userId,
            timezone: "UTC",
            dailyMacroTarget: .defaultDaily,
            weightKG: 82
        ))
        #expect(ProfileCache.load(userId: userId)?.weightKG == 82)
        ProfileCache.clear(userId: userId)
        #expect(ProfileCache.load(userId: userId) == nil)
    }

    @Test func accountDeletionRequestUsesAuthenticatedEdgeRoute() throws {
        let request = try SupabaseAuthService.makeDeleteAccountRequest(
            accessToken: "access-token",
            baseURL: try #require(URL(string: "https://example.supabase.co")),
            apiKey: "sb_publishable_example"
        )
        let body = try #require(
            JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
        )

        #expect(request.url?.path == "/functions/v1/delete_account")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "apikey") == "sb_publishable_example")
        #expect(body == ["confirmation": "DELETE"])
    }

    @Test func typedProfileUpdateCoversGoalsAndBodyMeasurements() throws {
        let payload = try SupabaseService.profileUpdatePayload(
            ProfileSettingsUpdate(
                timezone: "America/New_York",
                units: "imperial",
                displayName: " Luke ",
                heightCM: 181,
                weightKG: 82,
                targetWeightKG: 78,
                activityLevel: .active,
                goalType: .lose,
                goalNotes: "Slow and steady",
                dailyMacroTarget: MacroTarget(
                    caloriesKcal: 2_300,
                    proteinG: 170,
                    carbsG: 250,
                    fatG: 70
                )
            )
        )

        #expect(payload["display_name"] as? String == "Luke")
        #expect(payload["timezone"] as? String == "America/New_York")
        #expect(payload["units"] as? String == "imperial")
        #expect(payload["height_cm"] as? Double == 181)
        #expect(payload["activity_level"] as? String == "active")
        #expect(payload["goal_type"] as? String == "lose")
        #expect(payload["goal_notes"] as? String == "Slow and steady")
        #expect(payload["daily_macro_target"] as? [String: Double] != nil)

        #expect(throws: Error.self) {
            try SupabaseService.profileUpdatePayload(
                ProfileSettingsUpdate(heightCM: 10)
            )
        }
    }

    @Test @MainActor func appRouterRecognizesNativeAuthCallback() throws {
        let callback = try #require(
            URL(string: "shudo://auth/callback?code=authorization-code")
        )
        AppRouter.shared.handle(url: callback)
        #expect(AppRouter.shared.authCallbackURL == callback)
        AppRouter.shared.consumeAuthCallback(callback)
        #expect(AppRouter.shared.authCallbackURL == nil)
    }

    @Test func confirmedAccountDeletionClearsLocalStateOnlyAfterSuccess() async throws {
        let successFlag = DeletionTestFlag()
        try await AuthSessionManager.completeAccountDeletion(
            accessToken: "access-token",
            using: DeletionServiceStub(error: nil)
        ) {
            await successFlag.markCleared()
        }
        #expect(await successFlag.wasCleared())

        let failureFlag = DeletionTestFlag()
        do {
            try await AuthSessionManager.completeAccountDeletion(
                accessToken: "access-token",
                using: DeletionServiceStub(error: DeletionTestError.failed)
            ) {
                await failureFlag.markCleared()
            }
            Issue.record("Expected deletion failure")
        } catch {
            #expect(!(await failureFlag.wasCleared()))
        }
    }

    @Test func recoveryDoesNotRevealWhetherEmailExists() {
        let missingUser = SupabaseAuthService.FriendlyAuthError(
            httpStatus: 400,
            supabaseErrorCode: "user_not_found",
            serverMessage: "User not found",
            friendlyMessage: "No account found for this email."
        )
        let rateLimited = SupabaseAuthService.FriendlyAuthError(
            httpStatus: 429,
            supabaseErrorCode: "over_email_send_rate_limit",
            serverMessage: "Too many requests",
            friendlyMessage: "Please try again later."
        )

        #expect(SupabaseAuthService.masksRecoveryLookupFailure(missingUser))
        #expect(!SupabaseAuthService.masksRecoveryLookupFailure(rateLimited))
    }

    @Test func authEmailValidationAcceptsAndNormalizesUsersAddress() {
        #expect(AuthEmailInput.isValid("  Luke@YNG.sh\n"))
        #expect(AuthEmailInput.normalized("  Luke@YNG.sh\n") == "luke@yng.sh")
        #expect(!AuthEmailInput.isValid("luke@yng"))
        #expect(!AuthEmailInput.isValid("luke@@yng.sh"))
        #expect(!AuthEmailInput.isValid("@yng.sh"))
    }

    // MARK: - isAuthenticationError Tests

    @Test func testIsAuthenticationError_networkError_returnsFalse() {
        // Network errors (NSURLErrorDomain) should NOT be treated as auth errors
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
        let result = AuthSessionManager.isAuthenticationError(error)
        #expect(result == false, "Network errors should not be treated as authentication errors")
    }

    @Test func testIsAuthenticationError_401_returnsTrue() {
        // HTTP 401 should be treated as auth error
        let error = NSError(domain: "HTTP", code: 401, userInfo: nil)
        let result = AuthSessionManager.isAuthenticationError(error)
        #expect(result == true, "401 status should be treated as authentication error")
    }

    @Test func testIsAuthenticationError_403_returnsTrue() {
        // HTTP 403 should be treated as auth error
        let error = NSError(domain: "HTTP", code: 403, userInfo: nil)
        let result = AuthSessionManager.isAuthenticationError(error)
        #expect(result == true, "403 status should be treated as authentication error")
    }

    @Test func testIsAuthenticationError_invalidGrant_returnsTrue() {
        // Error message containing "invalid_grant" should be auth error
        let error = NSError(domain: "Auth", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Error: invalid_grant - token has been revoked"
        ])
        let result = AuthSessionManager.isAuthenticationError(error)
        #expect(result == true, "invalid_grant error should be treated as authentication error")
    }

    @Test func friendlyOAuthInvalidGrantUsesStructuredCodeBeforeFriendlyLoginCopy() {
        let error = SupabaseAuthService.FriendlyAuthError(
            httpStatus: 400,
            supabaseErrorCode: "invalid_grant",
            serverMessage: "Invalid Refresh Token: Refresh Token Not Found",
            friendlyMessage: "Incorrect email or password."
        )

        #expect(AuthSessionManager.isAuthenticationError(error))
    }

    @Test func friendlyOAuthInvalidGrantFallsBackToOriginalServerDescription() {
        let error = SupabaseAuthService.FriendlyAuthError(
            httpStatus: 400,
            supabaseErrorCode: nil,
            serverMessage: "OAuth error: invalid_grant",
            friendlyMessage: "Something went wrong. Please try again."
        )

        #expect(AuthSessionManager.isAuthenticationError(error))
    }

    @Test func currentGoTrueDeadSessionCodesInvalidateRefreshSession() {
        for code in [
            "refresh_token_already_used",
            "refresh_token_not_found",
            "session_expired",
            "session_not_found",
            "user_banned",
            "user_not_found",
        ] {
            let error = SupabaseAuthService.FriendlyAuthError(
                httpStatus: 400,
                supabaseErrorCode: code,
                serverMessage: nil,
                friendlyMessage: "Please try again."
            )
            #expect(
                AuthSessionManager.isAuthenticationError(error),
                "\(code) should invalidate a refresh session"
            )
        }
    }

    @Test func friendlyLoginAndTransientFailuresDoNotTriggerSignOut() {
        let invalidCredentials = SupabaseAuthService.FriendlyAuthError(
            httpStatus: 400,
            supabaseErrorCode: "invalid_credentials",
            serverMessage: "Invalid login credentials",
            friendlyMessage: "Incorrect email or password."
        )
        let rateLimited = SupabaseAuthService.FriendlyAuthError(
            httpStatus: 429,
            supabaseErrorCode: "over_request_rate_limit",
            serverMessage: "Too many requests",
            friendlyMessage: "Please try again later."
        )
        let serverFailureMentioningToken = SupabaseAuthService.FriendlyAuthError(
            httpStatus: 500,
            supabaseErrorCode: "unexpected_failure",
            serverMessage: "Could not inspect invalid refresh token",
            friendlyMessage: "Please try again."
        )

        #expect(!AuthSessionManager.isAuthenticationError(invalidCredentials))
        #expect(!AuthSessionManager.isAuthenticationError(rateLimited))
        #expect(!AuthSessionManager.isAuthenticationError(serverFailureMentioningToken))
    }

    @Test func authAdjacentProseWithoutTerminalStatusDoesNotTriggerSignOut() {
        let forbidden = NSError(
            domain: "Profile",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "This profile field is forbidden"]
        )
        let unauthorized = NSError(
            domain: "Storage",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Unauthorized photo operation"]
        )
        let similarOAuthCode = NSError(
            domain: "Auth",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "invalid_grantee"]
        )

        #expect(!AuthSessionManager.isAuthenticationError(forbidden))
        #expect(!AuthSessionManager.isAuthenticationError(unauthorized))
        #expect(!AuthSessionManager.isAuthenticationError(similarOAuthCode))
    }

    @Test func testIsAuthenticationError_tokenExpired_returnsTrue() {
        // Error message containing "token expired" should be auth error
        let error = NSError(domain: "Auth", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Token expired. Please reauthenticate."
        ])
        let result = AuthSessionManager.isAuthenticationError(error)
        #expect(result == true, "Token expired error should be treated as authentication error")
    }

    @Test func testIsAuthenticationError_serverError500_returnsFalse() {
        // 500 errors are server issues, not auth issues
        let error = NSError(domain: "HTTP", code: 500, userInfo: nil)
        let result = AuthSessionManager.isAuthenticationError(error)
        #expect(result == false, "500 errors should not be treated as authentication errors")
    }

    @Test func testIsAuthenticationError_timeoutError_returnsFalse() {
        // Timeout errors are transient, not auth issues
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        let result = AuthSessionManager.isAuthenticationError(error)
        #expect(result == false, "Timeout errors should not be treated as authentication errors")
    }

    @Test func testIsAuthenticationError_dnsError_returnsFalse() {
        // DNS errors are network issues, not auth issues
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, userInfo: nil)
        let result = AuthSessionManager.isAuthenticationError(error)
        #expect(result == false, "DNS errors should not be treated as authentication errors")
    }

    // MARK: - Retry Behavior Tests (Conceptual)

    @Test func testRetryLogic_shouldRetryOnNetworkError() {
        // This test verifies the conceptual behavior:
        // Network errors should trigger retry, not immediate signout
        let networkError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: nil)
        let shouldSignOut = AuthSessionManager.isAuthenticationError(networkError)
        #expect(shouldSignOut == false, "Network connection lost should NOT trigger signout")
    }

    @Test func testRetryLogic_shouldNotRetryOn401() {
        // 401 errors should NOT retry - they indicate definitive auth failure
        let authError = NSError(domain: "HTTP", code: 401, userInfo: nil)
        let shouldSignOut = AuthSessionManager.isAuthenticationError(authError)
        #expect(shouldSignOut == true, "401 should trigger immediate signout without retry")
    }

    @Test func extractsUserIdFromJWTWhenUserFetchWasUnavailable() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "sub": "6e530972-c4f0-4b54-a9b1-c76077f0b492"
        ])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "header.\(encoded).signature"

        #expect(AuthSessionManager.subject(fromJWT: token) == "6e530972-c4f0-4b54-a9b1-c76077f0b492")
        #expect(AuthSessionManager.subject(fromJWT: "not-a-jwt") == nil)
    }

    @Test func persistedSessionScopeUsesOnlyTheCanonicalProjectOrigin() throws {
        let url = try #require(URL(string: "https://New-Project.supabase.co/auth/v1"))
        #expect(AuthSessionManager.projectScope(for: url) == "https://new-project.supabase.co")
    }

    @Test func projectScopedEnvelopeRestoresOnlyForItsOwnSupabaseProject() throws {
        let currentURL = try #require(URL(string: "https://current-ref.supabase.co"))
        let otherURL = try #require(URL(string: "https://other-ref.supabase.co"))
        let session = try makeSession(issuer: "https://current-ref.supabase.co/auth/v1")
        let envelope = AuthSessionManager.PersistedSessionEnvelope(
            schemaVersion: 1,
            projectScope: AuthSessionManager.projectScope(for: currentURL),
            session: session
        )
        let data = try JSONEncoder().encode(envelope)

        let restored = try #require(AuthSessionManager.resolvePersistedSession(
            data,
            currentProjectURL: currentURL
        ))
        #expect(restored.session == session)
        #expect(!restored.requiresRewrite)
        #expect(AuthSessionManager.resolvePersistedSession(
            data,
            currentProjectURL: otherURL
        ) == nil)
    }

    @Test func mismatchedTokenIssuerInvalidatesEvenAnApparentlyCurrentEnvelope() throws {
        let currentURL = try #require(URL(string: "https://current-ref.supabase.co"))
        let wrongSession = try makeSession(issuer: "https://old-ref.supabase.co/auth/v1")
        let envelope = AuthSessionManager.PersistedSessionEnvelope(
            schemaVersion: 1,
            projectScope: AuthSessionManager.projectScope(for: currentURL),
            session: wrongSession
        )

        #expect(AuthSessionManager.resolvePersistedSession(
            try JSONEncoder().encode(envelope),
            currentProjectURL: currentURL
        ) == nil)
    }

    @Test func matchingLegacySessionMigratesButOldOrUnscopedLegacySessionIsCleared() throws {
        let currentURL = try #require(URL(string: "https://current-ref.supabase.co"))
        let currentSession = try makeSession(issuer: "https://current-ref.supabase.co/auth/v1")
        let oldSession = try makeSession(issuer: "https://old-ref.supabase.co/auth/v1")
        let unscopedSession = SupabaseAuthService.Session(
            accessToken: "not-a-jwt",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            userId: "test-user"
        )

        let migrated = try #require(AuthSessionManager.resolvePersistedSession(
            try JSONEncoder().encode(currentSession),
            currentProjectURL: currentURL
        ))
        #expect(migrated.session == currentSession)
        #expect(migrated.requiresRewrite)
        #expect(AuthSessionManager.resolvePersistedSession(
            try JSONEncoder().encode(oldSession),
            currentProjectURL: currentURL
        ) == nil)
        #expect(AuthSessionManager.resolvePersistedSession(
            try JSONEncoder().encode(unscopedSession),
            currentProjectURL: currentURL
        ) == nil)
    }

    @Test func refreshResultCannotRecreateSignedOutOrReplacedSession() throws {
        let expected = try makeSession(
            issuer: "https://current-ref.supabase.co/auth/v1",
            refreshToken: "expected"
        )
        let refreshed = try makeSession(
            issuer: "https://current-ref.supabase.co/auth/v1",
            refreshToken: "refreshed"
        )
        let replacement = try makeSession(
            issuer: "https://current-ref.supabase.co/auth/v1",
            refreshToken: "replacement"
        )

        #expect(AuthSessionManager.canApplyRefresh(
            current: expected,
            expected: expected,
            refreshed: refreshed
        ))
        #expect(AuthSessionManager.canApplyRefresh(
            current: refreshed,
            expected: expected,
            refreshed: refreshed
        ))
        #expect(!AuthSessionManager.canApplyRefresh(
            current: nil,
            expected: expected,
            refreshed: refreshed
        ))
        #expect(!AuthSessionManager.canApplyRefresh(
            current: replacement,
            expected: expected,
            refreshed: refreshed
        ))
    }

    private func makeSession(
        issuer: String,
        refreshToken: String = "refresh"
    ) throws -> SupabaseAuthService.Session {
        let payload = try JSONSerialization.data(withJSONObject: [
            "iss": issuer,
            "sub": "test-user",
        ])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return SupabaseAuthService.Session(
            accessToken: "header.\(encoded).signature",
            refreshToken: refreshToken,
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            userId: "test-user"
        )
    }
}
