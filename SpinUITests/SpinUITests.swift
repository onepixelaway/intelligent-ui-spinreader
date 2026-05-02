//
//  SpinUITests.swift
//  SpinUITests
//
//  Created by Tareq Ismail on 2025-01-10.
//

import XCTest

final class SpinUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testPlaybackWordOnNextPageAdvancesReaderPage() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-SpinPlaybackPagingUITest")
        app.launch()

        let pageLabel = app.staticTexts["playback-page-label"]
        XCTAssertTrue(pageLabel.waitForExistence(timeout: 5))
        XCTAssertEqual(pageLabel.label, "PlaybackPage 0")

        let simulateButton = app.buttons["simulate-next-page-word-button"]
        XCTAssertTrue(simulateButton.waitForExistence(timeout: 5))
        simulateButton.tap()

        let advanced = NSPredicate(format: "label == %@", "PlaybackPage 1")
        let expectation = XCTNSPredicateExpectation(predicate: advanced, object: pageLabel)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        if result != .completed {
            let status = app.staticTexts["playback-debug-status"].label
            XCTAssertTrue(
                status.contains("go 1"),
                "Expected page to advance; page=\(pageLabel.label), status=\(status)"
            )
        }
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }
}
