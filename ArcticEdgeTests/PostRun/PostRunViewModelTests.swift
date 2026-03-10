// PostRunViewModelTests.swift
// ArcticEdgeTests/PostRun
//
// TDD RED phase for PostRunViewModel — Wave 0 stubs.
// These tests define the contract for plan 03-04 (PostRunViewModel implementation).
//
// Requirements covered:
//   ANLYS-01: FrameRecords load for a given runID from PersistenceService
//   ANLYS-02: Stats computation (topSpeed, avgSpeed, verticalDrop, distanceMeters)
//   ANLYS-03: Session aggregates (total vertical drop, run count across all runs today)
//   ANLYS-04: Scrubber frame lookup — nearest frame by timestamp

import Testing
import Foundation
@testable import ArcticEdge

@Suite("PostRunViewModel")
struct PostRunViewModelTests {

    @Test("frame records load for a given runID")
    func testFrameRecordLoading() async throws {
        // STUB: will fail until PostRunViewModel exists (plan 03-04)
        // Behavior: PostRunViewModel loads FrameRecords for a given runID from
        // MockPersistenceService; assert frames.count matches injected count
        Issue.record("PostRunViewModel does not exist yet — implement in plan 03-04")
        #expect(Bool(false))
    }

    @Test("stats computation returns correct topSpeed, avgSpeed, verticalDrop, distanceMeters")
    func testStatsComputation() async throws {
        // STUB: will fail until PostRunViewModel exists (plan 03-04)
        // Behavior: Given FrameRecords with known gpsSpeed and pitch values,
        // assert computeStats returns correct topSpeed, avgSpeed, verticalDrop, distanceMeters
        Issue.record("PostRunViewModel does not exist yet — implement in plan 03-04")
        #expect(Bool(false))
    }

    @Test("session aggregates match sum of per-run verticalDrop values")
    func testSessionAggregates() async throws {
        // STUB: will fail until PostRunViewModel exists (plan 03-04)
        // Behavior: Given multiple RunRecords in MockPersistenceService,
        // assert session totals match sum of per-run verticalDrop values and run count
        Issue.record("PostRunViewModel does not exist yet — implement in plan 03-04")
        #expect(Bool(false))
    }

    @Test("scrubber frame lookup returns nearest frame by timestamp")
    func testScrubberFrameLookup() async throws {
        // STUB: will fail until PostRunViewModel exists (plan 03-04)
        // Behavior: Given frames with timestamps [1.0, 2.0, 3.0],
        // selectedTimestamp = 2.0 → assert returned frame has timestamp == 2.0
        Issue.record("PostRunViewModel does not exist yet — implement in plan 03-04")
        #expect(Bool(false))
    }
}
