// ArcticEdgeUITestsLaunchTests.swift
// ArcticEdgeUITests
//
// Launch smoke test. A fresh install opens on the permission primer rather than
// the tab bar, because three invasive permissions with no explanation is how you
// get three refusals.

import XCTest

@MainActor
final class ArcticEdgeUITestsLaunchTests: XCTestCase {

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testLaunchReachesTheOnboardingPrimer() throws {
        let app = XCUIApplication()
        // Force the primer: earlier tests in the same run share the app container
        // and may have already recorded that onboarding was seen.
        app.launchArguments += ["-UITestForceOnboarding", "YES"]
        app.launch()

        XCTAssertTrue(app.staticTexts["onboarding.heading"].waitForExistence(timeout: 90),
                      "a new install should open on the permission primer")
        XCTAssertTrue(app.buttons["onboarding.skip"].exists,
                      "the primer must be skippable: capture still works without location")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
