// LiveViewModel.swift
// ArcticEdge
//
// @Observable @MainActor bridge between StreamBroadcaster and LiveTelemetryView.
// Three waveform buffers, all filled from the 100Hz FilteredFrame stream:
//   waveformSnapshot — filteredVerticalAccel (gravity-referenced vertical load)
//   gForceSnapshot   — userAccel magnitude (orientation-independent total load)
//
// The vertical channel replaced a high-pass of the raw device z axis. In a pocket
// the device frame points in an arbitrary direction, so that signal varied with
// how the phone was sitting rather than with how the skier was skiing.
// GPS speed is separate (1Hz from AppModel) and fed via appendGPSSpeed(_:).
// GPS speed is NOT in FilteredFrame; read from appModel.lastGPSSpeed (10Hz HUD).

import Foundation

@Observable
@MainActor
final class LiveViewModel {

    // MARK: - Public state

    private(set) var waveformSnapshot: [Double] = []
    private(set) var gForceSnapshot: [Double] = []
    private(set) var gpsSnapshot: [Double] = []
    private(set) var gForce: Double = 0
    /// Magnitude of acceleration in the horizontal plane: the closest honest
    /// stand-in for turn loading a single pocket phone can offer.
    private(set) var horizontalLoad: Double = 0

    // MARK: - Configuration

    let windowSize: Int

    // MARK: - Private

    private var streamTask: Task<Void, Never>?

    // MARK: - Init

    init(windowSize: Int = 1000) {
        self.windowSize = windowSize
    }

    // MARK: - Lifecycle

    func startConsuming(broadcaster: StreamBroadcaster) {
        streamTask?.cancel()
        streamTask = Task { @MainActor [weak self] in
            let stream = await broadcaster.makeStream()
            for await frame in stream {
                guard let self else { return }
                let mag = hypot(frame.userAccelX, hypot(frame.userAccelY, frame.userAccelZ))

                waveformSnapshot.append(frame.filteredVerticalAccel)
                if waveformSnapshot.count > windowSize { waveformSnapshot.removeFirst() }

                gForceSnapshot.append(mag)
                if gForceSnapshot.count > windowSize { gForceSnapshot.removeFirst() }

                gForce = mag
                horizontalLoad = frame.horizontalAccelMagnitude
            }
        }
    }

    /// Feed GPS speed readings (m/s, ≥ 0) into the GPS waveform buffer.
    /// Called from the view via .onChange(of: appModel.lastGPSSpeed).
    func appendGPSSpeed(_ speed: Double) {
        gpsSnapshot.append(speed)
        if gpsSnapshot.count > windowSize { gpsSnapshot.removeFirst() }
    }

    func stopConsuming() {
        streamTask?.cancel()
        streamTask = nil
        waveformSnapshot = []
        gForceSnapshot = []
        gpsSnapshot = []
        gForce = 0
        horizontalLoad = 0
    }

    // MARK: - Test support

    func startConsumingStream(_ stream: AsyncStream<FilteredFrame>) {
        streamTask?.cancel()
        streamTask = Task { @MainActor [weak self] in
            for await frame in stream {
                guard let self else { return }
                let mag = hypot(frame.userAccelX, hypot(frame.userAccelY, frame.userAccelZ))
                waveformSnapshot.append(frame.filteredVerticalAccel)
                if waveformSnapshot.count > windowSize { waveformSnapshot.removeFirst() }
                gForceSnapshot.append(mag)
                if gForceSnapshot.count > windowSize { gForceSnapshot.removeFirst() }
                gForce = mag
                horizontalLoad = frame.horizontalAccelMagnitude
            }
        }
    }
}
