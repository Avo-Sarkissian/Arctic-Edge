// ActivityClassifierTests.swift
// ArcticEdgeTests
//
// TDD GREEN phase for ActivityClassifier — all 10 stubs from plan 02-01 are now implemented.
// Tests use MockPersistenceService (local actor) and a TestClock actor for deterministic
// hysteresis control without Task.sleep.
//
// Requirements covered:
//   DETC-01: Signal fusion (testSkiingClassification, testChairliftRequiresAllThreeSignals,
//             testTwoOfThreeInsufficientForChairlift, testGPSBlackoutSustainsChairlift)
//   DETC-02: Hysteresis (testShortSignalDoesNotTransition, testFullHysteresisWindowTriggersTransition,
//             testBriefStopDoesNotEndRun)
//   DETC-03: RunRecord lifecycle (testConfirmedSkiingCreatesRunRecord,
//             testTransitionFinalizesRunRecord, testEndDayFinalizesOpenRun)

import Testing
import Foundation
import CoreMotion
@testable import ArcticEdge

// MARK: - MockPersistenceService

/// Lightweight actor recording createRunRecord / finalizeRunRecord calls.
/// Conforms to PersistenceServiceProtocol — does NOT require SwiftData.
actor MockPersistenceService: PersistenceServiceProtocol {
    struct CreateCall: Sendable {
        let runID: UUID
        let startTimestamp: Date
    }
    struct FinalizeCall: Sendable {
        let runID: UUID
        let endTimestamp: Date
    }

    private(set) var createCalls: [CreateCall] = []
    private(set) var finalizeCalls: [FinalizeCall] = []

    func createRunRecord(runID: UUID, startTimestamp: Date) throws {
        createCalls.append(CreateCall(runID: runID, startTimestamp: startTimestamp))
    }

    func finalizeRunRecord(runID: UUID, endTimestamp: Date) throws {
        finalizeCalls.append(FinalizeCall(runID: runID, endTimestamp: endTimestamp))
    }
}

// MARK: - TestClock

/// Actor holding a mutable Date that can be advanced by tests.
/// The `now()` method is the @Sendable clock closure passed to ActivityClassifier.
actor TestClock {
    private var current: Date

    init(startingAt: Date = Date(timeIntervalSince1970: 0)) {
        current = startingAt
    }

    func advance(to date: Date) {
        current = date
    }

    func advance(by seconds: Double) {
        current = current.addingTimeInterval(seconds)
    }

    func now() -> Date { current }

    /// Returns a @Sendable closure that reads the current time from this actor.
    /// Because the closure captures `self` (the actor), reads are actor-isolated
    /// and safe under strict concurrency.
    nonisolated func makeClock() -> @Sendable () -> Date {
        { [self] in
            // Synchronous actor state read: safe because Date is Sendable and
            // we accept that the clock value was current at call time.
            // Using assumeIsolated is the correct pattern here — the clock closure
            // is always called from within ActivityClassifier's actor isolation,
            // which is distinct from MainActor, so we can't guarantee same executor.
            // Instead, we keep a simple nonisolated(unsafe) cache updated via advance().
            self.unsafeCurrentDate
        }
    }

    // nonisolated(unsafe) allows synchronous read from the @Sendable closure.
    // Write access is actor-isolated via advance(to:) / advance(by:).
    nonisolated(unsafe) var unsafeCurrentDate: Date = Date(timeIntervalSince1970: 0)

    func syncCache() {
        unsafeCurrentDate = current
    }
}

// MARK: - Helpers

/// Builds a skiing-signal FilteredFrame (high variance) at a given timestamp.
private func skiingFrame(timestamp: TimeInterval = 0) -> FilteredFrame {
    // userAccelX/Y/Z = 0.5g each → magnitude ≈ 0.866g.
    FilteredFrame(
        timestamp: timestamp,
        runID: UUID(),
        pitch: 0, roll: 0, yaw: 0,
        userAccelX: 0.5, userAccelY: 0.5, userAccelZ: 0.5,
        gravityX: 0, gravityY: 0, gravityZ: -1,
        rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0,
        filteredAccelZ: 0.5
    )
}

/// Alternate skiing frame with slightly different magnitude to produce variance in the window.
private func skiingFrameB(timestamp: TimeInterval = 0) -> FilteredFrame {
    FilteredFrame(
        timestamp: timestamp,
        runID: UUID(),
        pitch: 0, roll: 0, yaw: 0,
        userAccelX: 0.3, userAccelY: 0.3, userAccelZ: 0.3,
        gravityX: 0, gravityY: 0, gravityZ: -1,
        rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0,
        filteredAccelZ: 0.3
    )
}

