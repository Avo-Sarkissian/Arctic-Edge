// GPSManager.swift
// ArcticEdge
//
// Actor wrapping CLLocationUpdate.liveUpdates(.otherNavigation) into an AsyncStream
// of GPSReading values. Multiple consumers are supported via UUID-keyed continuations.
//
// Design notes:
// - .otherNavigation avoids road-snapping that would corrupt mountain terrain coordinates.
// - backgroundSession is a stored property — local assignment causes premature deallocation,
//   which silently kills the GPS update stream (see Phase 2 RESEARCH.md pitfall 2).
// - Raw speed/accuracy values are preserved as-is; negative sentinels mean "unavailable".
//   Filtering is the classifier's responsibility, not GPS's.

import CoreLocation
import Foundation

// MARK: - GPSReading

/// Immutable value capturing one GPS fix from CLLocation.
/// speed == -1 or horizontalAccuracy < 0 indicates the value is unavailable.
nonisolated struct GPSReading: Sendable {
    let speed: Double               // m/s; -1 if unavailable
    let horizontalAccuracy: Double  // meters; <0 if unavailable
    let timestamp: Date
}

// MARK: - Protocol

/// Protocol enabling ActivityClassifier to accept a MockGPSManager in tests.
/// nonisolated members prevent SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor from inferring
/// @MainActor isolation on conforming types (same pattern as MotionDataSource).
protocol GPSManagerProtocol: Actor {
    nonisolated func makeStream() -> AsyncStream<GPSReading>
    func start() async
    func stop() async
}

// MARK: - GPSManager

actor GPSManager: GPSManagerProtocol {
    // backgroundSession MUST be a stored property — releasing it kills the GPS stream.
    private var backgroundSession: CLBackgroundActivitySession?
    private var streamTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<GPSReading>.Continuation] = [:]

    // MARK: - GPSManagerProtocol

    nonisolated func makeStream() -> AsyncStream<GPSReading> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<GPSReading>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id: id) }
        }
        Task {
            await self.registerContinuation(id: id, continuation: continuation)
        }
        return stream
    }

    func start() async {
        // Retain the session; releasing it terminates the background task.
        backgroundSession = CLBackgroundActivitySession()
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    guard let location = update.location else { continue }
                    let reading = GPSReading(
                        speed: location.speed,
                        horizontalAccuracy: location.horizontalAccuracy,
                        timestamp: location.timestamp
                    )
                    await self.broadcast(reading)
                }
            } catch {
                // Stream ended (location authorization revoked, session cancelled, etc.)
                // No recovery action; caller must restart if desired.
            }
        }
    }

    func stop() async {
        streamTask?.cancel()
        streamTask = nil
        backgroundSession = nil
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations = [:]
    }

    // MARK: - Private

    private func registerContinuation(
        id: UUID,
        continuation: AsyncStream<GPSReading>.Continuation
    ) {
        continuations[id] = continuation
    }

    private func broadcast(_ reading: GPSReading) {
        for continuation in continuations.values {
            continuation.yield(reading)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
