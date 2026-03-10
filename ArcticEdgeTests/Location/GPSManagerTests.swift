// GPSManagerTests.swift
// ArcticEdgeTests
//
// Tests for GPSReading model validity semantics and MockGPSManager injection behavior.
// All tests use Swift Testing (import Testing) — no XCTest.

import Foundation
import Testing
@testable import ArcticEdge

@Suite("GPSManager")
struct GPSManagerTests {

    // MARK: - GPSReading validity semantics

    @Test func testGPSReadingInvalidSpeed() {
        // speed < 0 indicates GPS unavailable / not yet acquired
        let reading = GPSReading(speed: -1.0, horizontalAccuracy: 5.0, timestamp: .now)
        #expect(reading.speed < 0, "speed -1 should indicate invalid GPS signal")
    }

    @Test func testGPSReadingInvalidAccuracy() {
        // horizontalAccuracy < 0 indicates CLLocation accuracy is unavailable
        let reading = GPSReading(speed: 5.0, horizontalAccuracy: -1.0, timestamp: .now)
        #expect(reading.horizontalAccuracy < 0, "accuracy -1 should indicate invalid accuracy")
    }

    // MARK: - MockGPSManager injection

    @Test func testMockGPSManagerInjectsReading() async {
        let mock = MockGPSManager()
        let stream = await mock.makeStream()

        let expected = GPSReading(speed: 8.5, horizontalAccuracy: 6.0, timestamp: .now)

        // Inject concurrently — the inject must arrive before the for-await below.
        let injectTask = Task {
            // Yield once to let the for-await below begin waiting.
            await Task.yield()
            await mock.inject(expected)
            await mock.stop()
        }

        var received: GPSReading?
        for await reading in stream {
            received = reading
            break
        }

        await injectTask.value

        #expect(received != nil, "stream should deliver the injected reading")
        #expect(received?.speed == expected.speed, "speed should match injected value")
        #expect(received?.horizontalAccuracy == expected.horizontalAccuracy, "accuracy should match")
    }
}
