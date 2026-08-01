// ArcticEdgeUITestsLaunchTests.swift
// ArcticEdgeUITests
//
// Launch smoke test. Captures a screenshot of the first screen a new install
// sees, which is the permission primer rather than the tab bar.

import XCTest

@MainActor
final class ArcticEdgeUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testLaunchReachesTheOnboardingPrimer() throws {
        let app = XCUIApplication()
        app.launch()

        // A fresh install must explain the permissions before iOS asks for them.
        let heading = app.staticTexts["ArcticEdge needs three things"]
        XCTAssertTrue(heading.waitForExistence(timeout: 20),
                      "a new install should open on the permission primer")
        XCTAssertTrue(app.buttons["CONTINUE"].exists)
        XCTAssertTrue(app.buttons["Not now"].exists,
                      "the primer must be skippable: capture still works without location")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
