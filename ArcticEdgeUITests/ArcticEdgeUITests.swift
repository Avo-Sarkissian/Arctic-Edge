// ArcticEdgeUITests.swift
// ArcticEdgeUITests
//
// Replaces the Xcode template stubs (testExample, testLaunchPerformance) with
// checks on flows a skier actually touches. These run with no permission
// granted, which is deliberate: the denied path is the one most likely to break
// silently, and it used to produce a screen that recorded nothing while saying
// nothing.

import XCTest

@MainActor
final class ArcticEdgeUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Skip the permission primer so tests land on the tab bar directly.
        app.launchArguments += ["-UITestSkipOnboarding", "YES"]
        app.launch()
    }

    override func tearDown() async throws {
        app = nil
    }

    // MARK: - Navigation

    func testAllThreeTabsAreReachable() throws {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 15), "the tab bar should appear on launch")

        for tab in ["Today", "History", "Settings"] {
            let button = tabBar.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 5), "missing \(tab) tab")
            button.tap()
        }
    }

    func testTodayTabShowsTheSessionControl() throws {
        app.tabBars.buttons["Today"].tap()
        let startButton = app.buttons["START DAY"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 15),
                      "Start Day is the primary action and must be present")
        XCTAssertTrue(startButton.isHittable)
    }

    // MARK: - Empty states

    func testHistoryShowsAnEmptyStateRatherThanABlankScreen() throws {
        app.tabBars.buttons["History"].tap()
        // Either the empty state or at least one recorded run is fine. A blank
        // screen with neither is not.
        let emptyState = app.staticTexts["No runs yet"]
        let anyRun = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Run '")
        ).firstMatch
        XCTAssertTrue(
            emptyState.waitForExistence(timeout: 15) || anyRun.waitForExistence(timeout: 2),
            "history should show either runs or an explanation of why there are none"
        )
    }

    // MARK: - Settings and honesty rules

    func testSettingsExposesDataControl() throws {
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Raw motion frames"].waitForExistence(timeout: 15),
                      "the storage readout should be visible")
        XCTAssertTrue(app.buttons["Delete all data"].exists,
                      "deleting recorded data must be reachable")
        XCTAssertTrue(app.buttons["Export runs for calibration"].exists,
                      "calibration export must be reachable")
    }

    func testSettingsDeclaresTheScoreProvisional() throws {
        // An honesty rule with a UI consequence: the absolute score stays
        // labelled provisional until the anchors are recalibrated from real runs.
        app.tabBars.buttons["Settings"].tap()
        let provisional = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'provisional'")
        ).firstMatch
        XCTAssertTrue(provisional.waitForExistence(timeout: 15),
                      "settings must state that the carving score is provisional")
    }

    func testDeleteAllDataAsksBeforeDestroying() throws {
        app.tabBars.buttons["Settings"].tap()
        let deleteButton = app.buttons["Delete all data"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 15))
        deleteButton.tap()

        // A confirmation dialog presents as an action sheet on iPhone, so the
        // buttons may sit under the sheet rather than the app root.
        let confirm = firstButton(labeled: "Delete everything")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "an irreversible delete must confirm first")

        let cancel = firstButton(labeled: "Keep my data")
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()

        // Dismissal is animated, so wait for it rather than sampling immediately.
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10),
                      "cancelling should dismiss the dialog without deleting")
    }

    /// Finds a button by label whether it is presented at the app root or inside
    /// a sheet.
    private func firstButton(labeled label: String) -> XCUIElement {
        let inSheet = app.sheets.buttons[label]
        return inSheet.exists ? inSheet : app.buttons[label]
    }

    // MARK: - Degraded capture

    func testCaptureStatusReportsPermissionState() throws {
        // The simulator grants no location authorization, so the app should be
        // reporting a degraded capture state rather than implying all is well.
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Location"].waitForExistence(timeout: 15),
                      "capture status should report the location permission state")
        XCTAssertTrue(app.staticTexts["Barometer"].exists,
                      "capture status should report whether vertical can be measured")
    }
}
