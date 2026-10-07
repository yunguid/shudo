import XCTest

final class ProteinInsightsUITests: XCTestCase {
    /// 2.0 navigation: the old "This week" row is gone from Today; weekly
    /// insights and the protein guide hang off the expanded day header.
    @MainActor
    func testWeekInsightsAreReachableFromTheTodayHeader() {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "main"]
        app.launch()
        let header = app.descendants(matching: .any)["today.header.remaining"]
        XCTAssertTrue(header.waitForExistence(timeout: 8))
        header.tap()
        let insights = app.buttons["Week insights"]
        XCTAssertTrue(insights.waitForExistence(timeout: 3))
        insights.tap()
        XCTAssertTrue(app.staticTexts["Your protein"].waitForExistence(timeout: 5))
        let guide = app.buttons["Explore protein portions"]
        for _ in 0..<4 where !guide.isHittable { app.swipeUp() }
        XCTAssertTrue(guide.isHittable)
        guide.tap()
        XCTAssertTrue(app.navigationBars["Protein portions"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testProteinGuideAndWeeklyHistoryRemainReachable() {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "insights"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your protein"].waitForExistence(timeout: 5))
        let guide = app.buttons["Explore protein portions"]
        if !guide.isHittable { app.swipeUp() }
        XCTAssertTrue(guide.waitForExistence(timeout: 3))
        guide.tap()
        XCTAssertTrue(app.navigationBars["Protein portions"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Food weight ≠ protein weight"].exists)
        let guideShot = XCTAttachment(screenshot: app.screenshot())
        guideShot.name = "Sourced protein portions"
        guideShot.lifetime = .keepAlways
        add(guideShot)
        app.navigationBars.buttons.firstMatch.tap()
        for _ in 0..<4 where !app.staticTexts["Week by week"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Week by week"].isHittable)
        let weeklyShot = XCTAttachment(screenshot: app.screenshot())
        weeklyShot.name = "Weekly insights scroll"
        weeklyShot.lifetime = .keepAlways
        add(weeklyShot)
    }
    @MainActor
    func testProteinReferenceRemainsReachableAtLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "insights",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your protein"].waitForExistence(timeout: 5))
        let guide = app.buttons["Explore protein portions"]
        for _ in 0..<8 where !guide.isHittable { app.swipeUp() }
        XCTAssertTrue(guide.isHittable)
        guide.tap()
        XCTAssertTrue(app.navigationBars["Protein portions"].waitForExistence(timeout: 3))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Protein guide at accessibility text size"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

}
