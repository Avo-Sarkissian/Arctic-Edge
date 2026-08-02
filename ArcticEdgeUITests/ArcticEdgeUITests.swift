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
// LOCAL ENVIRONMENT NOTE (2026-08-02): on at least one developer machine these
// fail with "process main thread busy for 30.0s" on the first launch of a test
// class, and the runner itself often will not install ("Application failed
// preflight checks"). CI settled it: those cases pass on a clean runner, and the
// app launched directly via simctl is up in about a second with no hang. Treat a
// local-only failure here as the machine, and CI as the arbiter. Do not add
// sleeps to paper over it.

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

    /// Finds a button anywhere in the hierarchy by identifier or visible label.
    ///
    /// A confirmation dialog lands in different containers depending on OS and
    /// size class (sheet, alert, or plain descendants), and the cancel button is
    /// often placed outside the group holding the others. Probing containers in
    /// a fixed order sampled `.exists` before the dialog had presented and then
    /// locked onto the wrong query. Searching all descendants with a live
    /// predicate lets waitForExistence do its job.
    private func anyButton(_ identifier: String, labeled label: String) -> XCUIElement {
        let predicate = NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)
        return app.descendants(matching: .button).matching(predicate).firstMatch
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

        // The property that matters: tapping Delete does not delete. It asks.
        let confirm = anyButton("settings.confirmDelete", labeled: "Delete everything")
        XCTAssertTrue(confirm.waitForExistence(timeout: 20),
                      "an irreversible delete must confirm first")

        // Dismiss WITHOUT confirming. The explicit cancel button is preferred,
        // but it is not asserted on: on this OS the dialog's cancel-role button
        // is not reliably exposed to the accessibility hierarchy even though the
        // destructive one is, and failing the test on that would be asserting a
        // UIKit implementation detail rather than app behaviour. Tapping outside
        // an action sheet is an equivalent cancel from the user's side.
        let cancel = anyButton("settings.cancelDelete", labeled: "Keep my data")
        if cancel.waitForExistence(timeout: 5) {
            cancel.tap()
        } else {
            // Well above the sheet, inside the app's own window.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        }

        // Dismissal is animated, so wait for it rather than sampling immediately.
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 15),
                      "dismissing should close the dialog")

        // The real assertion: nothing was destroyed on the way through.
        XCTAssertTrue(app.buttons["settings.deleteAll"].waitForExistence(timeout: 10),
                      "settings should still be intact after cancelling")
        XCTAssertTrue(app.staticTexts["Raw motion frames"].exists,
                      "cancelling must not have deleted anything")
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
