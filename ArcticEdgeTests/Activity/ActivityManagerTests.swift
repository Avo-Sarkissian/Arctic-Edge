// ActivityManagerTests.swift
// ArcticEdgeTests
//
// Tests for ActivityManager / MockActivityManager protocol bridge behavior.
// CMMotionActivityManager.isActivityAvailable() returns false in the simulator,
// so ActivityManager.start() must be a no-op there.
// ActivitySnapshot is the Sendable wrapper for CMMotionActivity values.

import CoreMotion
import Foundation
import Testing
@testable import ArcticEdge

@Suite("ActivityManager")
struct ActivityManagerTests {

    // MARK: - isActivityAvailable guard

    @Test func testActivityManagerStartIsNoopOnSimulator() async {
        // start() must not crash on simulator where isActivityAvailable() == false.
        let manager = ActivityManager()
        await manager.start()
        await manager.stop()
    }

    // MARK: - MockActivityManager stream lifecycle

    @Test func testActivityManagerStopFinishesContinuations() async {
        let mock = MockActivityManager()
        let stream = await mock.makeStream()

        // Stop the mock — the for-await loop must exit cleanly.
        let stopTask = Task {
            await Task.yield()
            await mock.stop()
        }

        var iterationCount = 0
        for await _ in stream {
            iterationCount += 1
        }

        await stopTask.value
        // Stream finished without hanging — no values were injected before stop().
        #expect(iterationCount == 0, "no values should have been injected before stop()")
    }

    // MARK: - MockActivityManager injection

    @Test func testMockActivityManagerInjectsActivity() async {
        let mock = MockActivityManager()
        let stream = await mock.makeStream()

        let injectTask = Task {
            await Task.yield()
            await mock.inject(ActivitySnapshot(automotive: true, confidence: .high))
            await mock.stop()
        }

        var received: ActivitySnapshot?
        for await snapshot in stream {
            received = snapshot
            break
        }

        await injectTask.value
        #expect(received != nil, "stream should deliver the injected ActivitySnapshot")
        #expect(received?.automotive == true, "automotive flag should be true")
    }
}
