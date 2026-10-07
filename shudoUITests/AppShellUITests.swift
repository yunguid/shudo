import XCTest

/// The 2.0 shell on the offline PolishPreview harness: three tabs, the
/// capture bar on every tab, the Today thread and its pinned header.
final class AppShellUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ screen: String = "main", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", screen] + extra
        app.launch()
        XCTAssertTrue(app.buttons["Log meal"].waitForExistence(timeout: 8))
        return app
    }

    /// The accessory sits under the keyboard, so typing happens in a field
    /// docked above it; sending puts Luke's bubble in Today's thread and the
    /// scripted coach answers.
    @MainActor
    func testTypingToShudoStaysAboveTheKeyboardAndSends() throws {
        let app = launch()
        app.buttons["capture.field"].tap()
        let input = app.descendants(matching: .any).matching(identifier: "capture.input").firstMatch
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "After tapping the capture field"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(input.waitForExistence(timeout: 3))
        let keyboard = app.keyboards.firstMatch
        if keyboard.waitForExistence(timeout: 3) {
            // Let the keyboard finish animating in.
            let settled = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "frame.origin.y < %f", app.frame.height - 100),
                object: keyboard
            )
            _ = XCTWaiter.wait(for: [settled], timeout: 3)
            XCTAssertLessThanOrEqual(input.frame.maxY, keyboard.frame.minY + 1, "Keyboard covers the composer")
        }
        input.typeText("had a protein bar at 4")
        app.buttons["capture.input.send"].tap()

        let bubble = app.staticTexts["had a protein bar at 4"]
        XCTAssertTrue(bubble.waitForExistence(timeout: 5))
        XCTAssertFalse(input.exists)
        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Logging it now'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 8))
    }
}
