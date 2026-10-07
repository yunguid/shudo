import XCTest

/// Drives Springboard through a coach text's whole life on a simulator:
/// permission prompt, banner, the grouped stack in Notification Center, the
/// long-look with Reply, a lock-screen reply answered by Shudo, and a tap
/// that opens the thread at the message. The app side is the DEBUG
/// `-shudoNotificationDemo` harness (real scheduler, fake server).
///
/// Opt-in, because it waits on real notification delivery:
///
///     TEST_RUNNER_SHUDO_DEMO_SHOTS=<dir> xcodebuild test … \
///       -only-testing:shudoUITests/CoachNotificationDemoUITests
///
/// Screenshots (and Springboard trees, for debugging queries) land in <dir>.
final class CoachNotificationDemoUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var shotsDirectory: URL?
    private var prefix = "q5-after"

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let path = ProcessInfo.processInfo.environment["SHUDO_DEMO_SHOTS"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SHUDO_DEMO_SHOTS=<dir> to run the notification demo.")
        }
        shotsDirectory = URL(fileURLWithPath: path, isDirectory: true)
        if let prefix = ProcessInfo.processInfo.environment["SHUDO_DEMO_PREFIX"], !prefix.isEmpty {
            self.prefix = prefix
        }
    }

    @MainActor
    func testCoachTextsEndToEnd() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-shudoPolishPreview", "main",
            "-shudoNotificationDemo", "-shudoNotificationDemoDelay", "8",
        ]
        app.launch()

        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 10) {
            snap("permission")
            allow.tap()
        }
        sleep(25) // the self-check runs while the app is in front
        // Home: the demo schedules its four texts 8, 18, 28 and 38 s out.
        XCUIDevice.shared.press(.home)

        let banner = notification(containing: "62g of protein")
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "checkpoint banner never arrived")
        snap("banner")

        // Pull the banner open: the long-look with the actions.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).press(forDuration: 1.2)
        sleep(2)
        snap("long-look")
        dumpTree("long-look")

        // Reply from the banner; Shudo answers as a new text.
        let reply = springboard.buttons["Reply"]
        if reply.waitForExistence(timeout: 5) {
            reply.tap()
            sleep(2)
            // A fresh simulator shows the keyboard's slide-to-type tip first.
            let tip = springboard.buttons["Continue"]
            if tip.waitForExistence(timeout: 3) {
                tip.tap()
                sleep(1)
            }
            springboard.typeText("Had a shake at 9")
            snap("reply-typing")
            let send = springboard.buttons["Send"]
            if send.waitForExistence(timeout: 3) { send.tap() } else { springboard.typeText("\n") }
            let answer = notification(containing: "158g")
            XCTAssertTrue(answer.waitForExistence(timeout: 30), "Shudo's answer never arrived")
            snap("reply-answer")
        } else {
            XCTFail("no Reply action in the long-look")
        }

        // Let the rest land, then look at the stack.
        sleep(35)
        openNotificationCenter()
        snap("nc-stack")
        // The collapsed stack sits just above the bottom of the cover sheet.
        let showLess = springboard.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Show less")).firstMatch
        if !showLess.exists {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.69)).tap()
            _ = showLess.waitForExistence(timeout: 5)
        }
        sleep(1)
        snap("nc-expanded")
        dumpTree("nc-expanded")

        // Tap the snack text: the app opens on Today at that message.
        let snackRow = springboard.buttons.matching(identifier: "ShortLook.Platter.Content.Seamless")
            .matching(NSPredicate(format: "label CONTAINS %@", "7-Eleven is 4 min away"))
            .firstMatch
        if snackRow.waitForExistence(timeout: 5), snackRow.isHittable {
            snackRow.tap()
            sleep(6)
            snap("deep-link")
        } else {
            XCTFail("snack text missing from Notification Center")
        }
    }

    /// Tapping the first banner opens Today scrolled to that text. Taps by
    /// coordinate only (no Springboard queries), so it survives a busy Mac.
    @MainActor
    func testTappingABannerOpensTheThread() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-shudoPolishPreview", "main",
            "-shudoNotificationDemo", "-shudoNotificationDemoDelay", "8",
        ]
        app.launch()
        sleep(25)
        XCUIDevice.shared.press(.home)
        sleep(10) // the checkpoint banner is up 8–13 s after Home
        snap("tap-banner")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        sleep(6)
        snap("deep-link")
    }

    /// The four texts as one conversation in Notification Center:
    /// collapsed (with its count), then expanded. Coordinates only.
    @MainActor
    func testTextsStackAsOneConversation() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-shudoPolishPreview", "main",
            "-shudoNotificationDemo", "-shudoNotificationDemoDelay", "8",
        ]
        app.launch()
        sleep(25)
        XCUIDevice.shared.press(.home)
        sleep(50) // all four delivered
        openNotificationCenter()
        snap("nc-stack")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.69)).tap()
        sleep(3)
        snap("nc-expanded")
    }

    /// Before/after comparison: the app is whatever is installed; the test
    /// only backgrounds it and waits for a text pushed with `simctl push`
    /// (body mentioning "62g of protein"), then captures banner and long-look.
    @MainActor
    func testPushedTextPresentation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "main"]
        app.launch()
        sleep(3)
        XCUIDevice.shared.press(.home)
        let pushed = notification(containing: "62g of protein")
        XCTAssertTrue(pushed.waitForExistence(timeout: 120), "pushed text never arrived")
        snap("banner")
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).press(forDuration: 1.2)
        sleep(2)
        snap("long-look")
    }

    // MARK: Helpers

    private func notification(containing text: String) -> XCUIElement {
        // Buttons only: a full Springboard descendants query times out on a
        // busy machine.
        springboard.buttons
            .matching(identifier: "ShortLook.Platter.Content.Seamless")
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    private func openNotificationCenter() {
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.005))
        let middle = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.65))
        top.press(forDuration: 0.05, thenDragTo: middle)
        sleep(2)
    }

    private func snap(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let shotsDirectory else { return }
        try? screenshot.pngRepresentation.write(to: shotsDirectory.appendingPathComponent("\(prefix)-\(name).png"))
    }

    private func dumpTree(_ name: String) {
        guard let shotsDirectory else { return }
        try? springboard.debugDescription.write(
            to: shotsDirectory.appendingPathComponent("\(prefix)-tree-\(name).txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
