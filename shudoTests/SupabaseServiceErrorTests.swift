//
//  SupabaseServiceErrorTests.swift
//  shudoTests
//
//  Tests for SupabaseService error handling
//

import Testing
import Foundation
@testable import shudo

struct SupabaseServiceErrorTests {

    // MARK: - ServiceError Tests

    @Test func testServiceError_networkError_hasCorrectDescription() {
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
            NSLocalizedDescriptionKey: "The Internet connection appears to be offline."
        ])
        let error = SupabaseService.ServiceError.networkError(underlying: underlying)

        #expect(error.errorDescription?.contains("Network error") == true)
        #expect(error.errorDescription?.contains("offline") == true)
    }

    @Test func testServiceError_serverError_includesStatusCode() {
        let error = SupabaseService.ServiceError.serverError(statusCode: 503, message: nil)

        #expect(error.errorDescription?.contains("503") == true)
    }

    @Test func testServiceError_serverError_usesCustomMessage() {
        let error = SupabaseService.ServiceError.serverError(statusCode: 500, message: "Database unavailable")

        #expect(error.errorDescription == "Database unavailable")
    }

    @Test func testServiceError_identifiesOnlyAuthenticationFailures() {
        #expect(SupabaseService.ServiceError.serverError(
            statusCode: 401,
            message: nil
        ).isAuthenticationFailure)
        #expect(SupabaseService.ServiceError.serverError(
            statusCode: 403,
            message: nil
        ).isAuthenticationFailure)
        #expect(!SupabaseService.ServiceError.serverError(
            statusCode: 500,
            message: nil
        ).isAuthenticationFailure)
        #expect(!SupabaseService.ServiceError.parseError(
            message: "Invalid JSON structure"
        ).isAuthenticationFailure)
    }

    @Test func testServiceError_parseError_includesMessage() {
        let error = SupabaseService.ServiceError.parseError(message: "Invalid JSON structure")

        #expect(error.errorDescription?.contains("Invalid JSON structure") == true)
    }

    // MARK: - Error Type Distinction Tests

    @Test func testServiceErrors_areDistinct() {
        let networkError = SupabaseService.ServiceError.networkError(underlying: NSError(domain: "", code: 0))
        let serverError = SupabaseService.ServiceError.serverError(statusCode: 500, message: nil)
        let parseError = SupabaseService.ServiceError.parseError(message: "test")

        // Verify each error type produces different descriptions
        let descriptions = [
            networkError.errorDescription,
            serverError.errorDescription,
            parseError.errorDescription
        ].compactMap { $0 }

        #expect(descriptions.count == 3, "All error types should have descriptions")
        #expect(Set(descriptions).count == 3, "All descriptions should be unique")
    }

    // MARK: - LocalizedError Conformance

    @Test func testServiceError_conformsToLocalizedError() {
        let error: any LocalizedError = SupabaseService.ServiceError.networkError(
            underlying: NSError(domain: "", code: 0)
        )

        // LocalizedError should provide errorDescription
        #expect(error.errorDescription != nil)
    }
}
