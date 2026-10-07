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
        let app = launchPreview(scriptedSpeech: "with two scrambled eggs")

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
        XCTAssertTrue(recordingControl.isEnabled)
        recordingControl.tap()
        XCTAssertTrue(waitForRecording(recordingControl, timeout: 15))
        XCTAssertTrue(firstPhoto.exists)
        XCTAssertTrue(secondPhoto.exists)
        XCTAssertEqual(note.value as? String, "Synthetic regression meal")

        // Stopping appends the dictated take to the editable note.
        recordingControl.tap()
        let undoDictation = app.buttons["Undo last dictation"]
        XCTAssertTrue(undoDictation.waitForExistence(timeout: 5))
        XCTAssertTrue(firstPhoto.exists)
        XCTAssertTrue(waitForValue(
            of: note,
            toEqual: "Synthetic regression meal with two scrambled eggs",
            timeout: 3
        ))

        recordingControl.tap()
        XCTAssertTrue(waitForRecording(recordingControl, timeout: 15))
        recordingControl.tap()
        XCTAssertTrue(waitForValue(
            of: note,
            toEqual: "Synthetic regression meal with two scrambled eggs with two scrambled eggs",
            timeout: 5
        ))
        XCTAssertTrue(firstPhoto.exists)
        XCTAssertTrue(secondPhoto.exists)

        // Undo removes only the last take.
        XCTAssertTrue(undoDictation.waitForExistence(timeout: 3))
        undoDictation.tap()
        XCTAssertTrue(waitForValue(
            of: note,
            toEqual: "Synthetic regression meal with two scrambled eggs",
            timeout: 3
        ))
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
            "-shudoScriptedSpeech", "chicken and rice",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Log meal"].waitForExistence(timeout: 5))

        app.buttons["Log meal"].tap()
        XCTAssertTrue(app.navigationBars["Log meal"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Remove photo 1"].waitForExistence(timeout: 3))

        let recordingControl = app.buttons["Voice recording control"]
        XCTAssertTrue(recordingControl.waitForExistence(timeout: 3))
        recordingControl.tap()
        XCTAssertTrue(
            waitForRecording(recordingControl, timeout: 15),
            "Mic tap was swallowed by the photo's unclipped fill overflow"
        )
        recordingControl.tap()
        XCTAssertTrue(app.buttons["Undo last dictation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Remove photo 1"].exists)
    }

    @MainActor
    func testStandaloneQuickVoiceStillAutoStarts() throws {
        let app = launchPreview(scriptedSpeech: "overnight oats with whey")

        app.buttons["Quick voice meal"].tap()

        let activeRecording = app.buttons["Voice recording control"]
        XCTAssertTrue(waitForRecording(activeRecording, timeout: 15))
        activeRecording.tap()
        XCTAssertTrue(app.buttons["Undo last dictation"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(
            of: app.textViews.firstMatch,
            toEqual: "overnight oats with whey",
            timeout: 3
        ))
    }

    @MainActor
    func testDeniedMicrophoneExplainsTheFailureAndKeepsTheDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-shudoPolishPreview", "main",
            "-shudoScriptedSpeechMode", "denied",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["Log meal"].waitForExistence(timeout: 5))
        app.buttons["Log meal"].tap()

        let note = app.textViews.firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 3))
        note.tap()
        note.typeText("Permission recovery draft")

        let recordingControl = app.buttons["Voice recording control"]
        recordingControl.tap()
        let permissionError = app.staticTexts[
            "Microphone access is required to record a meal."
        ]
        XCTAssertTrue(permissionError.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open Settings"].exists)
        XCTAssertTrue(recordingControl.isEnabled)
        XCTAssertFalse(waitForRecording(recordingControl, timeout: 1))
        XCTAssertEqual(note.value as? String, "Permission recovery draft")
    }

    /// The headline flow: words show up while speaking, the take lands in
    /// the editable note, an edit sticks, and Log sends text — the timeline
    /// card is titled with the real words immediately.
    @MainActor
    func testDictationStreamsIntoEditableNoteAndSendsText() throws {
        let app = launchPreview(scriptedSpeech: "Greek yogurt with honey and granola")

        app.buttons["Log meal"].tap()
        XCTAssertTrue(app.navigationBars["Log meal"].waitForExistence(timeout: 3))

        let recordingControl = app.buttons["Voice recording control"]
        recordingControl.tap()
        XCTAssertTrue(waitForRecording(recordingControl, timeout: 15))

        let live = app.descendants(matching: .any)["Live transcript"]
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        let streaming = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS 'Greek yogurt'"),
            object: live
        )
        XCTAssertEqual(XCTWaiter.wait(for: [streaming], timeout: 5), .completed)

        recordingControl.tap()
        let note = app.textViews.firstMatch
        XCTAssertTrue(waitForValue(
            of: note,
            toEqual: "Greek yogurt with honey and granola",
            timeout: 5
        ))
        XCTAssertFalse(live.exists)

        // The dictated words are ordinary editable text. (Where the caret
        // lands is UIKit's call; the edit sticking is what matters.)
        note.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.9)).tap()
        note.typeText(" and berries")
        let edited = try XCTUnwrap(note.value as? String)
        XCTAssertTrue(edited.contains("Greek yogurt with honey and granola"))
        XCTAssertTrue(edited.contains("and berries"))

        let submit = app.buttons["Submit meal"]
        XCTAssertTrue(submit.isEnabled)
        submit.tap()

        XCTAssertTrue(app.navigationBars["Log meal"].waitForNonExistence(timeout: 5))
        let card = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", edited.trimmingCharacters(in: .whitespaces))
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Voice note"].exists)
    }

    /// A take still being heard can be sent straight from Log meal.
    @MainActor
    func testLogMealWhileListeningSendsTheLiveWords() throws {
        let app = launchPreview(scriptedSpeech: "two bananas")
        app.buttons["Log meal"].tap()
        XCTAssertTrue(app.navigationBars["Log meal"].waitForExistence(timeout: 3))

        let recordingControl = app.buttons["Voice recording control"]
        recordingControl.tap()
        XCTAssertTrue(waitForRecording(recordingControl, timeout: 15))

        let submit = app.buttons["Submit meal"]
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"),
            object: submit
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        submit.tap()

        XCTAssertTrue(app.navigationBars["Log meal"].waitForNonExistence(timeout: 5))
        let card = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "two bananas")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    /// One smoke test against the real recognizer stack. The Simulator can't
    /// run SpeechTranscriber, so either live listening or an honest
    /// "unavailable"/permission message is acceptable — never a dead button.
    @MainActor
    func testRealMicrophoneSmokeListensOrExplainsWhyNot() throws {
        let app = launchPreview()
        app.buttons["Log meal"].tap()
        XCTAssertTrue(app.navigationBars["Log meal"].waitForExistence(timeout: 3))

        let recordingControl = app.buttons["Voice recording control"]
        recordingControl.tap()
        allowSystemPromptsIfRequested(in: app)

        let explained = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS 'isn’t available on this device' OR label CONTAINS 'Microphone access' OR label CONTAINS 'Speech recognition is off' OR label CONTAINS 'microphone couldn’t start' OR label CONTAINS 'microphone is taking too long' OR label CONTAINS 'Voice couldn’t start' OR label CONTAINS 'Didn’t catch that'"
        )).firstMatch
        let deadline = Date().addingTimeInterval(20)
        var listened = false
        while Date() < deadline {
            if recordingControl.label.hasPrefix("Stop recording") {
                listened = true
                break
            }
            if explained.exists { break }
            allowSystemPromptsIfRequested(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertTrue(listened || explained.exists, "Mic tap produced neither listening nor an explanation")
        if listened {
            recordingControl.tap()
        }
        XCTAssertTrue(recordingControl.waitForExistence(timeout: 5))
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
    private func launchPreview(scriptedSpeech: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-shudoPolishPreview", "main"]
        if let scriptedSpeech {
            app.launchArguments += ["-shudoScriptedSpeech", scriptedSpeech]
        }
        app.launch()
        XCTAssertTrue(app.buttons["Log meal"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func waitForValue(
        of element: XCUIElement,
        toEqual expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "value == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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

    @MainActor
    private func waitForRecording(_ control: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label BEGINSWITH 'Stop recording'")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: control)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
