// MotionManager.swift
// ArcticEdge
//
// Actor owning CMMotionManager, applying the high-pass filter, and emitting FilteredFrame
// to RingBuffer and StreamBroadcaster. Includes thermal-aware sample rate adjustment.

import CoreMotion
import Foundation

// MotionDataSource abstracts CMMotionManager for testability.
// Conforming types are owned by MotionManager; they must be class types (AnyObject)
// so that deviceMotionUpdateInterval can be mutated via a non-Sendable reference.
// nonisolated members prevent SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor from inferring
// @MainActor isolation on this protocol, which would block access from the MotionManager actor.
protocol MotionDataSource: AnyObject {
    nonisolated var deviceMotionUpdateInterval: Double { get set }
    nonisolated func startDeviceMotionUpdates(to queue: OperationQueue, withHandler handler: @escaping CMDeviceMotionHandler)
    nonisolated func stopDeviceMotionUpdates()
}

// CMMotionManager implements these methods. The nonisolated extension satisfies the protocol.
// CMMotionManager is itself a non-Sendable class; MotionManager actor owns it exclusively.
extension CMMotionManager: MotionDataSource {}

// MARK: - RawSample

/// Primitives extracted from one CMDeviceMotion callback.
///
/// CMDeviceMotion is a non-Sendable class, so its values are copied out inside
/// the callback and carried across the actor boundary as this Sendable struct.
nonisolated struct RawSample: Sendable {
    let timestamp: TimeInterval
    let pitch: Double, roll: Double, yaw: Double
    let userAccelX: Double, userAccelY: Double, userAccelZ: Double
    let gravityX: Double, gravityY: Double, gravityZ: Double
    let rotationRateX: Double, rotationRateY: Double, rotationRateZ: Double
}

