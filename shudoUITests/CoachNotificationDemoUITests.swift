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
            "-shudoNotificationDemo", "-shudoNotificationDemoDelay", "20",
        ]
        app.launch()

        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 10) {
            snap("permission")
            allow.tap()
        }
        XCTAssertTrue(app.buttons["Log meal"].waitForExistence(timeout: 10))
        sleep(4) // self-check + scheduling
        XCUIDevice.shared.press(.home)

        let checkpoint = notification(containing: "62g of protein")
        XCTAssertTrue(checkpoint.waitForExistence(timeout: 45), "checkpoint banner never arrived")
        snap("banner")
        dumpTree("banner")

        let snack = notification(containing: "7-Eleven is 4 min away")
        XCTAssertTrue(snack.waitForExistence(timeout: 20), "snack banner never arrived")
        snap("banner-snack")

        // Let the last two land (the recap is passive: no banner).
        sleep(24)
        openNotificationCenter()
        snap("nc-stack")
        dumpTree("nc-stack")

        // Expand the stack.
        let stackTop = notification(containing: "Shudo")
        if stackTop.waitForExistence(timeout: 5) {
            stackTop.tap()
            sleep(2)
        }
        snap("nc-expanded")
        dumpTree("nc-expanded")

        // Long-look with the actions.
        let target = notification(containing: "62g of protein")
        guard target.waitForExistence(timeout: 5) else {
            XCTFail("checkpoint missing from Notification Center")
            return
        }
        target.press(forDuration: 1.5)
        sleep(2)
        snap("long-look")
        dumpTree("long-look")

        // Reply from the lock screen; Shudo answers as a new text.
        let reply = springboard.buttons["Reply"]
        if reply.waitForExistence(timeout: 5) {
            reply.tap()
            sleep(1)
            springboard.typeText("Had a shake at 9")
            snap("reply-typing")
            let send = springboard.buttons["Send"]
            if send.waitForExistence(timeout: 3) { send.tap() } else { springboard.typeText("\n") }
            let answer = notification(containing: "158g")
            XCTAssertTrue(answer.waitForExistence(timeout: 30), "Shudo's answer never arrived")
            sleep(2)
            snap("reply-answer")
            dumpTree("reply-answer")
        } else {
            XCTFail("no Reply action in the long-look")
        }

        // Tap the snack text: the app opens on Today at that message.
        let snackRow = notification(containing: "7-Eleven is 4 min away")
        if snackRow.waitForExistence(timeout: 5) {
            snackRow.tap()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            sleep(3)
            snap("deep-link")
        } else {
            XCTFail("snack text missing from Notification Center")
        }
    }

    /// Before/after comparison: the app is whatever is installed; the test
    /// only backgrounds it and waits for a text pushed with `simctl push`
    /// (body mentioning "62g of protein"), then captures banner and long-look.
    @MainActor
    func testPushedTextPresentation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "main"]
        app.launch()
        XCTAssertTrue(app.buttons["Log meal"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        let pushed = notification(containing: "62g of protein")
        XCTAssertTrue(pushed.waitForExistence(timeout: 90), "pushed text never arrived")
        snap("banner")
        sleep(6)
        openNotificationCenter()
        let row = notification(containing: "62g of protein")
        if row.waitForExistence(timeout: 5) {
            snap("nc")
            row.press(forDuration: 1.5)
            sleep(2)
            snap("long-look")
        }
    }

    // MARK: Helpers

    private func notification(containing text: String) -> XCUIElement {
        springboard.descendants(matching: .any)
            .matching(identifier: "NotificationShortLookView")
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
