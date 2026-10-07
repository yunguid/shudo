import XCTest

/// "This week" (the weekly insights screen) hangs off the expanded Today
/// header: the rolling seven days on top, the stored recaps underneath, and
/// each recap opens in a sheet.
final class ThisWeekUITests: XCTestCase {
    @MainActor
    func testThisWeekIsReachableFromTheTodayHeader() {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "main"]
        app.launch()
        let header = app.descendants(matching: .any)["today.header.remaining"]
        XCTAssertTrue(header.waitForExistence(timeout: 8))
        header.tap()
        let insights = app.buttons["This week"]
        XCTAssertTrue(insights.waitForExistence(timeout: 3))
        insights.tap()
        XCTAssertTrue(app.navigationBars["This week"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testARecapOpensFromThisWeek() {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "insights"]
        app.launch()
        XCTAssertTrue(app.navigationBars["This week"].waitForExistence(timeout: 5))
        let recap = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Protein held steady")
        ).firstMatch
        for _ in 0..<4 where !recap.isHittable { app.swipeUp() }
        XCTAssertTrue(recap.isHittable)
        recap.tap()
        let suggestion = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Cap Friday and Saturday")
        ).firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 3))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Weekly recap sheet"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testRecapsStayReachableAtLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "insights",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.navigationBars["This week"].waitForExistence(timeout: 5))
        let recap = app.buttons.containing(
            NSPredicate(format: "label CONTAINS %@", "Strong start to the streak")
        ).firstMatch
        for _ in 0..<8 where !recap.isHittable { app.swipeUp() }
        XCTAssertTrue(recap.isHittable)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "This week at accessibility text size"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
