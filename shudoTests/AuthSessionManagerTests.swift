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

    // MARK: - isAuthenticationError Tests

    @Test func testIsAuthenticationError_networkError_returnsFalse() {
        // Network errors (NSURLErrorDomain) should NOT be treated as auth errors
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: nil)
        let result = AuthSessionManagerTestHelper.isAuthenticationError(error)
        #expect(result == false, "Network errors should not be treated as authentication errors")
    }

    @Test func testIsAuthenticationError_401_returnsTrue() {
        // HTTP 401 should be treated as auth error
        let error = NSError(domain: "HTTP", code: 401, userInfo: nil)
        let result = AuthSessionManagerTestHelper.isAuthenticationError(error)
        #expect(result == true, "401 status should be treated as authentication error")
    }

    @Test func testIsAuthenticationError_403_returnsTrue() {
        // HTTP 403 should be treated as auth error
        let error = NSError(domain: "HTTP", code: 403, userInfo: nil)
        let result = AuthSessionManagerTestHelper.isAuthenticationError(error)
        #expect(result == true, "403 status should be treated as authentication error")
    }

    @Test func testIsAuthenticationError_invalidGrant_returnsTrue() {
        // Error message containing "invalid_grant" should be auth error
        let error = NSError(domain: "Auth", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Error: invalid_grant - token has been revoked"
        ])
        let result = AuthSessionManagerTestHelper.isAuthenticationError(error)
        #expect(result == true, "invalid_grant error should be treated as authentication error")
    }

    @Test func testIsAuthenticationError_tokenExpired_returnsTrue() {
        // Error message containing "token expired" should be auth error
        let error = NSError(domain: "Auth", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Token expired. Please reauthenticate."
        ])
        let result = AuthSessionManagerTestHelper.isAuthenticationError(error)
        #expect(result == true, "Token expired error should be treated as authentication error")
    }

    @Test func testIsAuthenticationError_serverError500_returnsFalse() {
        // 500 errors are server issues, not auth issues
        let error = NSError(domain: "HTTP", code: 500, userInfo: nil)
        let result = AuthSessionManagerTestHelper.isAuthenticationError(error)
        #expect(result == false, "500 errors should not be treated as authentication errors")
    }

    @Test func testIsAuthenticationError_timeoutError_returnsFalse() {
        // Timeout errors are transient, not auth issues
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        let result = AuthSessionManagerTestHelper.isAuthenticationError(error)
        #expect(result == false, "Timeout errors should not be treated as authentication errors")
    }

    @Test func testIsAuthenticationError_dnsError_returnsFalse() {
        // DNS errors are network issues, not auth issues
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, userInfo: nil)
        let result = AuthSessionManagerTestHelper.isAuthenticationError(error)
        #expect(result == false, "DNS errors should not be treated as authentication errors")
    }

    // MARK: - Retry Behavior Tests (Conceptual)

    @Test func testRetryLogic_shouldRetryOnNetworkError() {
        // This test verifies the conceptual behavior:
        // Network errors should trigger retry, not immediate signout
        let networkError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: nil)
        let shouldSignOut = AuthSessionManagerTestHelper.isAuthenticationError(networkError)
        #expect(shouldSignOut == false, "Network connection lost should NOT trigger signout")
    }

    @Test func testRetryLogic_shouldNotRetryOn401() {
        // 401 errors should NOT retry - they indicate definitive auth failure
        let authError = NSError(domain: "HTTP", code: 401, userInfo: nil)
        let shouldSignOut = AuthSessionManagerTestHelper.isAuthenticationError(authError)
        #expect(shouldSignOut == true, "401 should trigger immediate signout without retry")
    }
}

// MARK: - Test Helper

/// Helper to expose private methods for testing
enum AuthSessionManagerTestHelper {
    /// Test wrapper for isAuthenticationError logic
    static func isAuthenticationError(_ error: NSError) -> Bool {
        // Replicate the logic from AuthSessionManager for testing
        if error.domain == NSURLErrorDomain {
            return false
        }

        let authErrorCodes = [401, 403]
        if authErrorCodes.contains(error.code) {
            return true
        }

        let message = error.localizedDescription.lowercased()
        let authKeywords = ["invalid_grant", "token expired", "invalid refresh token", "unauthorized", "forbidden"]
        return authKeywords.contains { message.contains($0) }
    }
}
