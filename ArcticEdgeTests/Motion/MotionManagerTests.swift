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
    // handler is stored to confirm startDeviceMotionUpdates was called with a handler.
    // NOTE: CMDeviceMotion() cannot be safely default-initialized in the simulator
    // (its internal data pointer is nil, causing EXC_BAD_ACCESS on field access).
    // Tests that need to inject frames should call manager.receive() directly instead
    // of invoking this handler with CMDeviceMotion().
    nonisolated(unsafe) var handler: CMDeviceMotionHandler?

    nonisolated func startDeviceMotionUpdates(
        to queue: OperationQueue,
        withHandler handler: @escaping CMDeviceMotionHandler
    ) {
        startCallCount += 1
        self.handler = handler
    }

    nonisolated func stopDeviceMotionUpdates() {
        stopCallCount += 1
    }
}

@Suite("MotionManager Tests")
struct MotionManagerTests {

    // Helper to create a MotionManager with a mock data source and an exposed RingBuffer.
    private func makeManager() -> (MotionManager, MockMotionDataSource, RingBuffer) {
        let mockSource = MockMotionDataSource()
        let ringBuffer = RingBuffer()
        let manager = MotionManager(dataSource: mockSource, ringBuffer: ringBuffer)
        return (manager, mockSource, ringBuffer)
    }

    @Test("startUpdates stores handler and emits 3 FilteredFrames into RingBuffer")
    func testStartEmitsFrames() async throws {
        let (manager, mockSource, ringBuffer) = makeManager()
        let runID = UUID()
        await manager.startUpdates(runID: runID)

        #expect(mockSource.startCallCount == 1, "startDeviceMotionUpdates should be called exactly once")
        #expect(mockSource.deviceMotionUpdateInterval == 0.01, "interval should be 0.01 for 100Hz")
        #expect(mockSource.handler != nil, "startDeviceMotionUpdates should have stored a handler")

        // CMDeviceMotion() cannot be safely used in the simulator -- its internal data
        // pointer is nil and accessing any field causes EXC_BAD_ACCESS (SIGSEGV at 0x8).
        // Instead, inject frames through the internal receive() path, which is the same
        // code path the production handler calls after extracting primitives from CMDeviceMotion.
        await manager.receive(
            timestamp: 0.0, runID: runID,
            pitch: 0, roll: 0, yaw: 0,
            userAccelX: 0, userAccelY: 0, userAccelZ: 0,
            gravityX: 0, gravityY: 0, gravityZ: 0,
            rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0
        )
        await manager.receive(
            timestamp: 0.01, runID: runID,
            pitch: 0, roll: 0, yaw: 0,
            userAccelX: 0, userAccelY: 0, userAccelZ: 0,
            gravityX: 0, gravityY: 0, gravityZ: 0,
            rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0
        )
        await manager.receive(
            timestamp: 0.02, runID: runID,
            pitch: 0, roll: 0, yaw: 0,
            userAccelX: 0, userAccelY: 0, userAccelZ: 0,
            gravityX: 0, gravityY: 0, gravityZ: 0,
            rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0
        )

        let count = await ringBuffer.count
        #expect(count == 3, "RingBuffer should contain 3 frames after 3 receive() calls, got \(count)")
    }

    @Test("adjustSampleRate for nominal thermal state sets interval to 0.01 (100Hz)")
    func testThermalNominalIs100Hz() async {
        let (manager, mockSource, _) = makeManager()
        await manager.adjustSampleRate(for: .nominal)
        #expect(
            mockSource.deviceMotionUpdateInterval == 0.01,
            "Nominal thermal state should set interval to 0.01 (100Hz), got \(mockSource.deviceMotionUpdateInterval)"
        )
    }

    @Test("adjustSampleRate for serious thermal state sets interval to 0.02 (50Hz)")
    func testThermalSeriousIs50Hz() async {
        let (manager, mockSource, _) = makeManager()
        await manager.adjustSampleRate(for: .serious)
        #expect(
            mockSource.deviceMotionUpdateInterval == 0.02,
            "Serious thermal state should set interval to 0.02 (50Hz), got \(mockSource.deviceMotionUpdateInterval)"
        )
    }

    @Test("adjustSampleRate for critical thermal state sets interval to 0.04 (25Hz)")
    func testThermalCriticalIs25Hz() async {
        let (manager, mockSource, _) = makeManager()
        await manager.adjustSampleRate(for: .critical)
        #expect(
            mockSource.deviceMotionUpdateInterval == 0.04,
            "Critical thermal state should set interval to 0.04 (25Hz), got \(mockSource.deviceMotionUpdateInterval)"
        )
    }
}
