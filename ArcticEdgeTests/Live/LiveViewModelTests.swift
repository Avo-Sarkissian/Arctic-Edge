// LiveViewModelTests.swift
// ArcticEdgeTests/Live
//
// TDD GREEN phase for LiveViewModel — plan 03-03.
// Tests verify the waveform ring-buffer and HUD metric bridging contract.
//
// Requirements covered:
//   LIVE-01: Waveform snapshot builds from incoming FilteredFrames
//   LIVE-02: Metric values (g-force, horizontal load) update from FilteredFrame
//   LIVE-03: Waveform snapshot never exceeds windowSize (1000 frames)

import Testing
import Foundation
@testable import ArcticEdge

@Suite("LiveViewModel")
struct LiveViewModelTests {

    // MARK: - Helpers

    /// Produces a minimal FilteredFrame with the given fields; all others default to 0.
    private func makeFrame(
        filteredVerticalAccel: Double = 0,
        horizontalAccelMagnitude: Double = 0,
        userAccelX: Double = 0,
        userAccelY: Double = 0,
        userAccelZ: Double = 0
    ) -> FilteredFrame {
        FilteredFrame(
            timestamp: 0,
            runID: UUID(),
            pitch: 0,
            roll: 0,
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
            filteredAccelZ: 0,
            filteredVerticalAccel: filteredVerticalAccel,
            horizontalAccelMagnitude: horizontalAccelMagnitude
        )
    }

    /// Feeds frames into an AsyncStream and returns the stream + continuation.
    private func makeStream() -> (AsyncStream<FilteredFrame>, AsyncStream<FilteredFrame>.Continuation) {
        AsyncStream<FilteredFrame>.makeStream()
    }

    /// Waits until the view model has drained the expected number of frames.
    /// A fixed sleep made these tests flaky: the consuming task is scheduled, so
    /// 100 ms is usually but not always enough on a loaded machine.
    private func waitForWaveform(
        _ vm: LiveViewModel,
        count: Int,
        timeout: Duration = .seconds(5)
    ) async throws -> Int {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let current = await vm.waveformSnapshot.count
            if current >= count { return current }
            try await Task.sleep(for: .milliseconds(10))
        }
        return await vm.waveformSnapshot.count
    }

    // MARK: - Tests

    @Test("waveform snapshot builds from incoming frames")
    func testWaveformSnapshotBuilds() async throws {
        let vm = await LiveViewModel(windowSize: 1000)
        let (stream, continuation) = makeStream()

        await vm.startConsumingStream(stream)

        // Feed 10 frames
        for i in 0..<10 {
            continuation.yield(makeFrame(filteredVerticalAccel: Double(i)))
        }
        continuation.finish()

        let count = try await waitForWaveform(vm, count: 10)
        #expect(count == 10)
    }

    @Test("metric values update from FilteredFrame")
    func testMetricValuesUpdate() async throws {
        let vm = await LiveViewModel(windowSize: 1000)
        let (stream, continuation) = makeStream()

        await vm.startConsumingStream(stream)

        let frame = makeFrame(
            horizontalAccelMagnitude: 0.42,
            userAccelX: 0.5,
            userAccelY: 0.3,
            userAccelZ: 0.8
        )
        continuation.yield(frame)
        continuation.finish()

        _ = try await waitForWaveform(vm, count: 1)
        let gForce = await vm.gForce
        let horizontalLoad = await vm.horizontalLoad
        let expectedGForce = hypot(0.5, hypot(0.3, 0.8))

        // Device pitch and roll are deliberately absent: in a pocket they measure
        // how the phone is sitting, not how the skier is skiing.
        #expect(abs(gForce - expectedGForce) < 1e-9)
        #expect(horizontalLoad == 0.42)
    }

    @Test("snapshot never exceeds windowSize")
    func testSnapshotDoesNotExceedWindowSize() async throws {
        let vm = await LiveViewModel(windowSize: 1000)
        let (stream, continuation) = makeStream()

        await vm.startConsumingStream(stream)

        // Feed 1200 frames (exceeds 1000-sample window)
        for i in 0..<1200 {
            continuation.yield(makeFrame(filteredVerticalAccel: Double(i)))
        }
        continuation.finish()

        // The window caps at 1000, so wait for it to saturate then confirm it
        // does not grow past the cap.
        let count = try await waitForWaveform(vm, count: 1000)
        #expect(count == 1000)
    }
}
