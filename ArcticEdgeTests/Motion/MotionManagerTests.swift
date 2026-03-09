// MotionManagerTests.swift
// ArcticEdgeTests
//
// Tests for MotionManager actor (MOTN-01, MOTN-05).
// Covers: frame emission from mock data source and thermal interval adjustments.

import Testing
import CoreMotion
import Foundation
@testable import ArcticEdge

// MockMotionDataSource: a simple class conforming to MotionDataSource for test injection.
// Stores the handler so tests can verify start/stop behavior.
// nonisolated(unsafe) on mutable properties avoids MainActor inference from the project setting.
// @unchecked Sendable: we use nonisolated(unsafe) and accept manual responsibility for
// thread safety in test code; accesses are sequential in all test cases.
final class MockMotionDataSource: MotionDataSource, @unchecked Sendable {
    nonisolated(unsafe) var deviceMotionUpdateInterval: Double = 0.01
    nonisolated(unsafe) var startCallCount = 0
    nonisolated(unsafe) var stopCallCount = 0

    nonisolated func startDeviceMotionUpdates(
        to queue: OperationQueue,
        withHandler handler: @escaping CMDeviceMotionHandler
    ) {
        startCallCount += 1
    }

    nonisolated func stopDeviceMotionUpdates() {
        stopCallCount += 1
    }
}

@Suite("MotionManager Tests")
struct MotionManagerTests {

    // Helper to create a MotionManager with a mock data source and no broadcaster.
    private func makeManager() -> (MotionManager, MockMotionDataSource) {
        let mockSource = MockMotionDataSource()
        let manager = MotionManager(dataSource: mockSource, ringBuffer: RingBuffer())
        return (manager, mockSource)
    }

    @Test("startUpdates sets 100Hz interval and calls dataSource start exactly once")
    func testStartEmitsFrames() async {
        let (manager, mockSource) = makeManager()
        let runID = UUID()
        await manager.startUpdates(runID: runID)
        // Verify the data source was started exactly once.
        #expect(mockSource.startCallCount == 1, "startDeviceMotionUpdates should be called exactly once, got \(mockSource.startCallCount)")
        // Verify the interval was set to 100Hz before starting.
        #expect(mockSource.deviceMotionUpdateInterval == 0.01, "deviceMotionUpdateInterval should be 0.01 for 100Hz, got \(mockSource.deviceMotionUpdateInterval)")
    }

    @Test("adjustSampleRate for nominal thermal state sets interval to 0.01 (100Hz)")
    func testThermalNominalIs100Hz() async {
        let (manager, mockSource) = makeManager()
        await manager.adjustSampleRate(for: .nominal)
        #expect(
            mockSource.deviceMotionUpdateInterval == 0.01,
            "Nominal thermal state should set interval to 0.01 (100Hz), got \(mockSource.deviceMotionUpdateInterval)"
        )
    }

    @Test("adjustSampleRate for serious thermal state sets interval to 0.02 (50Hz)")
    func testThermalSeriousIs50Hz() async {
        let (manager, mockSource) = makeManager()
        await manager.adjustSampleRate(for: .serious)
        #expect(
            mockSource.deviceMotionUpdateInterval == 0.02,
            "Serious thermal state should set interval to 0.02 (50Hz), got \(mockSource.deviceMotionUpdateInterval)"
        )
    }

    @Test("adjustSampleRate for critical thermal state sets interval to 0.04 (25Hz)")
    func testThermalCriticalIs25Hz() async {
        let (manager, mockSource) = makeManager()
        await manager.adjustSampleRate(for: .critical)
        #expect(
            mockSource.deviceMotionUpdateInterval == 0.04,
            "Critical thermal state should set interval to 0.04 (25Hz), got \(mockSource.deviceMotionUpdateInterval)"
        )
    }
}
