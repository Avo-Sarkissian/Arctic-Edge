// ArcticEdgeUITests.swift
// ArcticEdgeUITests
//
// Replaces the Xcode template stubs (testExample, testLaunchPerformance) with
// checks on flows a skier actually touches. These run with no permission
// granted, which is deliberate: the denied path is the one most likely to break
// silently, and it used to produce a screen that recorded nothing while saying
// nothing.
//
// Queries go through accessibility identifiers rather than visible copy, so they
// are cheap and survive copy changes.
//
// KNOWN ISSUE (2026-08-01): three cases fail locally with
// "Failed to get matching snapshots: process main thread busy for 30.0s" on the
// first app launch of each test class. The app itself is healthy: launched
// directly via simctl it is up in about a second with no hang, no crash, and
// CoreLocation initialising normally. The same simulator has been returning
// "Application failed preflight checks" for the test runner all session, so this
// looks like a degraded CoreSimulator rather than an app defect. CI runs on a
// clean runner and is the arbiter. Do not add sleeps to work around it: if the
// failure reproduces on CI, it is real and the app needs profiling.

import XCTest

@MainActor
final class ArcticEdgeUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Cold launch on a simulator can take a while: the SwiftData store is
    /// created from scratch with three indexes on first run. Waits here are
    /// generous so a slow first launch reads as slow, not as broken.
    private let launchTimeout: TimeInterval = 90

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Skip the permission primer so tests land on the tab bar directly.
        app.launchArguments += ["-UITestSkipOnboarding", "YES"]
        app.launch()
        // Do not start querying until the shell is up.
        _ = app.tabBars.buttons["Settings"].waitForExistence(timeout: launchTimeout)
    }

    override func tearDown() async throws {
        app = nil
    }

    // MARK: - Helpers

    private func openTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.tabBars.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: launchTimeout), "missing \(name) tab", file: file, line: line)
        button.tap()
    }

    /// Finds a button by identifier whether it is presented inside a sheet or at
    /// the app root. A confirmation dialog's cancel button is commonly placed
    /// outside the sheet element on iPhone.
    private func dialogButton(_ identifier: String, labeled label: String) -> XCUIElement {
        let inSheet = app.sheets.buttons[identifier]
        if inSheet.exists { return inSheet }
        let byIdentifier = app.buttons[identifier]
        if byIdentifier.exists { return byIdentifier }
        let inSheetByLabel = app.sheets.buttons[label]
        if inSheetByLabel.exists { return inSheetByLabel }
        return app.buttons[label]
    }

    // MARK: - Navigation

    func testAllThreeTabsAreReachable() throws {
        for tab in ["Today", "History", "Settings"] {
            openTab(tab)
        }
        // Landing on Settings last, its content should be present.
        XCTAssertTrue(app.otherElements["settings.frameCount"].waitForExistence(timeout: 20)
                      || app.staticTexts["Raw motion frames"].waitForExistence(timeout: 5),
                      "the last tab tapped should have rendered its content")
    }

    func testTodayTabShowsTheSessionControl() throws {
        openTab("Today")
        let startButton = app.buttons["today.sessionAction"]
        XCTAssertTrue(startButton.waitForExistence(timeout: launchTimeout),
                      "Start Day is the primary action and must be present")
        XCTAssertTrue(startButton.isHittable)
    }

    // MARK: - Empty states

    func testHistoryShowsAnEmptyStateRatherThanABlankScreen() throws {
        openTab("History")
        // Either the empty state or at least one recorded run is fine. A blank
        // screen with neither is not.
        let emptyState = app.staticTexts["history.emptyState"]
        let anyRun = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Run '")
        ).firstMatch
        XCTAssertTrue(
            emptyState.waitForExistence(timeout: 20) || anyRun.waitForExistence(timeout: 5),
            "history should show either runs or an explanation of why there are none"
        )
    }

    // MARK: - Settings and honesty rules

    func testSettingsExposesDataControl() throws {
        openTab("Settings")
        XCTAssertTrue(app.buttons["settings.deleteAll"].waitForExistence(timeout: launchTimeout),
                      "deleting recorded data must be reachable")
        XCTAssertTrue(app.buttons["settings.exportCalibration"].exists,
                      "calibration export must be reachable")
        XCTAssertTrue(app.staticTexts["Raw motion frames"].exists,
                      "the storage readout should be visible")
    }

    func testSettingsDeclaresTheScoreProvisional() throws {
        // An honesty rule with a UI consequence: the absolute score stays
        // labelled provisional until the anchors are recalibrated from real runs.
        openTab("Settings")
        let version = app.staticTexts["settings.modelVersion"]
        XCTAssertTrue(version.waitForExistence(timeout: launchTimeout),
                      "settings should show the scoring model version")
        XCTAssertTrue(version.label.localizedCaseInsensitiveContains("provisional"),
                      "the shipped model version must carry the provisional suffix, got \(version.label)")
    }

    func testDeleteAllDataAsksBeforeDestroying() throws {
        openTab("Settings")
        let deleteButton = app.buttons["settings.deleteAll"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: launchTimeout))
        deleteButton.tap()

        // A confirmation dialog presents as an action sheet, so wait for the
        // sheet itself before querying inside it.
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 20),
                      "an irreversible delete must confirm first")

        let confirm = sheet.buttons["settings.confirmDelete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10),
                      "the confirmation should offer a destructive action")

        let cancel = dialogButton("settings.cancelDelete", labeled: "Keep my data")
        XCTAssertTrue(cancel.waitForExistence(timeout: 10),
                      "the confirmation should be cancellable")
        cancel.tap()

        // Dismissal is animated, so wait for it rather than sampling immediately.
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 15),
                      "cancelling should dismiss the dialog without deleting")
    }

    // MARK: - Degraded capture

    func testCaptureStatusReportsPermissionState() throws {
        // The simulator grants no location authorization, so the app should be
        // reporting a degraded capture state rather than implying all is well.
        openTab("Settings")
        XCTAssertTrue(app.staticTexts["Location"].waitForExistence(timeout: launchTimeout),
                      "capture status should report the location permission state")
        XCTAssertTrue(app.staticTexts["Barometer"].exists,
                      "capture status should report whether vertical can be measured")
    }
}
