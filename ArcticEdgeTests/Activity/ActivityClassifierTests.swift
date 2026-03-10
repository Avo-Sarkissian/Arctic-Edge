// ActivityClassifierTests.swift
// ArcticEdgeTests
//
// Wave 0 stub suite for ActivityClassifier — all tests are intentionally RED.
// These stubs compile but fail with #expect(Bool(false)) placeholders.
// Full implementation follows in plan 02-02 (TDD GREEN phase).
//
// Test map mirrors VALIDATION.md per-task requirements:
// DETC-01: Signal fusion (tasks 02-02 and 02-03)
// DETC-02: Hysteresis (task 02-04)
// DETC-03: RunRecord lifecycle (task 02-05)

import Testing

@Suite("ActivityClassifier")
struct ActivityClassifierTests {

    // MARK: - DETC-01: Signal fusion

    @Test func testSkiingClassification() {
        #expect(Bool(false), "stub — implement in plan 02-02")
    }

    @Test func testChairliftRequiresAllThreeSignals() {
        #expect(Bool(false), "stub — implement in plan 02-02")
    }

    @Test func testTwoOfThreeInsufficientForChairlift() {
        #expect(Bool(false), "stub — implement in plan 02-02")
    }

    @Test func testGPSBlackoutSustainsChairlift() {
        #expect(Bool(false), "stub — implement in plan 02-02")
    }

    // MARK: - DETC-02: Hysteresis

    @Test func testShortSignalDoesNotTransition() {
        #expect(Bool(false), "stub — implement in plan 02-02")
    }

    @Test func testFullHysteresisWindowTriggersTransition() {
        #expect(Bool(false), "stub — implement in plan 02-02")
    }

    @Test func testBriefStopDoesNotEndRun() {
        #expect(Bool(false), "stub — implement in plan 02-02")
    }

    // MARK: - DETC-03: RunRecord lifecycle

    @Test func testConfirmedSkiingCreatesRunRecord() {
        #expect(Bool(false), "stub — implement in plan 02-02")
    }

    @Test func testTransitionFinalizesRunRecord() {
        #expect(Bool(false), "stub — implement in plan 02-02")
    }

    @Test func testEndDayFinalizesOpenRun() {
        #expect(Bool(false), "stub — implement in plan 02-02")
    }
}
