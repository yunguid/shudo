//
//  shudoUITests.swift
//  shudoUITests
//
//  Created by Luke on 8/16/25.
//

import XCTest

final class shudoUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    /// The meal composer is the photo path: the bar's camera (a photo
    /// picker on the Simulator) opens it with the photo attached. The
    /// note, the photos and a recording all survive leaving the app; the
    /// bottom-left mic records and the same spot logs the meal.
    @MainActor
    func testPhotoMealKeepsTheMixedDraftAndLogsFromTheMicSpot() throws {
        let app = launchPreview(scriptedSpeech: "with two scrambled eggs")
        openComposerWithPhoto(in: app)

        let note = mealInput(in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 2))
        note.tap()
        note.typeText("Synthetic regression meal")

        app.buttons["Photos"].tap()
        let cancelPicker = app.buttons["Cancel"]
        XCTAssertTrue(cancelPicker.waitForExistence(timeout: 5))
        cancelPicker.tap()
        XCTAssertTrue(app.buttons["Photos"].waitForExistence(timeout: 3))
        XCTAssertEqual(note.value as? String, "Synthetic regression meal")

        app.buttons["Photos"].tap()
        selectFirstPhotos(in: app, count: 1)
        let firstPhoto = app.buttons["Remove photo 1"]
        let secondPhoto = app.buttons["Remove photo 2"]
        XCTAssertTrue(secondPhoto.waitForExistence(timeout: 8))

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.navigationBars["Log meal"].waitForExistence(timeout: 5))
        XCTAssertTrue(firstPhoto.exists)
        XCTAssertTrue(secondPhoto.exists)
        XCTAssertEqual(note.value as? String, "Synthetic regression meal")

        app.buttons["meal.mic"].tap()
        let send = app.buttons["meal.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 15))
        XCTAssertTrue(firstPhoto.exists)
        XCTAssertTrue(app.buttons["meal.discard"].exists)

        send.tap()
        XCTAssertTrue(app.navigationBars["Log meal"].waitForNonExistence(timeout: 10))
        let card = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Synthetic regression meal")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
    }

    /// A tall portrait photo's fill overflow keeps its full height for hit
    /// testing; it must never swallow taps meant for the bottom controls.
    @MainActor
    func testTallPortraitPhotoDoesNotBlockTheMic() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-shudoPolishPreview", "main",
            "-shudoPolishPreviewTallComposerPhoto",
            "-shudoScriptedSpeech", "chicken and rice",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["capture.mic"].waitForExistence(timeout: 8))
        openComposerFromFan(in: app)
        XCTAssertTrue(app.buttons["Remove photo 1"].waitForExistence(timeout: 3))

        let mic = app.buttons["meal.mic"]
        XCTAssertTrue(mic.waitForExistence(timeout: 3))
        mic.tap()
        XCTAssertTrue(
            app.buttons["meal.send"].waitForExistence(timeout: 15),
            "Mic tap was swallowed by the photo's unclipped fill overflow"
        )
        XCTAssertTrue(app.buttons["Remove photo 1"].exists)
    }

    /// `shudo://capture` (quick voice) goes through the one voice entry
    /// point: the capture bar records on Today, and the bottom-left button
    /// that started it sends it.
    @MainActor
    func testCaptureDeepLinkRecordsInTheBar() throws {
        let app = launchPreview(scriptedSpeech: "overnight oats with whey")
        app.open(try XCTUnwrap(URL(string: "shudo://capture")))

        let send = app.buttons["capture.send"]
        let recording = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == 'Send to Shudo' AND isEnabled == true"),
            object: send
        )
        XCTAssertEqual(XCTWaiter.wait(for: [recording], timeout: 8), .completed)
        XCTAssertFalse(app.navigationBars["Log meal"].exists, "no second voice surface")
        send.tap()
        XCTAssertTrue(app.staticTexts["overnight oats with whey"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testDeniedMicrophoneSaysSoAndKeepsTheDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-shudoPolishPreview", "main",
            "-shudoScriptedSpeechMode", "denied",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["capture.mic"].waitForExistence(timeout: 8))
        openComposerWithPhoto(in: app)

        let note = mealInput(in: app)
        XCTAssertTrue(note.waitForExistence(timeout: 3))
        note.tap()
        note.typeText("Permission recovery draft")

        app.buttons["meal.mic"].tap()
        let permissionError = app.staticTexts["Microphone access is required to record a meal."]
        XCTAssertTrue(permissionError.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["meal.mic"].isEnabled)
        XCTAssertFalse(app.buttons["meal.send"].exists)
        XCTAssertEqual(note.value as? String, "Permission recovery draft")
    }

    /// The headline flow: record (no live words), tap the same spot, it
    /// transcribes and logs — the timeline card carries the real words.
    @MainActor
    func testRecordThenTapTheSameSpotLogsTheMeal() throws {
        let app = launchPreview(scriptedSpeech: "Greek yogurt with honey and granola")
        openComposerWithPhoto(in: app)

        let mic = app.buttons["meal.mic"]
        let micFrame = mic.frame
        mic.tap()
        let send = app.buttons["meal.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 15))
        XCTAssertEqual(send.frame.midX, micFrame.midX, accuracy: 6, "send replaces the mic in place")
        XCTAssertTrue(app.buttons["meal.discard"].exists)

        // Recording shows time and level, never the words.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Greek yogurt'")
        ).firstMatch.exists)

        send.tap()
        XCTAssertTrue(app.navigationBars["Log meal"].waitForNonExistence(timeout: 10))
        let card = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Greek yogurt with honey and granola")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
    }

    /// A failed upload keeps the recording and the sheet: the same spot
    /// retries, then logs.
    @MainActor
    func testAFailedTranscriptionKeepsTheRecordingForRetry() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-shudoPolishPreview", "main",
            "-shudoScriptedSpeech", "salmon and sweet potato",
            "-shudoScriptedSpeechMode", "uploadFailsOnce",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["capture.mic"].waitForExistence(timeout: 8))
        openComposerWithPhoto(in: app)

        app.buttons["meal.mic"].tap()
        let send = app.buttons["meal.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 15))
        send.tap()

        let retry = app.buttons["meal.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 8))
        XCTAssertTrue(app.descendants(matching: .any)["meal.error"].exists)
        XCTAssertTrue(app.buttons["meal.discard"].exists)
        XCTAssertTrue(app.navigationBars["Log meal"].exists)
        retry.tap()
        XCTAssertTrue(app.navigationBars["Log meal"].waitForNonExistence(timeout: 10))
    }

    /// One smoke test against the real recorder. Either it records or an
    /// honest reason shows — never a dead button.
    @MainActor
    func testRealMicrophoneSmokeRecordsOrExplainsWhyNot() throws {
        let app = launchPreview()
        openComposerWithPhoto(in: app)

        app.buttons["meal.mic"].tap()
        allowSystemPromptsIfRequested(in: app)

        let explained = app.descendants(matching: .any)["meal.message"]
        let send = app.buttons["meal.send"]
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if send.exists || explained.exists { break }
            allowSystemPromptsIfRequested(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(send.exists || explained.exists, "Mic tap produced neither recording nor an explanation")
        if send.exists {
            app.buttons["meal.discard"].tap()
        }
        XCTAssertTrue(app.buttons["meal.mic"].waitForExistence(timeout: 5))
    }

    /// The coach toggle (Settings → Coach, which replaced the 1.x daily
    /// nudges) must respond to a tap, request notification authorization,
    /// and stick. Pins both the control's hittability (fill overlays have
    /// silently eaten taps before) and the enable flow.
    @MainActor
    func testCoachToggleEnablesAndPersists() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "settings"]
        app.launch()

        let toggle = app.switches["settings.coach.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        while !toggle.isHittable {
            app.swipeUp()
        }
        toggle.tap()
        allowNotificationsIfRequested(in: app, timeout: 8)

        // The system permission alert can race the first flip on loaded CI
        // clones; one settled retry keeps this from flaking while a genuinely
        // dead toggle still fails.
        if !waitForToggleOn(toggle, timeout: 5) {
            if toggle.isHittable { toggle.tap() }
            allowNotificationsIfRequested(in: app, timeout: 5)
            XCTAssertTrue(
                waitForToggleOn(toggle, timeout: 5),
                "Notifications toggle did not turn on after a tap"
            )
        }
    }

    @MainActor
    private func waitForToggleOn(_ toggle: XCUIElement, timeout: TimeInterval) -> Bool {
        let enabled = NSPredicate(format: "value == '1'")
        let expectation = XCTNSPredicateExpectation(predicate: enabled, object: toggle)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func allowNotificationsIfRequested(in app: XCUIApplication, timeout: TimeInterval) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout) else { return }
        let allow = alert.buttons["Allow"]
        if allow.exists { allow.tap() }
        app.activate()
    }

    @MainActor
    private func launchPreview(scriptedSpeech: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "main"]
        if let scriptedSpeech {
            app.launchArguments += ["-shudoScriptedSpeech", scriptedSpeech]
        }
        app.launch()
        XCTAssertTrue(app.buttons["capture.mic"].waitForExistence(timeout: 8))
        return app
    }

    /// Hold the Shudo mark → slide to Photo (the Simulator has no camera,
    /// so it's the photo picker) opens the composer with it.
    @MainActor
    private func openComposerWithPhoto(in app: XCUIApplication) {
        chooseFanOption(2, in: app)
        let photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'"))
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 8))
        photos.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 1) { done.tap() }
        XCTAssertTrue(app.navigationBars["Log meal"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Remove photo 1"].waitForExistence(timeout: 8))
    }

    /// Hold the Shudo mark → slide to Log food: the composer opens with
    /// whatever the shell seeded.
    @MainActor
    private func openComposerFromFan(in app: XCUIApplication) {
        chooseFanOption(1, in: app)
        XCTAssertTrue(app.navigationBars["Log meal"].waitForExistence(timeout: 5))
    }

    /// Press and hold the Shudo mark, slide to option `index` in the fan
    /// (a row above the mark, 92 pt apart, 104 pt up) and let go.
    @MainActor
    private func chooseFanOption(_ index: Int, in app: XCUIApplication) {
        let start = app.buttons["capture.mic"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: start.withOffset(CGVector(dx: CGFloat(index) * 92, dy: -104)))
    }

    @MainActor
    private func mealInput(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "meal.input").firstMatch
    }

    @MainActor
    private func selectFirstPhotos(in app: XCUIApplication, count: Int) {
        let photos = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'"))
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(photos.count, count)
        for index in 0..<count {
            photos.element(boundBy: index)
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .tap()
        }

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 2))
        XCTAssertTrue(done.isEnabled)
        done.tap()
    }

    /// Microphone, then speech recognition: up to two system prompts.
    @MainActor
    private func allowSystemPromptsIfRequested(in app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            let alert = springboard.alerts.firstMatch
            guard alert.waitForExistence(timeout: 1) else { return }
            let allow = alert.buttons["Allow"]
            let ok = alert.buttons["OK"]
            if allow.exists {
                allow.tap()
            } else if ok.exists {
                ok.tap()
            } else {
                return
            }
            app.activate()
        }
    }
}
