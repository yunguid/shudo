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
}