/// Builds a low-variance FilteredFrame (smooth chairlift ride).
private func chairliftFrame(timestamp: TimeInterval = 0) -> FilteredFrame {
    FilteredFrame(
        timestamp: timestamp,
        runID: UUID(),
        pitch: 0, roll: 0, yaw: 0,
        userAccelX: 0.001, userAccelY: 0.001, userAccelZ: 0.001,
        gravityX: 0, gravityY: 0, gravityZ: -1,
        rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0,
        filteredAccelZ: 0.001
    )
}

/// Alternate chairlift frame with slightly different magnitude to produce non-zero variance
/// that stays below the 0.01 g² threshold.
private func chairliftFrameB(timestamp: TimeInterval = 0) -> FilteredFrame {
    FilteredFrame(
        timestamp: timestamp,
        runID: UUID(),
        pitch: 0, roll: 0, yaw: 0,
        userAccelX: 0.002, userAccelY: 0.002, userAccelZ: 0.002,
        gravityX: 0, gravityY: 0, gravityZ: -1,
        rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0,
        filteredAccelZ: 0.002
    )
}

/// Automotive ActivitySnapshot with medium confidence.
private func automotiveActivity() -> ActivitySnapshot {
    ActivitySnapshot(automotive: true, unknown: false, confidence: .medium)
}

/// Non-automotive ActivitySnapshot (running, high confidence).
private func skiingActivity() -> ActivitySnapshot {
    ActivitySnapshot(running: true, unknown: false, confidence: .high)
}

/// GPSReading at chairlift speed (3.5 m/s).
private func liftGPS() -> GPSReading {
    GPSReading(speed: 3.5, horizontalAccuracy: 5.0, timestamp: Date())
}

/// GPSReading at skiing speed (8 m/s).
private func skiingGPS() -> GPSReading {
    GPSReading(speed: 8.0, horizontalAccuracy: 5.0, timestamp: Date())
}

/// Fill the variance window with alternating frames to produce high variance (> 0.005 g²).
private func fillHighVarianceWindow(classifier: ActivityClassifier, windowSize: Int = 50, atTime: TimeInterval = 0) async {
    for i in 0..<windowSize {
        let t = atTime + Double(i) * 0.001
        let frame = (i % 2 == 0) ? skiingFrame(timestamp: t) : skiingFrameB(timestamp: t)
        await classifier.processFrame(frame)
    }
}

/// Fill the variance window with chairlift frames producing low variance (< 0.01 g²).
private func fillLowVarianceWindow(classifier: ActivityClassifier, windowSize: Int = 5, atTime: TimeInterval = 0) async {
    for i in 0..<windowSize {
        let t = atTime + Double(i) * 0.001
        let frame = (i % 2 == 0) ? chairliftFrame(timestamp: t) : chairliftFrameB(timestamp: t)
        await classifier.processFrame(frame)
    }
}

// MARK: - Suite

@Suite("ActivityClassifier")
struct ActivityClassifierTests {

    // MARK: - DETC-01: Signal fusion

    /// Skiing signals held for >= 3s transitions from chairlift → skiing.
    @Test func testSkiingClassification() async {
        let clock = TestClock(startingAt: Date(timeIntervalSince1970: 0))
        await clock.syncCache()
        let classifier = ActivityClassifier(
            skiingOnsetSeconds: 3.0,
            varianceWindowSize: 50,
            clock: clock.makeClock()
        )
        await classifier.setState(.chairlift)
        await classifier.setGPS(skiingGPS())
        await classifier.setActivity(skiingActivity())

        // Fill variance window while clock stays at t=0 (onset not yet started).
        await fillHighVarianceWindow(classifier: classifier, windowSize: 50)

        // Advance clock to t=0.01 and inject one frame to begin onset accumulation.
        await clock.advance(to: Date(timeIntervalSince1970: 0.01))
        await clock.syncCache()
        await classifier.processFrame(skiingFrame(timestamp: 0.01))

        // Advance clock past onset window and confirm.
        await clock.advance(to: Date(timeIntervalSince1970: 3.02))
        await clock.syncCache()
        await classifier.processFrame(skiingFrame(timestamp: 3.02))

        let state = await classifier.state
        #expect(state == .skiing)
    }

    /// All three chairlift signals must be present to end a run.
    @Test func testChairliftRequiresAllThreeSignals() async {
        let clock = TestClock(startingAt: Date(timeIntervalSince1970: 0))
        await clock.syncCache()
        let classifier = ActivityClassifier(
            runEndSeconds: 2.0,
            varianceWindowSize: 5,
            clock: clock.makeClock()
        )
        await classifier.setState(.skiing)
        await classifier.setGPS(liftGPS())
        await classifier.setActivity(automotiveActivity())

        // Fill variance window with low-variance frames.
        await fillLowVarianceWindow(classifier: classifier, windowSize: 5)

        // Advance clock to t=0.1 (onset begins) then to t=2.1 (beyond run-end window).
        await clock.advance(to: Date(timeIntervalSince1970: 0.1))
        await clock.syncCache()
        await classifier.processFrame(chairliftFrame(timestamp: 0.1))

        await clock.advance(to: Date(timeIntervalSince1970: 2.2))
        await clock.syncCache()
        await classifier.processFrame(chairliftFrame(timestamp: 2.2))

        let state = await classifier.state
        #expect(state == .chairlift)
    }

