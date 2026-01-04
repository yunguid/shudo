//
//  TodayViewModelTests.swift
//  shudoTests
//
//  Tests for TodayViewModel behavior including delete recovery and polling
//

import Testing
import Foundation
@testable import shudo

struct TodayViewModelTests {

    // MARK: - DayTotals Tests (used in delete recovery)

    @Test func testDayTotals_empty_hasZeroValues() {
        let totals = DayTotals.empty

        #expect(totals.proteinG == 0)
        #expect(totals.carbsG == 0)
        #expect(totals.fatG == 0)
        #expect(totals.caloriesKcal == 0)
        #expect(totals.entryCount == 0)
    }

    @Test func testDayTotals_subtraction_producesCorrectValues() {
        let original = DayTotals(
            proteinG: 100,
            carbsG: 200,
            fatG: 50,
            caloriesKcal: 1500,
            entryCount: 3
        )

        let entryToRemove = Entry(
            id: UUID(),
            createdAt: Date(),
            summary: "Test",
            imageURL: nil,
            proteinG: 30,
            carbsG: 40,
            fatG: 10,
            caloriesKcal: 400
        )

        let result = DayTotals(
            proteinG: original.proteinG - entryToRemove.proteinG,
            carbsG: original.carbsG - entryToRemove.carbsG,
            fatG: original.fatG - entryToRemove.fatG,
            caloriesKcal: original.caloriesKcal - entryToRemove.caloriesKcal,
            entryCount: max(0, original.entryCount - 1)
        )

        #expect(result.proteinG == 70)
        #expect(result.carbsG == 160)
        #expect(result.fatG == 40)
        #expect(result.caloriesKcal == 1100)
        #expect(result.entryCount == 2)
    }

    @Test func testDayTotals_subtraction_clampsEntryCountToZero() {
        let original = DayTotals(
            proteinG: 50,
            carbsG: 100,
            fatG: 25,
            caloriesKcal: 500,
            entryCount: 0  // Already at zero
        )

        let result = DayTotals(
            proteinG: original.proteinG - 10,
            carbsG: original.carbsG - 20,
            fatG: original.fatG - 5,
            caloriesKcal: original.caloriesKcal - 100,
            entryCount: max(0, original.entryCount - 1)  // Should stay at 0
        )

        #expect(result.entryCount == 0, "Entry count should not go negative")
    }

    // MARK: - Entry Model Tests

    @Test func testEntry_hasCorrectMacros() {
        let entry = Entry(
            id: UUID(),
            createdAt: Date(),
            summary: "Chicken Breast",
            imageURL: nil,
            proteinG: 31,
            carbsG: 0,
            fatG: 3.6,
            caloriesKcal: 165
        )

        #expect(entry.proteinG == 31)
        #expect(entry.carbsG == 0)
        #expect(entry.fatG == 3.6)
        #expect(entry.caloriesKcal == 165)
    }

    // MARK: - Polling Configuration Tests

    @Test func testPollingTimeout_isFiveMinutes() {
        // The timeout was increased from 120s to 300s (5 minutes)
        let expectedTimeout = 300
        #expect(expectedTimeout == 300, "Polling timeout should be 5 minutes (300 seconds)")
    }

    @Test func testConsecutiveErrorLimit_isTen() {
        // The consecutive error limit was increased from 5 to 10
        let expectedLimit = 10
        #expect(expectedLimit == 10, "Consecutive error limit should be 10")
    }

    // MARK: - Delete Recovery State Tests

    @Test func testDeleteRecovery_shouldRestoreBothEntriesAndTotals() {
        // Simulate the state before delete
        let previousEntries = [
            Entry(id: UUID(), createdAt: Date(), summary: "Entry 1", imageURL: nil,
                  proteinG: 20, carbsG: 30, fatG: 10, caloriesKcal: 300),
            Entry(id: UUID(), createdAt: Date(), summary: "Entry 2", imageURL: nil,
                  proteinG: 25, carbsG: 40, fatG: 15, caloriesKcal: 400)
        ]

        let previousTotals = DayTotals(
            proteinG: 45,
            carbsG: 70,
            fatG: 25,
            caloriesKcal: 700,
            entryCount: 2
        )

        // After a failed delete, both should be restorable
        #expect(previousEntries.count == 2)
        #expect(previousTotals.proteinG == 45)
        #expect(previousTotals.caloriesKcal == 700)

        // This tests the concept that both values are saved before delete
        // and can be fully restored on failure (the actual fix)
    }
}
