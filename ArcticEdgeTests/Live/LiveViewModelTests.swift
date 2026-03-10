// LiveViewModelTests.swift
// ArcticEdgeTests/Live
//
// TDD GREEN phase for LiveViewModel — plan 03-03.
// Tests verify the waveform ring-buffer and HUD metric bridging contract.
//
// Requirements covered:
//   LIVE-01: Waveform snapshot builds from incoming FilteredFrames
//   LIVE-02: Metric values (pitch, roll, g-force) update from FilteredFrame
//   LIVE-03: Waveform snapshot never exceeds windowSize (1000 frames)

import Testing
import Foundation
@testable import ArcticEdge

@Suite("LiveViewModel")
struct LiveViewModelTests {

    // MARK: - Helpers

    /// Produces a minimal FilteredFrame with the given fields; all others default to 0.
    private func makeFrame(
        filteredAccelZ: Double = 0,
        pitch: Double = 0,
        roll: Double = 0,
        userAccelX: Double = 0,
        userAccelY: Double = 0,
        userAccelZ: Double = 0
    ) -> FilteredFrame {
        FilteredFrame(
            timestamp: 0,
            runID: UUID(),
            pitch: pitch,
            roll: roll,
            yaw: 0,
            userAccelX: userAccelX,
            userAccelY: userAccelY,
            userAccelZ: userAccelZ,
            gravityX: 0,
            gravityY: 0,
            gravityZ: 0,
            rotationRateX: 0,
            rotationRateY: 0,
            rotationRateZ: 0,
            filteredAccelZ: filteredAccelZ
        )
    }

    /// Feeds frames into an AsyncStream and returns the stream + continuation.
    private func makeStream() -> (AsyncStream<FilteredFrame>, AsyncStream<FilteredFrame>.Continuation) {
        AsyncStream<FilteredFrame>.makeStream()
    }

    // MARK: - Tests

    @Test("waveform snapshot builds from incoming frames")
    func testWaveformSnapshotBuilds() async throws {
        let vm = await LiveViewModel(windowSize: 1000)
        let (stream, continuation) = makeStream()

        await vm.startConsumingStream(stream)

        // Feed 10 frames
        for i in 0..<10 {
            continuation.yield(makeFrame(filteredAccelZ: Double(i)))
        }
        continuation.finish()

        // Wait for the stream task to drain
        try await Task.sleep(for: .milliseconds(100))

        let count = await vm.waveformSnapshot.count
        #expect(count == 10)
    }

    @Test("metric values update from FilteredFrame")
    func testMetricValuesUpdate() async throws {
        let vm = await LiveViewModel(windowSize: 1000)
        let (stream, continuation) = makeStream()

        await vm.startConsumingStream(stream)

        let frame = makeFrame(
            pitch: 0.3,
            roll: 0.1,
            userAccelX: 0.5,
            userAccelY: 0.3,
            userAccelZ: 0.8
        )
        continuation.yield(frame)
        continuation.finish()

        // Wait for the stream task to process the frame
        try await Task.sleep(for: .milliseconds(100))

        let pitch = await vm.pitch
        let roll = await vm.roll
        let gForce = await vm.gForce
        let expectedGForce = hypot(0.5, hypot(0.3, 0.8))

        #expect(pitch == 0.3)
        #expect(roll == 0.1)
        #expect(abs(gForce - expectedGForce) < 1e-9)
    }

    @Test("snapshot never exceeds windowSize")
    func testSnapshotDoesNotExceedWindowSize() async throws {
        let vm = await LiveViewModel(windowSize: 1000)
        let (stream, continuation) = makeStream()

        await vm.startConsumingStream(stream)

        // Feed 1200 frames (exceeds 1000-sample window)
        for i in 0..<1200 {
            continuation.yield(makeFrame(filteredAccelZ: Double(i)))
        }
        continuation.finish()

        // Wait for the stream task to drain all 1200 frames
        try await Task.sleep(for: .milliseconds(500))

        let count = await vm.waveformSnapshot.count
        #expect(count == 1000)
    }
}