    /// Two of three chairlift signals is insufficient to end a run.
    @Test func testTwoOfThreeInsufficientForChairlift() async {
        let clock = TestClock(startingAt: Date(timeIntervalSince1970: 0))
        await clock.syncCache()
        let classifier = ActivityClassifier(
            runEndSeconds: 2.0,
            varianceWindowSize: 5,
            clock: clock.makeClock()
        )
        await classifier.setState(.skiing)

        // Automotive + lift speed, but high variance (third signal missing).
        await classifier.setGPS(liftGPS())
        await classifier.setActivity(automotiveActivity())

        // High-variance frames → chairliftSignalActive returns false.
        await fillHighVarianceWindow(classifier: classifier, windowSize: 5)

        await clock.advance(to: Date(timeIntervalSince1970: 3.0))
        await clock.syncCache()
        await classifier.processFrame(skiingFrame(timestamp: 3.0))

        let state = await classifier.state
        #expect(state == .skiing)
    }

    /// GPS blackout while in chairlift state: GPS gate waived, state sustained by IMU + automotive.
    @Test func testGPSBlackoutSustainsChairlift() async {
        let clock = TestClock(startingAt: Date(timeIntervalSince1970: 0))
        await clock.syncCache()
        let classifier = ActivityClassifier(
            runEndSeconds: 2.0,
            varianceWindowSize: 5,
            clock: clock.makeClock()
        )
        await classifier.setState(.chairlift)

        // GPS blackout: latestGPS == nil.
        await classifier.setGPS(nil)
        // Automotive activity blocks skiingSignalActive (notAutomotive = false).
        await classifier.setActivity(automotiveActivity())

        // Low-variance frames.
        await fillLowVarianceWindow(classifier: classifier, windowSize: 5)

        // Because automotiveActivity() makes skiingSignalActive() return false,
        // no onset accumulation occurs even if GPS is absent. State stays .chairlift.
        let state = await classifier.state
        #expect(state == .chairlift)
    }

    // MARK: - DETC-02: Hysteresis

    /// Skiing signals held for < 3s must NOT trigger transition.
    @Test func testShortSignalDoesNotTransition() async {
        let clock = TestClock(startingAt: Date(timeIntervalSince1970: 0))
        await clock.syncCache()
        let classifier = ActivityClassifier(
            skiingOnsetSeconds: 3.0,
            varianceWindowSize: 50,
            clock: clock.makeClock()
        )
        await classifier.setState(.chairlift)
        await classifier.setGPS(skiingGPS())
        await classifier.setActivity(skiingActivity())

        // Fill variance window.
        await fillHighVarianceWindow(classifier: classifier, windowSize: 50)

        // Begin onset accumulation at t=0.01.
        await clock.advance(to: Date(timeIntervalSince1970: 0.01))
        await clock.syncCache()
        await classifier.processFrame(skiingFrame(timestamp: 0.01))

        // Only 2.9s elapsed — below onset threshold.
        await clock.advance(to: Date(timeIntervalSince1970: 2.91))
        await clock.syncCache()
        await classifier.processFrame(skiingFrame(timestamp: 2.91))

        let state = await classifier.state
        #expect(state == .chairlift)
    }

    /// Skiing signals held for >= 3s MUST trigger transition to skiing.
    @Test func testFullHysteresisWindowTriggersTransition() async {
        let clock = TestClock(startingAt: Date(timeIntervalSince1970: 0))
        await clock.syncCache()
        let classifier = ActivityClassifier(
            skiingOnsetSeconds: 3.0,
            varianceWindowSize: 50,
            clock: clock.makeClock()
        )
        await classifier.setState(.chairlift)
        await classifier.setGPS(skiingGPS())
        await classifier.setActivity(skiingActivity())

        // Fill variance window.
        await fillHighVarianceWindow(classifier: classifier, windowSize: 50)

        // Begin onset at t=0.01.
        await clock.advance(to: Date(timeIntervalSince1970: 0.01))
        await clock.syncCache()
        await classifier.processFrame(skiingFrame(timestamp: 0.01))

        // Exactly 3.0s elapsed (0.01 + 3.0 = 3.01 > 3.0) → meets threshold.
        await clock.advance(to: Date(timeIntervalSince1970: 3.01))
        await clock.syncCache()
        await classifier.processFrame(skiingFrame(timestamp: 3.01))

        let state = await classifier.state
        #expect(state == .skiing)
    }

