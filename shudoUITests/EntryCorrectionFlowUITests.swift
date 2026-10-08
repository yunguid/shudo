//
//  EntryCorrectionFlowUITests.swift
//  shudoUITests
//
//  Drives the offline PolishPreview harness through the estimate-update
//  journey: meal card → detail → the fix bar at its bottom → immediate
//  return to the timeline with a visible updating state → refreshed
//  estimate (or a recoverable failure with retry).
//

import XCTest

final class EntryCorrectionFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchPreviewApp() -> XCUIApplication {
        let app = XCUIApplication()
        // Keep the deterministic flow assertions independent from whatever
        // Dynamic Type size a developer last selected in this simulator.
        app.launchArguments = [
            "-shudoPolishPreview", "main",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        ]
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

    /// Today's thread opens at the bottom (the evening); lunch is further
    /// up, so scroll the thread until the meal receipt is on screen.
    private func openLunch(in app: XCUIApplication) {
        let mealCard = app.staticTexts["Chicken rice bowl"].firstMatch
        XCTAssertTrue(mealCard.waitForExistence(timeout: 8))
        for _ in 0..<8 where !mealCard.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(mealCard.isHittable)
        mealCard.tap()
    }

    /// Walks from the timeline into the meal and submits the given typed
    /// correction from the fix bar at its bottom.
    private func submitCorrection(_ text: String, in app: XCUIApplication) {
        openLunch(in: app)

        let note = correctionInput(in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertTrue(note.isHittable)
        note.tap()
        note.typeText(text)

        let submit = app.buttons["correction.submit"].firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.tap()
    }

    @MainActor
    func testTheMealPageIsJustTheMealAndItsFixBar() throws {
        let app = launchPreviewApp()
        openLunch(in: app)

        // No extra buttons or pages: the fix bar sits at the bottom.
        XCTAssertTrue(app.buttons["correction.mic"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Update meal"].exists)
        XCTAssertFalse(app.buttons["Log again"].exists)
        // Nothing to send yet: the bar shows only the mic and the field.
        XCTAssertFalse(app.buttons["correction.submit"].exists)

        let note = correctionInput(in: app)
        note.tap()
        note.typeText("The rice was one cup")
        XCTAssertTrue(app.buttons["correction.submit"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["correction.submit"].firstMatch.isEnabled)
    }

    private func correctionInput(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "correction.input").firstMatch
    }

    @MainActor
    func testTypedCorrectionReturnsToTimelineImmediatelyAndRefreshesTheMeal() throws {
        let app = launchPreviewApp()

        submitCorrection("The rice was one cup, not two", in: app)

        // The meal page leaves right away — long before the ~2s "server"
        // recalculation completes — instead of holding the user on it.
        XCTAssertTrue(
            app.buttons["correction.mic"].firstMatch.waitForNonExistence(timeout: 2)
        )

        // The timeline is back with the corrected meal in a visible
        // updating state.
        let updating = element(labeled: "Updating nutrition estimate", in: app)
        XCTAssertTrue(updating.waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["capture.mic"].firstMatch.waitForExistence(timeout: 2))

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
