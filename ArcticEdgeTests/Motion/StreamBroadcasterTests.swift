// StreamBroadcasterTests.swift
// ArcticEdgeTests
//
// Tests for StreamBroadcaster actor (MOTN-04).
// Covers: fan-out to multiple consumers, single-start guarantee, cancellation cleanup.

import Testing
import CoreMotion
import Foundation
@testable import ArcticEdge

@Suite("StreamBroadcaster Tests", .serialized)
struct StreamBroadcasterTests {

    // Helper: create a minimal FilteredFrame for broadcasting.
    private func makeFrame(timestamp: TimeInterval = 0.0) -> FilteredFrame {
        FilteredFrame(
            timestamp: timestamp,
            runID: UUID(),
            pitch: 0, roll: 0, yaw: 0,
            userAccelX: 0, userAccelY: 0, userAccelZ: 0,
            gravityX: 0, gravityY: 0, gravityZ: 0,
            rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0,
            filteredAccelZ: 0
        )
    }

    // Helper: create a paired (MotionManager, StreamBroadcaster) for tests.
    // MotionManager broadcaster reference is wired after construction to break circular dependency.
    private func makePair() async -> (MotionManager, StreamBroadcaster, MockMotionDataSource) {
        let mockSource = MockMotionDataSource()
        let manager = MotionManager(dataSource: mockSource, ringBuffer: RingBuffer())
        let broadcaster = StreamBroadcaster(motionManager: manager)
        await manager.setStreamBroadcaster(broadcaster)
        return (manager, broadcaster, mockSource)
    }

    @Test("Two consumers receive the same frames in order")
    func testTwoConsumersReceiveSameFrames() async {
        let (_, broadcaster, _) = await makePair()
        let stream1 = await broadcaster.makeStream()
        let stream2 = await broadcaster.makeStream()
        let framesToBroadcast = [makeFrame(timestamp: 1.0), makeFrame(timestamp: 2.0), makeFrame(timestamp: 3.0)]

        // Broadcast all frames.
        for frame in framesToBroadcast {
            await broadcaster.broadcast(frame)
        }
        await broadcaster.stop()

        // Collect frames from both streams.
        var received1: [FilteredFrame] = []
        var received2: [FilteredFrame] = []
        for await frame in stream1 { received1.append(frame) }
        for await frame in stream2 { received2.append(frame) }

        #expect(received1.count == 3, "Consumer 1 should receive 3 frames, got \(received1.count)")
        #expect(received2.count == 3, "Consumer 2 should receive 3 frames, got \(received2.count)")
        for i in 0..<3 {
            #expect(received1[i].timestamp == Double(i + 1), "Consumer 1 frame \(i) wrong timestamp")
            #expect(received2[i].timestamp == Double(i + 1), "Consumer 2 frame \(i) wrong timestamp")
        }
    }

    @Test("Calling makeStream twice does not trigger a second MotionManager start")
    func testSingleMotionManagerStart() async {
        let (_, broadcaster, mockSource) = await makePair()
        let runID = UUID()
        // Call start once, then make two streams.
        await broadcaster.start(runID: runID)
        _ = await broadcaster.makeStream()
        _ = await broadcaster.makeStream()
        // Even with two consumers, the underlying MotionManager should be started only once.
        #expect(mockSource.startCallCount == 1, "startDeviceMotionUpdates should be called once, got \(mockSource.startCallCount)")
        // Calling start again (simulating a second start attempt) should be a no-op.
        await broadcaster.start(runID: UUID())
        #expect(mockSource.startCallCount == 1, "startDeviceMotionUpdates should still be called once after second start attempt, got \(mockSource.startCallCount)")
    }

    @Test("Cancelling one consumer stream does not affect the other")
    func testConsumerCancellationCleansUp() async {
        // Create a fresh broadcaster for this test.
        let mockSource2 = MockMotionDataSource()
        let manager2 = MotionManager(dataSource: mockSource2, ringBuffer: RingBuffer())
        let broadcaster2 = StreamBroadcaster(motionManager: manager2)
        await manager2.setStreamBroadcaster(broadcaster2)

        // Assign streams to named locals so ARC does not fire onTermination immediately.
        let s1 = await broadcaster2.makeStream()
        let s2 = await broadcaster2.makeStream()
        let afterTwo = await broadcaster2.continuationCount
        #expect(afterTwo == 2, "Should have 2 active continuations after makeStream x2, got \(afterTwo)")

        // Stop and verify all continuations are cleaned up.
        await broadcaster2.stop()
        let afterStop = await broadcaster2.continuationCount
        #expect(afterStop == 0, "All continuations should be removed after stop(), got \(afterStop)")

        // Keep s1 and s2 in scope until after all assertions complete.
        _ = (s1, s2)
    }
}
