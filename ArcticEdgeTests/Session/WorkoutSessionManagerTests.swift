// WorkoutSessionManagerTests.swift
// ArcticEdgeTests
//
// Tests for SESS-05: UserDefaults sentinel lifecycle.
// Uses MockWorkoutSession to bypass HKWorkoutSession (unavailable in Simulator).

import Testing
import Foundation
@testable import ArcticEdge

// MockWorkoutSession: simulates immediate .running state without HealthKit.
// nonisolated on protocol methods to satisfy WorkoutSessionProtocol requirements.
struct MockWorkoutSession: WorkoutSessionProtocol {
    // Set to true to simulate a session start failure.
    var shouldFail: Bool = false

    nonisolated func start(on date: Date) async throws {
        // No-op: mock immediately "reaches .running" by returning without error.
    }

    nonisolated func end() {
        // No-op: mock session teardown.
    }
}

// Failing mock for testing error paths.
struct FailingWorkoutSession: WorkoutSessionProtocol {
    nonisolated func start(on date: Date) async throws {
        throw WorkoutSessionError.unavailable
    }
    nonisolated func end() {}
}

@Suite("WorkoutSessionManager - sentinel lifecycle")
struct WorkoutSessionManagerTests {

    // Clean UserDefaults before each test by using a unique test key would be ideal,
    // but since kSessionSentinelKey is a module-level constant we reset it explicitly.
    private func resetSentinel() {
        UserDefaults.standard.removeObject(forKey: kSessionSentinelKey)
    }

    // SESS-05: sentinel is set to true when session reaches .running.
    @Test func testSentinelSetOnStart() async throws {
        resetSentinel()
        let manager = WorkoutSessionManager(mockSession: MockWorkoutSession())
        try await manager.start()
        let sentinel = UserDefaults.standard.bool(forKey: kSessionSentinelKey)
        // After start(), sentinel must be true.
        #expect(sentinel == true)
        // Cleanup.
        await manager.end()
    }

    // SESS-05: sentinel is cleared to false when session ends cleanly.
    @Test func testSentinelClearedOnEnd() async throws {
        resetSentinel()
        let manager = WorkoutSessionManager(mockSession: MockWorkoutSession())
        try await manager.start()
        await manager.end()
        let sentinel = UserDefaults.standard.bool(forKey: kSessionSentinelKey)
        #expect(sentinel == false)
    }

    // SESS-05: if sentinel is true on relaunch, orphan recovery is triggered.
    // Sets sentinel manually (simulating a crash) then calls recoverOrphanedSession().
    // After recovery the sentinel must be cleared.
    @Test func testOrphanDetectedOnRelaunch() async throws {
        // Simulate what happens on crash: sentinel is still set.
        UserDefaults.standard.set(true, forKey: kSessionSentinelKey)
        let manager = WorkoutSessionManager()
        await manager.recoverOrphanedSession()
        // Sentinel must be cleared after recovery.
        let sentinelAfter = UserDefaults.standard.bool(forKey: kSessionSentinelKey)
        #expect(sentinelAfter == false)
        // Manager must not be in active state after recovery.
        let isActive = await manager.isSessionActive
        #expect(isActive == false)
    }

    // SESS-05: if sentinel is false on clean launch, recovery path is not needed.
    @Test func testCleanLaunchNoOrphan() async throws {
        // Ensure sentinel is absent.
        resetSentinel()
        let manager = WorkoutSessionManager()
        // On a clean launch the app checks the sentinel before calling recoverOrphanedSession().
        // Verify sentinel is still false and manager is not active.
        let sentinel = UserDefaults.standard.bool(forKey: kSessionSentinelKey)
        #expect(sentinel == false)
        let isActive = await manager.isSessionActive
        #expect(isActive == false)
    }
}
