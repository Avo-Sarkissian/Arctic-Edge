// WorkoutSessionManagerTests.swift
// ArcticEdgeTests
//
// Tests for SESS-05: UserDefaults sentinel lifecycle.
// HKWorkoutSession does not run in Simulator; the session is abstracted behind
// WorkoutSessionProtocol so these tests use a MockWorkoutSession.

import Testing
import Foundation
@testable import ArcticEdge

@Suite("WorkoutSessionManager - sentinel lifecycle")
struct WorkoutSessionManagerTests {

    // SESS-05: sentinel is set to true when session reaches .running.
    @Test func testSentinelSetOnStart() async throws {
        #expect(Bool(false), "not yet implemented")
    }

    // SESS-05: sentinel is cleared to false when session ends cleanly.
    @Test func testSentinelClearedOnEnd() async throws {
        #expect(Bool(false), "not yet implemented")
    }

    // SESS-05: if sentinel is true on relaunch, orphan recovery is triggered.
    @Test func testOrphanDetectedOnRelaunch() async throws {
        #expect(Bool(false), "not yet implemented")
    }

    // SESS-05: if sentinel is false on clean launch, recovery is not triggered.
    @Test func testCleanLaunchNoOrphan() async throws {
        #expect(Bool(false), "not yet implemented")
    }
}
