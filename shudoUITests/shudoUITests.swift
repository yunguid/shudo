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

    @MainActor
    func testPhotoFirstMealStartsVoiceAndPreservesTheMixedDraft() throws {
        let app = launchPreview()

        app.buttons["Log meal"].tap()
        XCTAssertTrue(app.navigationBars["Log meal"].waitForExistence(timeout: 3))

        let note = app.textViews.firstMatch
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
        selectFirstPhotos(in: app, count: 2)

        let firstPhoto = app.buttons["Remove photo 1"]
        let secondPhoto = app.buttons["Remove photo 2"]
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 8))
        XCTAssertTrue(secondPhoto.exists)

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.navigationBars["Log meal"].waitForExistence(timeout: 5))
        XCTAssertTrue(firstPhoto.exists)
        XCTAssertTrue(secondPhoto.exists)
        XCTAssertEqual(note.value as? String, "Synthetic regression meal")

        let recordingControl = app.buttons["Voice recording control"]
        let startRecording = recordingControl
        XCTAssertTrue(startRecording.isEnabled)
        startRecording.tap()
        allowMicrophoneIfRequested(in: app)

        let stopRecording = recordingControl
        XCTAssertTrue(waitForRecording(stopRecording, timeout: 15))
        XCTAssertTrue(firstPhoto.exists)
        XCTAssertTrue(secondPhoto.exists)
        XCTAssertEqual(note.value as? String, "Synthetic regression meal")

        stopRecording.tap()
        let discardRecording = app.buttons["Discard voice note"]
        XCTAssertTrue(discardRecording.waitForExistence(timeout: 3))
        XCTAssertTrue(firstPhoto.exists)
        XCTAssertEqual(note.value as? String, "Synthetic regression meal")

        recordingControl.tap()
        XCTAssertTrue(waitForRecording(stopRecording, timeout: 15))
        stopRecording.tap()
        XCTAssertTrue(discardRecording.waitForExistence(timeout: 3))
        XCTAssertTrue(firstPhoto.exists)
        XCTAssertTrue(secondPhoto.exists)
        XCTAssertEqual(note.value as? String, "Synthetic regression meal")
    }

    /// A single tall portrait photo used to leave the mic button dead: the
    /// fill-scaled thumbnail keeps its full unclipped height for hit testing
    /// and its invisible overflow swallowed every tap above the grid. The
    /// stock library photos are landscape (no vertical overflow), so this
    /// seeds the worst-case image deterministically via a launch flag.
    @MainActor
    func testTallPortraitPhotoDoesNotBlockTheMicButton() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-shudoPolishPreview", "main",
            "-shudoPolishPreviewTallComposerPhoto",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Log meal"].waitForExistence(timeout: 5))

        app.buttons["Log meal"].tap()
        XCTAssertTrue(app.navigationBars["Log meal"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Remove photo 1"].waitForExistence(timeout: 3))

        let recordingControl = app.buttons["Voice recording control"]
        XCTAssertTrue(recordingControl.waitForExistence(timeout: 3))
        recordingControl.tap()
        allowMicrophoneIfRequested(in: app)
        XCTAssertTrue(
            waitForRecording(recordingControl, timeout: 15),
            "Mic tap was swallowed by the photo's unclipped fill overflow"
        )
        recordingControl.tap()
        XCTAssertTrue(app.buttons["Discard voice note"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Remove photo 1"].exists)
    }

    @MainActor
    func testStandaloneQuickVoiceStillAutoStarts() throws {
        let app = launchPreview()

        app.buttons["Quick voice meal"].tap()
        allowMicrophoneIfRequested(in: app)

        let activeRecording = app.buttons["Voice recording control"]
        XCTAssertTrue(waitForRecording(activeRecording, timeout: 15))
        activeRecording.tap()
        XCTAssertTrue(app.buttons["Discard voice note"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testDeniedMicrophoneExplainsTheFailureAndKeepsTheDraft() throws {
        let app = launchPreview()
        app.buttons["Log meal"].tap()

        let note = app.textViews.firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 3))
        note.tap()
        note.typeText("Permission recovery draft")

        let recordingControl = app.buttons["Voice recording control"]
        recordingControl.tap()
        if waitForRecording(recordingControl, timeout: 2) {
            recordingControl.tap()
            throw XCTSkip("Simulator microphone permission is granted")
        }
        let permissionError = app.staticTexts[
            "Microphone access is required to record a meal."
        ]
        XCTAssertTrue(permissionError.waitForExistence(timeout: 5))
        XCTAssertTrue(recordingControl.isEnabled)
        XCTAssertEqual(note.value as? String, "Permission recovery draft")
    }

    /// The combined notifications toggle must respond to a tap, request
    /// authorization, and stick. Pins both the control's hittability (fill
    /// overlays have silently eaten taps before) and the enable flow.
    @MainActor
    func testNotificationsToggleEnablesAndPersists() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "settings"]
        app.launch()

        let toggle = app.switches.firstMatch
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
    private func launchPreview() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "main"]
        app.launch()
        XCTAssertTrue(app.buttons["Log meal"].waitForExistence(timeout: 5))
        return app
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

    @MainActor
    private func allowMicrophoneIfRequested(in app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 1) else { return }
        let allow = alert.buttons["Allow"]
        if allow.exists { allow.tap() }
        app.activate()
    }

    @MainActor
    private func waitForRecording(_ control: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label BEGINSWITH 'Stop recording'")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: control)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
