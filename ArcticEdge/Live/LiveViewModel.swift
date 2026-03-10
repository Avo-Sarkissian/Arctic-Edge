// LiveViewModel.swift
// ArcticEdge
//
// @Observable @MainActor bridge between StreamBroadcaster and LiveTelemetryView.
// Maintains a fixed-size waveformSnapshot ([Double] of filteredAccelZ values)
// for Canvas consumption. Metric values update on every incoming frame.
// GPS speed is NOT in FilteredFrame; read from appModel.lastGPSSpeed (10Hz HUD).

import Foundation

@Observable
@MainActor
final class LiveViewModel {

    // MARK: - Public state (read by Canvas and HUD cards)

    private(set) var waveformSnapshot: [Double] = []
    private(set) var pitch: Double = 0
    private(set) var roll: Double = 0
    private(set) var gForce: Double = 0

    // MARK: - Configuration

    let windowSize: Int

    // MARK: - Private

    private var streamTask: Task<Void, Never>?

    // MARK: - Init

    init(windowSize: Int = 1000) {
        self.windowSize = windowSize
    }

    // MARK: - Lifecycle

    // Called from AppModel.startDay() after broadcaster.start().
    // broadcaster is a StreamBroadcaster actor; makeStream() must be awaited.
    func startConsuming(broadcaster: StreamBroadcaster) {
        streamTask?.cancel()
        streamTask = Task { @MainActor [weak self] in
            let stream = await broadcaster.makeStream()
            for await frame in stream {
                guard let self else { return }
                waveformSnapshot.append(frame.filteredAccelZ)
                if waveformSnapshot.count > windowSize {
                    waveformSnapshot.removeFirst()
                }
                pitch = frame.pitch
                roll = frame.roll
                gForce = hypot(frame.userAccelX, hypot(frame.userAccelY, frame.userAccelZ))
            }
        }
    }

    func stopConsuming() {
        streamTask?.cancel()
        streamTask = nil
        waveformSnapshot = []
        pitch = 0
        roll = 0
        gForce = 0
    }

    // MARK: - Test support

    // Consume an already-created stream directly.
    // Avoids needing a real StreamBroadcaster (which requires CMMotionManager) in tests.
    func startConsumingStream(_ stream: AsyncStream<FilteredFrame>) {
        streamTask?.cancel()
        streamTask = Task { @MainActor [weak self] in
            for await frame in stream {
                guard let self else { return }
                waveformSnapshot.append(frame.filteredAccelZ)
                if waveformSnapshot.count > windowSize { waveformSnapshot.removeFirst() }
                pitch = frame.pitch
                roll = frame.roll
                gForce = hypot(frame.userAccelX, hypot(frame.userAccelY, frame.userAccelZ))
            }
        }
    }
}