actor MotionManager {
    private let dataSource: any MotionDataSource
    private let ringBuffer: RingBuffer
    // broadcaster is optional to break the circular init dependency in tests:
    // StreamBroadcaster.init requires a MotionManager, and MotionManager.init
    // can accept the broadcaster set afterward via setStreamBroadcaster().
    private var broadcaster: StreamBroadcaster?
    // BiquadHighPassFilter is not Sendable; it is actor-isolated here and never escapes.
    // Rebuilt whenever the effective sample rate changes: the coefficients encode
    // the rate, so a filter built at 100 Hz has the wrong cutoff once thermal or
    // power-saver throttling drops capture to 60, 50, or 25 Hz.
    private var filter: BiquadHighPassFilter
    private var filterSampleRate: Double = 100.0
    private var currentRunID: UUID = UUID()
    private var thermalObserver: NSObjectProtocol?
    private var powerSaverEnabled: Bool = false
    private(set) var currentSampleRateHz: Int = 100

    // Ordered ingest. CoreMotion yields into this continuation from a serial
    // queue, and one long-lived task drains it, so the stateful IIR filter sees
    // every sample exactly once in timestamp order. The previous design spawned
    // one unstructured Task per sample, which has no ordering guarantee and
    // corrupted the filter's delay line under real 100 Hz load.
    private var sampleContinuation: AsyncStream<RawSample>.Continuation?
    private var ingestTask: Task<Void, Never>?

    /// Most recent CoreMotion error, exposed so the app can report a sensor fault
    /// instead of silently capturing nothing. CoreMotion's error argument used to
    /// be discarded outright.
    private(set) var lastSensorError: String?

    init(dataSource: any MotionDataSource, ringBuffer: RingBuffer, broadcaster: StreamBroadcaster? = nil) {
        self.dataSource = dataSource
        self.ringBuffer = ringBuffer
        self.broadcaster = broadcaster
        self.filter = BiquadHighPassFilter(sampleRate: 100.0)
    }

    // Set the broadcaster after init to break the circular dependency.
    func setStreamBroadcaster(_ broadcaster: StreamBroadcaster) {
        self.broadcaster = broadcaster
    }

    func setPowerSaverMode(_ enabled: Bool) {
        powerSaverEnabled = enabled
        adjustSampleRate(for: ProcessInfo.processInfo.thermalState)
    }

    func startUpdates(runID: UUID) {
        currentRunID = runID
        lastSensorError = nil
        observeThermalState()
        // Honor the thermal state that is already in effect. Hardcoding 100 Hz here
        // ignored a phone that was already hot at the start of the day.
        adjustSampleRate(for: ProcessInfo.processInfo.thermalState)

        // Bounded buffer: ~20 s of slack at 100 Hz. Under normal load the consumer
        // keeps up and nothing is dropped; the bound exists so a stalled consumer
        // cannot grow memory without limit.
        let (stream, continuation) = AsyncStream<RawSample>.makeStream(
            bufferingPolicy: .bufferingNewest(2000)
        )
        sampleContinuation = continuation
        ingestTask = Task { [weak self] in
            for await sample in stream {
                await self?.receive(sample: sample)
            }
        }

        // Serial delivery queue. A default OperationQueue may deliver callbacks
        // concurrently, which would interleave yields and scramble sample order.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        queue.name = "com.arcticedge.motion"

        dataSource.startDeviceMotionUpdates(
            to: queue,
            withHandler: { [weak self] motion, error in
                if let error {
                    let message = error.localizedDescription
                    Task { await self?.recordSensorError(message) }
                    return
                }
                guard let motion else { return }
                // Extract all primitives immediately from the non-Sendable CMDeviceMotion.
                // Do NOT store the motion reference across this closure boundary.
                continuation.yield(RawSample(
                    timestamp: motion.timestamp,
                    pitch: motion.attitude.pitch,
                    roll: motion.attitude.roll,
                    yaw: motion.attitude.yaw,
                    userAccelX: motion.userAcceleration.x,
                    userAccelY: motion.userAcceleration.y,
                    userAccelZ: motion.userAcceleration.z,
                    gravityX: motion.gravity.x,
                    gravityY: motion.gravity.y,
                    gravityZ: motion.gravity.z,
                    rotationRateX: motion.rotationRate.x,
                    rotationRateY: motion.rotationRate.y,
                    rotationRateZ: motion.rotationRate.z
                ))
            }
        )
    }

    func stopUpdates() {
        dataSource.stopDeviceMotionUpdates()
        sampleContinuation?.finish()
        sampleContinuation = nil
        ingestTask?.cancel()
        ingestTask = nil
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
            thermalObserver = nil
        }
    }

    func recordSensorError(_ message: String) {
        lastSensorError = message
    }

    // Update the run the captured frames are tagged with. Called by the app
    // when the classifier starts a run (the run's UUID), and when it ends (a
    // fresh throwaway UUID so post-run lift frames do not pollute the run).
    // This is the fix for the per-run frame tagging bug: FrameRecord.runID
    // must match RunRecord.runID for per-run queries and the carving score.
    func setActiveRunID(_ id: UUID) {
        currentRunID = id
    }

    // Ordered ingest entry point: drained one sample at a time by ingestTask.
    private func receive(sample: RawSample) async {
        await receive(
            timestamp: sample.timestamp,
            runID: currentRunID,
            pitch: sample.pitch, roll: sample.roll, yaw: sample.yaw,
            userAccelX: sample.userAccelX, userAccelY: sample.userAccelY, userAccelZ: sample.userAccelZ,
            gravityX: sample.gravityX, gravityY: sample.gravityY, gravityZ: sample.gravityZ,
            rotationRateX: sample.rotationRateX, rotationRateY: sample.rotationRateY, rotationRateZ: sample.rotationRateZ
        )
    }

    // Production ingest path: stamps the currently active runID (no caller
    // supplied id). Retained for tests that inject samples directly.
    func ingest(
        timestamp: TimeInterval,
        pitch: Double, roll: Double, yaw: Double,
        userAccelX: Double, userAccelY: Double, userAccelZ: Double,
        gravityX: Double, gravityY: Double, gravityZ: Double,
        rotationRateX: Double, rotationRateY: Double, rotationRateZ: Double
    ) async {
        await receive(
            timestamp: timestamp,
            runID: currentRunID,
            pitch: pitch, roll: roll, yaw: yaw,
            userAccelX: userAccelX, userAccelY: userAccelY, userAccelZ: userAccelZ,
            gravityX: gravityX, gravityY: gravityY, gravityZ: gravityZ,
            rotationRateX: rotationRateX, rotationRateY: rotationRateY, rotationRateZ: rotationRateZ
        )
    }

    // receive() is actor-isolated. Safe to access filter (actor-owned, non-Sendable).
    // Internal (not private) so that the test suite can inject frames without a live CMDeviceMotion.
    func receive(
        timestamp: TimeInterval,
        runID: UUID,
        pitch: Double, roll: Double, yaw: Double,
        userAccelX: Double, userAccelY: Double, userAccelZ: Double,
        gravityX: Double, gravityY: Double, gravityZ: Double,
        rotationRateX: Double, rotationRateY: Double, rotationRateZ: Double
    ) async {
        let filteredAccelZ = filter.apply(userAccelZ)
        let frame = FilteredFrame(
            timestamp: timestamp,
            runID: runID,
            pitch: pitch,
            roll: roll,
            yaw: yaw,
            userAccelX: userAccelX,
            userAccelY: userAccelY,
            userAccelZ: userAccelZ,
            gravityX: gravityX,
            gravityY: gravityY,
            gravityZ: gravityZ,
            rotationRateX: rotationRateX,
            rotationRateY: rotationRateY,
            rotationRateZ: rotationRateZ,
            filteredAccelZ: filteredAccelZ
        )
        await ringBuffer.append(frame)
        await broadcaster?.broadcast(frame)
    }

    private func observeThermalState() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            Task { await self?.adjustSampleRate(for: state) }
        }
    }

    // adjustSampleRate is actor-isolated; safe to mutate dataSource here.
    // Thermal state sets the upper bound; power saver caps at 60Hz if lower.
    func adjustSampleRate(for state: ProcessInfo.ThermalState) {
        let thermalHz: Int
        switch state {
        case .nominal, .fair:   thermalHz = 100
        case .serious:          thermalHz = 50
        case .critical:         thermalHz = 25
        @unknown default:       thermalHz = 50
        }
        let targetHz = powerSaverEnabled ? min(thermalHz, 60) : thermalHz
        currentSampleRateHz = targetHz
        dataSource.deviceMotionUpdateInterval = 1.0 / Double(targetHz)

        // Rebuild the high-pass at the new rate. Biquad coefficients are derived
        // from the sample rate, so leaving a 100 Hz filter in place while capturing
        // at 25 Hz silently moves the cutoff by 4x.
        let newRate = Double(targetHz)
        if newRate != filterSampleRate {
            filterSampleRate = newRate
            filter = BiquadHighPassFilter(sampleRate: newRate)
        }
    }
}
