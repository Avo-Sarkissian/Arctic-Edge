// PostRunViewModelTests.swift
// ArcticEdgeTests/PostRun
//
// Covers PostRunViewModel's session aggregation and scrubber lookup.
// Statistics themselves moved to RunStatsCalculator and are tested there.
//
// Requirements covered:
//   ANLYS-02: Per-run stats surface through the view model
//   ANLYS-03: Session aggregates across all runs today
//   ANLYS-04: Scrubber frame lookup — nearest frame by timestamp

import Testing
import Foundation
@testable import ArcticEdge

@Suite("PostRunViewModel")
@MainActor
struct PostRunViewModelTests {

    private func speedFrames(_ speeds: [Double]) -> [StatsFrame] {
        speeds.enumerated().map { index, speed in
            StatsFrame(
                timestamp: Double(index),
                gpsSpeed: speed,
                gpsHorizontalAccuracy: 5,
                gpsSpeedAccuracy: 1
            )
        }
    }

    @Test("frame data loads through the view model into stats")
    func testFrameDataLoading() async throws {
        let vm = PostRunViewModel()
        vm.loadDataFromFrameData(speedFrames([10, 20, 30, 25, 15]))
        #expect(vm.stats.topSpeed != nil, "five good samples clear the minimum gate")
    }

    @Test("a run with too few speed samples reports no speed stats")
    func testInsufficientSpeedSamplesYieldNil() async throws {
        // Two fixes cannot honestly support an average speed. nil renders as a
        // dash; a zero would read as a measurement of standing still.
        let vm = PostRunViewModel()
        vm.loadDataFromFrameData(speedFrames([10, 20]))
        #expect(vm.stats.topSpeed == nil)
        #expect(vm.stats.avgSpeed == nil)
        #expect(vm.stats.distanceMeters == nil)
    }

    @Test("session aggregates sum per-run verticalDrop values")
    func testSessionAggregates() async throws {
        let vm = PostRunViewModel()
        let start1 = Date(timeIntervalSinceReferenceDate: 0)
        let run1 = RunRecord(runID: UUID(), startTimestamp: start1)
        run1.endTimestamp = Date(timeIntervalSinceReferenceDate: 120)  // 2 minutes
        run1.verticalDrop = 100.0

        let start2 = Date(timeIntervalSinceReferenceDate: 300)
        let run2 = RunRecord(runID: UUID(), startTimestamp: start2)
        run2.endTimestamp = Date(timeIntervalSinceReferenceDate: 480)  // 3 minutes
        run2.verticalDrop = 200.0

        vm.loadSessionAggregatesFromRecords([run1, run2])

        #expect(vm.sessionAggregates.totalVertical == 300.0)
        #expect(vm.sessionAggregates.runCount == 2)
        #expect(abs(vm.sessionAggregates.totalSkiingTime - 300.0) < 0.001)
    }

    @Test("a day with no measured vertical reports nil, not zero")
    func testAggregateVerticalIsNilWithoutData() async throws {
        // A device with no barometer measures no vertical. Reporting 0 m would
        // claim the skier descended nothing.
        let vm = PostRunViewModel()
        let run = RunRecord(runID: UUID(), startTimestamp: Date(timeIntervalSinceReferenceDate: 0))
        run.endTimestamp = Date(timeIntervalSinceReferenceDate: 60)

        vm.loadSessionAggregatesFromRecords([run])

        #expect(vm.sessionAggregates.totalVertical == nil)
        #expect(vm.sessionAggregates.runCount == 1)
    }

    @Test("scrubber frame lookup returns nearest frame by timestamp")
    func testScrubberFrameLookup() async throws {
        let vm = PostRunViewModel()
        let frames = speedFrames([10, 20, 30])   // timestamps 0, 1, 2

        #expect(vm.selectFrameData(at: 1.0, from: frames)?.timestamp == 1.0)
        #expect(vm.selectFrameData(at: 1.4, from: frames)?.timestamp == 1.0)
        #expect(vm.selectFrameData(at: 1.6, from: frames)?.timestamp == 2.0)
    }
}
