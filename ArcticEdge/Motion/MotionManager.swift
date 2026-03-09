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

actor MotionManager {
    private let dataSource: any MotionDataSource
    private let ringBuffer: RingBuffer
    // broadcaster is optional to break the circular init dependency in tests:
    // StreamBroadcaster.init requires a MotionManager, and MotionManager.init
    // can accept the broadcaster set afterward via setStreamBroadcaster().
    private var broadcaster: StreamBroadcaster?
    // BiquadHighPassFilter is not Sendable; it is actor-isolated here and never escapes.
    private let filter: BiquadHighPassFilter
    private var currentRunID: UUID = UUID()
    private var thermalObserver: NSObjectProtocol?

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

    func startUpdates(runID: UUID) {
        currentRunID = runID
        dataSource.deviceMotionUpdateInterval = 1.0 / 100.0  // 100Hz
        // Capture runID as a local constant before entering the callback closure.
        // Actor-isolated properties cannot be safely read from the CoreMotion callback thread.
        let capturedRunID = runID
        observeThermalState()
        dataSource.startDeviceMotionUpdates(
            to: OperationQueue(),
            withHandler: { [weak self] motion, _ in
                guard let motion, let self else { return }
                // Extract all primitives immediately from the non-Sendable CMDeviceMotion.
                // Do NOT store the motion reference across this closure boundary.
                let timestamp = motion.timestamp
                let pitch = motion.attitude.pitch
                let roll = motion.attitude.roll
                let yaw = motion.attitude.yaw
                let userAccelX = motion.userAcceleration.x
                let userAccelY = motion.userAcceleration.y
                let userAccelZ = motion.userAcceleration.z
                let gravityX = motion.gravity.x
                let gravityY = motion.gravity.y
                let gravityZ = motion.gravity.z
                let rotationRateX = motion.rotationRate.x
                let rotationRateY = motion.rotationRate.y
                let rotationRateZ = motion.rotationRate.z
                // Bridge into actor context to apply the filter and store the frame.
                Task {
                    await self.receive(
                        timestamp: timestamp,
                        runID: capturedRunID,
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
                        rotationRateZ: rotationRateZ
                    )
                }
            }
        )
    }

    func stopUpdates() {
        dataSource.stopDeviceMotionUpdates()
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
            thermalObserver = nil
        }
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
    func adjustSampleRate(for state: ProcessInfo.ThermalState) {
        let interval: Double
        switch state {
        case .nominal, .fair:
            interval = 1.0 / 100.0   // 100Hz
        case .serious:
            interval = 1.0 / 50.0    // 50Hz
        case .critical:
            interval = 1.0 / 25.0    // 25Hz
        @unknown default:
            interval = 1.0 / 50.0
        }
        dataSource.deviceMotionUpdateInterval = interval
    }
}
