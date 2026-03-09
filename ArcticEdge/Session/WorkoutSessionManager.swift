// WorkoutSessionManager.swift
// ArcticEdge
//
// Actor managing HKWorkoutSession lifecycle with UserDefaults sentinel for crash recovery.
//
// SESS-01: HKWorkoutSession reaches .running before CMMotionManager starts.
//          ArcticEdgeApp.startSession() must call WorkoutSessionManager.start() first,
//          then StreamBroadcaster.start(runID:).
// SESS-05: Sentinel set immediately on start(), cleared on clean end().
//          Orphan detected if sentinel is still true at next launch.
//
// HKWorkoutSession is not available in Simulator. WorkoutSessionProtocol allows
// MockWorkoutSession injection in tests so sentinel logic is fully testable without
// a physical device or HealthKit entitlement.

import Foundation
import HealthKit

// UserDefaults key for the crash-recovery sentinel.
// nonisolated so it is accessible from test and non-actor contexts.
nonisolated let kSessionSentinelKey = "sessionInProgress"

// MARK: - Protocol for test injection

// All members nonisolated to prevent SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// from inferring @MainActor isolation on this protocol.
protocol WorkoutSessionProtocol: Sendable {
    nonisolated func start(on date: Date) async throws
    nonisolated func end()
}

// MARK: - Delegate bridge (NSObject, not actor-isolated)

// Bridges HKWorkoutSessionDelegate callbacks to CheckedContinuation.
// @unchecked Sendable because NSLock provides thread safety for stored state.
// nonisolated(unsafe) on continuation prevents SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
// from isolating the stored property to @MainActor.
private final class WorkoutSessionDelegate: NSObject, HKWorkoutSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    // nonisolated(unsafe): protected by `lock`; NSObject class cannot be an actor.
    nonisolated(unsafe) private var continuation: CheckedContinuation<Void, Error>?

    // nonisolated prevents SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor from isolating init.
    nonisolated override init() {
        super.init()
    }

    nonisolated func set(_ continuation: CheckedContinuation<Void, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        guard toState == .running else { return }
        let c = lock.withLock {
            let stored = self.continuation
            self.continuation = nil
            return stored
        }
        c?.resume()
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        let c = lock.withLock {
            let stored = self.continuation
            self.continuation = nil
            return stored
        }
        c?.resume(throwing: error)
    }
}

// MARK: - HKWorkoutSession conformance via wrapper

// Wraps HKWorkoutSession (non-Sendable class) in a final Sendable class.
// Thread safety is guaranteed by the single owner (WorkoutSessionManager actor).
// nonisolated init avoids @MainActor inference from SWIFT_DEFAULT_ACTOR_ISOLATION.
final class HKWorkoutSessionWrapper: WorkoutSessionProtocol, @unchecked Sendable {
    private let session: HKWorkoutSession
    private let sessionDelegate: WorkoutSessionDelegate

    nonisolated init(configuration: HKWorkoutConfiguration, healthStore: HKHealthStore) throws {
        let d = WorkoutSessionDelegate()
        self.sessionDelegate = d
        let s = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        s.delegate = d
        self.session = s
    }

    nonisolated func start(on date: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionDelegate.set(continuation)
            session.startActivity(with: date)
        }
    }

    nonisolated func end() {
        session.end()
    }
}

// MARK: - WorkoutSessionManager

actor WorkoutSessionManager {
    // nonisolated(unsafe) on the optional protocol reference: the actor provides isolation.
    private var sessionProtocol: (any WorkoutSessionProtocol)?
    private var isActive: Bool = false

    // Designated init for production use (creates a real HKWorkoutSession on start()).
    init() {}

    // Init for test injection; bypasses HKWorkoutSession entirely.
    init(mockSession: some WorkoutSessionProtocol) {
        self.sessionProtocol = mockSession
    }

    // SESS-01 + SESS-05: Set sentinel BEFORE awaiting .running to eliminate the
    // window between startActivity() and the delegate callback where a crash
    // would leave no sentinel. If the process is killed in that window,
    // the orphan recovery path will correctly detect the open run on next launch.
    func start() async throws {
        // Set sentinel first (crash safety: covers the start -> running window).
        UserDefaults.standard.set(true, forKey: kSessionSentinelKey)

        if sessionProtocol == nil {
            // Production path: create a real HKWorkoutSession.
            let store = HKHealthStore()
            let config = HKWorkoutConfiguration()
            config.activityType = .downhillSkiing
            config.locationType = .outdoor
            let wrapper = try HKWorkoutSessionWrapper(configuration: config, healthStore: store)
            sessionProtocol = wrapper
        }

        guard let session = sessionProtocol else {
            throw WorkoutSessionError.unavailable
        }

        try await session.start(on: Date())
        isActive = true
    }

    // SESS-05: Clear sentinel on clean end. Motion pipeline is stopped by the caller.
    func end() async {
        // end() is nonisolated on the protocol, so calling from actor context is fine.
        sessionProtocol?.end()
        UserDefaults.standard.removeObject(forKey: kSessionSentinelKey)
        isActive = false
        sessionProtocol = nil
    }

    // SESS-05: Called from app launch when sentinel is found to be true.
    // Clears the sentinel so subsequent launches do not re-enter recovery.
    func recoverOrphanedSession() async {
        // Clear sentinel immediately so a second crash loop cannot occur.
        UserDefaults.standard.removeObject(forKey: kSessionSentinelKey)
        isActive = false
        print("[WorkoutSessionManager] Orphaned session detected. Sentinel cleared.")
    }

    var isSessionActive: Bool { isActive }
}

// MARK: - Errors

enum WorkoutSessionError: Error {
    case unavailable
}
