//
//  AuthSessionManagerTests.swift
//  shudoTests
//
//  Tests for AuthSessionManager retry logic and error handling
//

import Testing
import Foundation
@testable import shudo

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
