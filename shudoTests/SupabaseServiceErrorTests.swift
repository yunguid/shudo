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

    // MARK: - Signed image URL caching and batch signing

    @Test func signedURLCacheReusesWithinLifetimeAndExpiresWithMargin() async {
        let cache = SignedImageURLCache()
        let path = "user/entry/token/photo.jpg"
        let url = URL(string: "https://example.supabase.co/storage/v1/object/sign/entry-images/photo.jpg?token=abc")!
        let now = Date()

        await cache.store(url, for: path, now: now)
        #expect(await cache.cachedURL(for: path, now: now) == url)

        let nearExpiry = now.addingTimeInterval(
            SignedImageURLCache.signedURLLifetime - SignedImageURLCache.reuseSafetyMargin - 1
        )
        #expect(await cache.cachedURL(for: path, now: nearExpiry) == url)

        let pastMargin = now.addingTimeInterval(
            SignedImageURLCache.signedURLLifetime - SignedImageURLCache.reuseSafetyMargin + 1
        )
        #expect(await cache.cachedURL(for: path, now: pastMargin) == nil)
        // An expired entry is also evicted, not retried forever.
        #expect(await cache.cachedURL(for: path, now: now) == nil)
    }

    @Test func batchSignedURLResponsesNormalizeToAbsoluteURLs() throws {
        let supabaseUrl = URL(string: "https://example.supabase.co")!
        let parsed = SupabaseService.parseBatchSignedURLs(
            [
                [
                    "path": "a/b/photo.jpg",
                    "signedURL": "/object/sign/entry-images/a/b/photo.jpg?token=one"
                ],
                [
                    "path": "c/d/photo.jpg",
                    "signedUrl": "https://example.supabase.co/storage/v1/object/sign/entry-images/c/d/photo.jpg?token=two"
                ],
                ["path": "e/f/photo.jpg", "error": "not found"],
                ["signedURL": "/object/sign/entry-images/missing-path.jpg?token=three"]
            ],
            supabaseUrl: supabaseUrl
        )

        #expect(parsed.count == 2)
        #expect(
            parsed["a/b/photo.jpg"]?.absoluteString
                == "https://example.supabase.co/storage/v1/object/sign/entry-images/a/b/photo.jpg?token=one"
        )
        #expect(parsed["c/d/photo.jpg"]?.absoluteString.hasSuffix("token=two") == true)
    }

    // MARK: - Status polling projection

    @Test func statusSnapshotParsesAndMergesIntoVisibleEntry() throws {
        let id = UUID()
        let snapshot = try #require(SupabaseService.parseEntryStatusSnapshot([
            "id": id.uuidString,
            "status": "analyzing",
            "status_message": "Estimating your meal",
            "analysis_preview": "Chicken bowl with rice",
            "processing_attempts": 1,
            "updated_at": "2026-07-23T01:00:00.000Z",
            "local_day": "2026-07-22"
        ]))
        #expect(snapshot.status == .analyzing)
        #expect(snapshot.processingAttempts == 1)

        let visible = Entry(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_000),
            summary: "Voice note + photo",
            imageURL: URL(string: "https://example.com/cached.jpg"),
            proteinG: 0,
            carbsG: 0,
            fatG: 0,
            caloriesKcal: 0,
            localDay: "2026-07-22",
            status: .transcribing,
            statusMessage: "Transcribing your note"
        )
        let merged = TodayViewModel.entryApplyingStatusSnapshot(
            to: visible,
            snapshot: snapshot
        )
        // Status fields advance…
        #expect(merged.status == .analyzing)
        #expect(merged.statusMessage == "Estimating your meal")
        #expect(merged.analysisPreview == "Chicken bowl with rice")
        #expect(merged.statusUpdatedAt != nil)
        // …while locally known fields the projection omits are preserved.
        #expect(merged.summary == "Voice note + photo")
        #expect(merged.createdAt == visible.createdAt)
        #expect(merged.imageURL == visible.imageURL)
    }

    @Test func statusSnapshotRejectsRowsWithoutIdentityOrStatus() {
        #expect(SupabaseService.parseEntryStatusSnapshot(["id": "nope"]) == nil)
        #expect(
            SupabaseService.parseEntryStatusSnapshot([
                "id": UUID().uuidString,
                "status": "unknown-state"
            ]) == nil
        )
    }
}
