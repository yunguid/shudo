//
//  EntryCorrectionFlowUITests.swift
//  shudoUITests
//
//  Drives the offline PolishPreview harness through the estimate-update
//  journey: meal card → detail → correction sheet → immediate return to the
//  timeline with a visible updating state → refreshed estimate (or a
//  recoverable failure with retry).
//

import XCTest

final class EntryCorrectionFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchPreviewApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "main"]
        app.launch()
        return app
    }

    /// SwiftUI's combined/ignored accessibility containers surface as
    /// non-staticText elements; match on label across all element types.
    private func element(labeled fragment: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", fragment)
        ).firstMatch
    }

    /// Walks from the timeline into the correction sheet and submits the
    /// given typed correction.
    private func submitCorrection(_ text: String, in app: XCUIApplication) {
        let mealCard = app.staticTexts["Chicken rice bowl"].firstMatch
        XCTAssertTrue(mealCard.waitForExistence(timeout: 5))
        mealCard.tap()

        let updateMeal = app.buttons["Update meal"].firstMatch
        XCTAssertTrue(updateMeal.waitForExistence(timeout: 5))
        updateMeal.tap()

        let note = app.textViews.firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText(text)

        let submit = app.buttons["Update estimate"].firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.tap()
    }

    @MainActor
    func testTypedCorrectionReturnsToTimelineImmediatelyAndRefreshesTheMeal() throws {
        let app = launchPreviewApp()

        submitCorrection("The rice was one cup, not two", in: app)

        // The sheet leaves right away — long before the ~2s "server"
        // recalculation completes — instead of holding the user on it.
        XCTAssertTrue(
            app.buttons["Update estimate"].firstMatch.waitForNonExistence(timeout: 2)
        )

        // The timeline is back with the corrected meal in a visible
        // updating state.
        let updating = element(labeled: "Updating nutrition estimate", in: app)
        XCTAssertTrue(updating.waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["Log meal"].firstMatch.waitForExistence(timeout: 2))

        // The recalculated estimate replaces the old one on the same card.
        XCTAssertTrue(
            element(labeled: "Calories 560", in: app).waitForExistence(timeout: 8)
        )
        XCTAssertFalse(element(labeled: "Updating nutrition estimate", in: app).exists)
    }

    @MainActor
    func testFailedCorrectionRollsBackAndRetrySucceedsWithPreservedInput() throws {
        let app = launchPreviewApp()

        submitCorrection("fail this once, then half the rice", in: app)

        XCTAssertTrue(
            element(labeled: "Updating nutrition estimate", in: app).waitForExistence(timeout: 6)
        )

        // The failure is visible where the user is, with the previous
        // estimate back on the card and the correction preserved.
        let failureBanner = element(labeled: "Update failed", in: app)
        XCTAssertTrue(failureBanner.waitForExistence(timeout: 8))
        XCTAssertTrue(element(labeled: "Calories 695", in: app).exists)

        let retry = app.buttons["Retry meal update"].firstMatch
        XCTAssertTrue(retry.exists)
        retry.tap()

        XCTAssertTrue(
            element(labeled: "Updating nutrition estimate", in: app).waitForExistence(timeout: 6)
        )
        XCTAssertTrue(
            element(labeled: "Calories 560", in: app).waitForExistence(timeout: 8)
        )
        XCTAssertFalse(element(labeled: "Update failed", in: app).exists)
    }
}
