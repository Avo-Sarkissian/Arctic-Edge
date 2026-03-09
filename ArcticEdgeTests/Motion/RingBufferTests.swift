// RingBufferTests.swift
// ArcticEdgeTests
//
// Tests for RingBuffer actor (MOTN-03).
// Covers: append/drain atomicity, capacity enforcement, concurrent stress.

import Testing
import Foundation
@testable import ArcticEdge

@Suite("RingBuffer Tests")
struct RingBufferTests {

    // Helper: create a minimal FilteredFrame for testing purposes.
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

    @Test("Drain returns all appended frames")
    func testDrainReturnsAllAppended() async {
        let buffer = RingBuffer()
        let frames = (0..<5).map { makeFrame(timestamp: Double($0)) }
        for frame in frames {
            await buffer.append(frame)
        }
        let drained = await buffer.drain()
        #expect(drained.count == 5, "Expected 5 frames, got \(drained.count)")
        for (i, frame) in drained.enumerated() {
            #expect(frame.timestamp == Double(i), "Frame \(i) has wrong timestamp: \(frame.timestamp)")
        }
    }

    @Test("Drain empties the buffer")
    func testDrainEmptiesBuffer() async {
        let buffer = RingBuffer()
        for i in 0..<3 {
            await buffer.append(makeFrame(timestamp: Double(i)))
        }
        _ = await buffer.drain()
        let count = await buffer.count
        #expect(count == 0, "Buffer should be empty after drain, but count is \(count)")
    }

    @Test("Appending beyond capacity drops oldest frame")
    func testCapacityDropsOldest() async {
        let buffer = RingBuffer()
        // Append 1001 frames to a capacity-1000 buffer.
        for i in 0..<1001 {
            await buffer.append(makeFrame(timestamp: Double(i)))
        }
        let count = await buffer.count
        #expect(count == 1000, "Buffer count should be 1000 after 1001 appends, got \(count)")
        let drained = await buffer.drain()
        // The first frame (timestamp 0.0) should have been dropped; the oldest remaining is timestamp 1.0.
        #expect(drained.first?.timestamp == 1.0, "Oldest remaining frame should have timestamp 1.0, got \(String(describing: drained.first?.timestamp))")
    }

    @Test("Concurrent append and drain never exceed capacity and never crash")
    func testConcurrentAppendAndDrain() async {
        let buffer = RingBuffer()
        // Launch 10 concurrent append tasks, each appending 150 frames.
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<10 {
                group.addTask {
                    for i in 0..<150 {
                        await buffer.append(self.makeFrame(timestamp: Double(t * 150 + i)))
                    }
                }
            }
            // Drain periodically while appending.
            group.addTask {
                for _ in 0..<5 {
                    _ = await buffer.drain()
                    // Yield to let other tasks progress.
                    await Task.yield()
                }
            }
        }
        // After all tasks complete, count must be at or below capacity (1000).
        let finalCount = await buffer.count
        #expect(finalCount <= 1000, "Buffer count \(finalCount) must not exceed capacity 1000")
    }
}
