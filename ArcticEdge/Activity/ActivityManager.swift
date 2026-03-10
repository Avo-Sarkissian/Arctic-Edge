// ActivityManager.swift
// ArcticEdge
//
// Actor bridging CMMotionActivityManager's callback-based API into an AsyncStream
// of ActivitySnapshot values. Multiple consumers are supported via UUID-keyed continuations.
//
// Design notes:
// - isActivityAvailable() returns false in the simulator — start() is a no-op there.
// - CMMotionActivity is not Sendable (ObjC class). ActivitySnapshot extracts all boolean
//   properties into a Sendable value type before crossing the concurrency boundary.
//   This mirrors the MotionManager pattern of extracting CMDeviceMotion primitives.
// - The CMMotionActivityManager callback bridges into actor isolation via Task { await }.

import CoreMotion
import Foundation

// MARK: - ActivitySnapshot

/// Sendable value type capturing the boolean activity flags from CMMotionActivity.
/// Replaces CMMotionActivity in async stream boundaries to satisfy strict concurrency.
nonisolated struct ActivitySnapshot: Sendable {
    let stationary: Bool
    let walking: Bool
    let running: Bool
    let automotive: Bool
    let cycling: Bool
    let unknown: Bool
    let confidence: CMMotionActivityConfidence

    init(from activity: CMMotionActivity) {
        stationary  = activity.stationary
        walking     = activity.walking
        running     = activity.running
        automotive  = activity.automotive
        cycling     = activity.cycling
        unknown     = activity.unknown
        confidence  = activity.confidence
    }

    /// Convenience init for testing (all flags false by default).
    init(
        stationary: Bool = false,
        walking: Bool = false,
        running: Bool = false,
        automotive: Bool = false,
        cycling: Bool = false,
        unknown: Bool = true,
        confidence: CMMotionActivityConfidence = .low
    ) {
        self.stationary = stationary
        self.walking    = walking
        self.running    = running
        self.automotive = automotive
        self.cycling    = cycling
        self.unknown    = unknown
        self.confidence = confidence
    }
}

// MARK: - Protocol

/// Protocol enabling ActivityClassifier to accept a MockActivityManager in tests.
/// nonisolated members prevent SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor from inferring
/// @MainActor isolation on conforming types.
protocol ActivityManagerProtocol: Actor {
    nonisolated func makeStream() -> AsyncStream<ActivitySnapshot>
    func start() async
    func stop() async
}

// MARK: - ActivityManager

actor ActivityManager: ActivityManagerProtocol {
    private let manager = CMMotionActivityManager()
    private var continuations: [UUID: AsyncStream<ActivitySnapshot>.Continuation] = [:]

    // MARK: - ActivityManagerProtocol

    nonisolated func makeStream() -> AsyncStream<ActivitySnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ActivitySnapshot>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id: id) }
        }
        Task {
            await self.registerContinuation(id: id, continuation: continuation)
        }
        return stream
    }

    func start() async {
        // Guard against simulator / devices without motion coprocessor.
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        manager.startActivityUpdates(to: OperationQueue()) { [weak self] activity in
            guard let activity else { return }
            // Extract all primitives on the callback thread before bridging to actor.
            let stationary  = activity.stationary
            let walking     = activity.walking
            let running     = activity.running
            let automotive  = activity.automotive
            let cycling     = activity.cycling
            let unknown     = activity.unknown
            let confidence  = activity.confidence
            Task { [weak self] in
                await self?.broadcast(ActivitySnapshot(
                    stationary: stationary,
                    walking:    walking,
                    running:    running,
                    automotive: automotive,
                    cycling:    cycling,
                    unknown:    unknown,
                    confidence: confidence
                ))
            }
        }
    }

    func stop() async {
        manager.stopActivityUpdates()
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations = [:]
    }

    // MARK: - Private

    private func registerContinuation(
        id: UUID,
        continuation: AsyncStream<ActivitySnapshot>.Continuation
    ) {
        continuations[id] = continuation
    }

    private func broadcast(_ snapshot: ActivitySnapshot) {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