    /// A brief stop mid-run (stationary, not all three chairlift signals) must not end the run.
    @Test func testBriefStopDoesNotEndRun() async {
        let clock = TestClock(startingAt: Date(timeIntervalSince1970: 0))
        await clock.syncCache()
        let classifier = ActivityClassifier(
            runEndSeconds: 2.0,
            varianceWindowSize: 5,
            clock: clock.makeClock()
        )
        await classifier.setState(.skiing)

        // GPS speed = 0 (outside lift range 0.5–7.0 m/s), not automotive.
        // Only one signal potentially active (low variance if stopped). But automotive = false
        // means isAutomotive = false → chairliftSignalActive() = false.
        let stopGPS = GPSReading(speed: 0.0, horizontalAccuracy: 5.0, timestamp: Date())
        await classifier.setGPS(stopGPS)
        await classifier.setActivity(ActivitySnapshot(stationary: true, unknown: false, confidence: .high))

        // High-variance frames (skier is stopped but equipment vibrating, or just use any frame).
        await fillHighVarianceWindow(classifier: classifier, windowSize: 5)

        await clock.advance(to: Date(timeIntervalSince1970: 3.0))
        await clock.syncCache()
        await classifier.processFrame(skiingFrame(timestamp: 3.0))

        let state = await classifier.state
        #expect(state == .skiing)
    }

    // MARK: - DETC-03: RunRecord lifecycle

    /// Confirmed skiing transition must call createRunRecord exactly once.
    @Test func testConfirmedSkiingCreatesRunRecord() async {
        let mock = MockPersistenceService()
        let clock = TestClock(startingAt: Date(timeIntervalSince1970: 0))
        await clock.syncCache()
        let classifier = ActivityClassifier(
            skiingOnsetSeconds: 3.0,
            varianceWindowSize: 50,
            clock: clock.makeClock()
        )
        await classifier.setState(.chairlift)
        await classifier.setPersistence(mock)
        await classifier.setGPS(skiingGPS())
        await classifier.setActivity(skiingActivity())

        // Fill variance window.
        await fillHighVarianceWindow(classifier: classifier, windowSize: 50)

        // Begin onset.
        await clock.advance(to: Date(timeIntervalSince1970: 0.01))
        await clock.syncCache()
        await classifier.processFrame(skiingFrame(timestamp: 0.01))

        // Trigger confirmed transition.
        await clock.advance(to: Date(timeIntervalSince1970: 3.02))
        await clock.syncCache()
        await classifier.processFrame(skiingFrame(timestamp: 3.02))

        // Allow the Task in confirmSkiingTransition to complete.
        await Task.yield()
        await Task.yield()

        let createCount = await mock.createCalls.count
        #expect(createCount == 1)
    }

    /// SKIING → CHAIRLIFT transition must call finalizeRunRecord exactly once.
    @Test func testTransitionFinalizesRunRecord() async {
        let mock = MockPersistenceService()
        let clock = TestClock(startingAt: Date(timeIntervalSince1970: 0))
        await clock.syncCache()
        let classifier = ActivityClassifier(
            runEndSeconds: 2.0,
            varianceWindowSize: 5,
            clock: clock.makeClock()
        )
        await classifier.setState(.skiing)
        await classifier.setCurrentRunID(UUID())
        await classifier.setPersistence(mock)
        await classifier.setGPS(liftGPS())
        await classifier.setActivity(automotiveActivity())

        // Fill variance window with low-variance frames.
        await fillLowVarianceWindow(classifier: classifier, windowSize: 5)

        // Begin run-end evaluation at t=0.1.
        await clock.advance(to: Date(timeIntervalSince1970: 0.1))
        await clock.syncCache()
        await classifier.processFrame(chairliftFrame(timestamp: 0.1))

        // Advance past run-end window.
        await clock.advance(to: Date(timeIntervalSince1970: 2.2))
        await clock.syncCache()
        await classifier.processFrame(chairliftFrame(timestamp: 2.2))

        await Task.yield()
        await Task.yield()

        let finalizeCount = await mock.finalizeCalls.count
        #expect(finalizeCount == 1)
    }

    /// endDay() while in skiing state must finalize any open RunRecord.
    @Test func testEndDayFinalizesOpenRun() async {
        let mock = MockPersistenceService()
        let classifier = ActivityClassifier()
        await classifier.setState(.skiing)
        await classifier.setCurrentRunID(UUID())
        await classifier.endDayWithPersistence(mock)

        let finalizeCount = await mock.finalizeCalls.count
        #expect(finalizeCount == 1)
    }
}
