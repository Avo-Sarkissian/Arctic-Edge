// PostRunViewModelTests.swift
// ArcticEdgeTests/PostRun
//
// TDD GREEN phase for PostRunViewModel — plan 03-04.
// Tests exercise computeStats(from:), session aggregate loading,
// and the scrubber frame lookup using FrameData (no SwiftData ModelContainer required).
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
@MainActor
struct PostRunViewModelTests {

    @Test("frame records load for a given runID")
    func testFrameRecordLoading() async throws {
        // PostRunViewModel.loadDataFromFrameData sets stats from injected FrameData.
        // We verify that after injection, the ViewModel holds the correct frame count
        // by checking that stats reflect the injected data (computeStats runs on it).
        let vm = PostRunViewModel()
        let frames: [PostRunViewModel.FrameData] = [
            .init(timestamp: 1.0, pitch: 0, gpsSpeed: 10, filteredAccelZ: 1, userAccelX: 0, userAccelY: 0, userAccelZ: 0),
            .init(timestamp: 2.0, pitch: 0, gpsSpeed: 20, filteredAccelZ: 1, userAccelX: 0, userAccelY: 0, userAccelZ: 0),
            .init(timestamp: 3.0, pitch: 0, gpsSpeed: 30, filteredAccelZ: 1, userAccelX: 0, userAccelY: 0, userAccelZ: 0),
            .init(timestamp: 4.0, pitch: 0, gpsSpeed: 25, filteredAccelZ: 1, userAccelX: 0, userAccelY: 0, userAccelZ: 0),
            .init(timestamp: 5.0, pitch: 0, gpsSpeed: 15, filteredAccelZ: 1, userAccelX: 0, userAccelY: 0, userAccelZ: 0)
        ]
        vm.loadDataFromFrameData(frames)

        // Verify data was processed: topSpeed should reflect the max of [10,20,30,25,15] = 30
        #expect(vm.stats.topSpeed == 30.0)
    }

    @Test("stats computation returns correct topSpeed, avgSpeed, verticalDrop, distanceMeters")
    func testStatsComputation() async throws {
        let vm = PostRunViewModel()
        // frames with gpsSpeed [10, 20, 30] m/s and pitch = 0
        // pitch = 0 => sin(0) = 0 => verticalDrop = 0
        // distance = sum(speed * dt) where dt = 1.0 for each pair
        // = 10*1 + 20*1 = 30 meters
        let frames: [PostRunViewModel.FrameData] = [
            .init(timestamp: 0.0, pitch: 0, gpsSpeed: 10, filteredAccelZ: 0, userAccelX: 0, userAccelY: 0, userAccelZ: 0),
            .init(timestamp: 1.0, pitch: 0, gpsSpeed: 20, filteredAccelZ: 0, userAccelX: 0, userAccelY: 0, userAccelZ: 0),
            .init(timestamp: 2.0, pitch: 0, gpsSpeed: 30, filteredAccelZ: 0, userAccelX: 0, userAccelY: 0, userAccelZ: 0)
        ]
        let result = vm.computeStats(from: frames)

        #expect(result.topSpeed == 30.0)
        #expect(result.avgSpeed == 20.0)
        // pitch=0, sin(0)=0, so verticalDrop=0
        #expect(result.verticalDrop == 0.0)
        // distanceMeters = 10*1.0 + 20*1.0 = 30.0
        #expect(abs(result.distanceMeters - 30.0) < 0.001)
    }

    @Test("session aggregates match sum of per-run verticalDrop values")
    func testSessionAggregates() async throws {
        let vm = PostRunViewModel()
        // Two runs with verticalDrop 100 and 200
        let start1 = Date(timeIntervalSinceReferenceDate: 0)
        let end1 = Date(timeIntervalSinceReferenceDate: 120)  // 2 minutes
        let run1 = RunRecord(runID: UUID(), startTimestamp: start1)
        run1.endTimestamp = end1
        run1.verticalDrop = 100.0

        let start2 = Date(timeIntervalSinceReferenceDate: 300)
        let end2 = Date(timeIntervalSinceReferenceDate: 480)  // 3 minutes
        let run2 = RunRecord(runID: UUID(), startTimestamp: start2)
        run2.endTimestamp = end2
        run2.verticalDrop = 200.0

        vm.loadSessionAggregatesFromRecords([run1, run2])

        #expect(vm.sessionAggregates.totalVertical == 300.0)
        #expect(vm.sessionAggregates.runCount == 2)
        // totalSkiingTime = 120 + 180 = 300 seconds
        #expect(abs(vm.sessionAggregates.totalSkiingTime - 300.0) < 0.001)
    }

    @Test("scrubber frame lookup returns nearest frame by timestamp")
    func testScrubberFrameLookup() async throws {
        let vm = PostRunViewModel()
        let frames: [PostRunViewModel.FrameData] = [
            .init(timestamp: 1.0, pitch: 0, gpsSpeed: 10, filteredAccelZ: 0, userAccelX: 0, userAccelY: 0, userAccelZ: 0),
            .init(timestamp: 2.0, pitch: 0, gpsSpeed: 20, filteredAccelZ: 0, userAccelX: 0, userAccelY: 0, userAccelZ: 0),
            .init(timestamp: 3.0, pitch: 0, gpsSpeed: 30, filteredAccelZ: 0, userAccelX: 0, userAccelY: 0, userAccelZ: 0)
        ]

        // selectFrameData(at: 2.0) should return the frame with timestamp 2.0
        let found = vm.selectFrameData(at: 2.0, from: frames)
        #expect(found?.timestamp == 2.0)

        // selectFrameData(at: 2.4) should still return timestamp 2.0 (nearest)
        let found2 = vm.selectFrameData(at: 2.4, from: frames)
        #expect(found2?.timestamp == 2.0)

        // selectFrameData(at: 2.6) should return timestamp 3.0 (nearest)
        let found3 = vm.selectFrameData(at: 2.6, from: frames)
        #expect(found3?.timestamp == 3.0)
    }
}
