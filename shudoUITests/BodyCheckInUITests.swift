import XCTest

/// The morning ritual in the fewest taps: Check in → shutter → Save, and the
/// keypad-only weight entry. Runs on the offline Body fixture (the
/// Simulator's "camera" shoots a drawn stand-in).
final class BodyCheckInUITests: XCTestCase {
    @MainActor
    func testSnapShootSaveTurnsTheHeroIntoTheCheckedInRow() {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "body", "-shudoBodyPreview", "empty"]
        app.launch()

        let snap = app.buttons["Check in"]
        XCTAssertTrue(snap.waitForExistence(timeout: 8))
        snap.tap()

        let shutter = app.buttons.containing(
            NSPredicate(format: "label BEGINSWITH %@", "Start")
        ).firstMatch
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        shutter.tap()

        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 15), "the timer fires and review opens")
        save.tap()

        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Checked in")).firstMatch.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Checked in after Check in → shutter → Save"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testWeightIsTypedOnTheKeypadAndSaved() {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "body"]
        app.launch()

        let weight = app.buttons["Weight"]
        XCTAssertTrue(weight.waitForExistence(timeout: 8))
        weight.tap()

        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        // The keypad is already up: no tap on the field needed.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.typeText("164.8")
        app.buttons["Save"].tap()

        let detail = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "164.8 lb")
        ).firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
    }
}
