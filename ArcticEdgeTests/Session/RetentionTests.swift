// RetentionTests.swift
// ArcticEdgeTests/Session
//
// Frame retention against a real in-memory store. Raw frames land at 100 Hz with
// no natural bound (roughly two million rows per six hour day), so pruning has to
// remove the right rows and, more importantly, must never take a run or a score
// with them.

import Testing
import Foundation
import SwiftData
@testable import ArcticEdge

@Suite("Frame retention")
struct RetentionTests {

    private func makeService() throws -> (PersistenceService, ModelContainer) {
        let schema = Schema([FrameRecord.self, RunRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return (PersistenceService(modelContainer: container), container)
    }

    private func frame(runID: UUID, uptime: TimeInterval) -> FilteredFrame {
        FilteredFrame(
            timestamp: uptime, runID: runID,
            pitch: 0, roll: 0, yaw: 0,
            userAccelX: 0, userAccelY: 0, userAccelZ: 0,
            gravityX: 0, gravityY: 0, gravityZ: -1,
            rotationRateX: 0, rotationRateY: 0, rotationRateZ: 0,
            filteredAccelZ: 0
        )
    }

    @Test("frames belonging to no run are removed")
    func testOrphanedFramesPruned() async throws {
        let (service, _) = try makeService()
        let realRun = UUID()
        let throwaway = UUID()   // the id live capture uses between runs

        try await service.createRunRecord(runID: realRun, startTimestamp: Date())
        try await service.flushWithGPS(frames: (0..<5).map { frame(runID: realRun, uptime: Double($0)) }, fix: nil)
        try await service.flushWithGPS(frames: (5..<12).map { frame(runID: throwaway, uptime: Double($0)) }, fix: nil)

        #expect(try await service.frameCount() == 12)

        let deleted = try await service.pruneFrames(olderThan: .distantPast, keepingRunIDs: [])
        #expect(deleted == 7, "the 7 lift frames belong to no run and should go")
        #expect(try await service.frameCount() == 5)
    }

    @Test("an active run's frames survive even with no RunRecord yet")
    func testLiveRunIsProtected() async throws {
        // A run that has not been confirmed yet has no RunRecord. Pruning mid-day
        // must not delete the capture in progress.
        let (service, _) = try makeService()
        let liveRun = UUID()
        try await service.flushWithGPS(frames: (0..<6).map { frame(runID: liveRun, uptime: Double($0)) }, fix: nil)

        let deleted = try await service.pruneFrames(olderThan: .distantPast, keepingRunIDs: [liveRun])
        #expect(deleted == 0)
        #expect(try await service.frameCount() == 6)
    }

    @Test("runs, stats, and scores are never pruned")
    func testRunsSurvivePruning() async throws {
        // The whole point of the retention window: raw frames expire, the record
        // of having skied does not.
        let (service, _) = try makeService()
        let runID = UUID()
        try await service.createRunRecord(runID: runID, startTimestamp: Date())
        try await service.flushWithGPS(frames: (0..<8).map { frame(runID: runID, uptime: Double($0)) }, fix: nil)
        try await service.finalizeRunRecord(runID: runID, endTimestamp: Date())
        try await service.updateRunStats(runID: runID, topSpeed: 18, avgSpeed: 12, verticalDrop: 240, distanceMeters: 1400)
        try await service.updateCarvingScore(runID: runID, score: 71, version: "1.0.0-provisional")

        // Everything is older than the cutoff.
        _ = try await service.pruneFrames(olderThan: Date.distantFuture, keepingRunIDs: [])

        #expect(try await service.frameCount() == 0, "raw frames should expire")
        let snapshot = try await service.fetchRunSnapshot(runID: runID)
        let run = try #require(snapshot)
        #expect(run.carvingScore == 71, "the score must outlive its frames")
        #expect(run.topSpeed == 18)
        #expect(run.verticalDrop == 240)
    }

    @Test("recent frames inside the window are kept")
    func testRecentFramesKept() async throws {
        let (service, _) = try makeService()
        let runID = UUID()
        try await service.createRunRecord(runID: runID, startTimestamp: Date())
        try await service.flushWithGPS(frames: (0..<10).map { frame(runID: runID, uptime: Double($0)) }, fix: nil)

        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let deleted = try await service.pruneFrames(olderThan: cutoff, keepingRunIDs: [])

        #expect(deleted == 0, "frames captured just now are well inside the window")
        #expect(try await service.frameCount() == 10)
    }

    @Test("stats written at finalization are not erased by a later finalize")
    func testFinalizeDoesNotClearStats() async throws {
        // finalizeRunRecord used to overwrite every stat with nil, so any later
        // call silently wiped the numbers history reads.
        let (service, _) = try makeService()
        let runID = UUID()
        try await service.createRunRecord(runID: runID, startTimestamp: Date())
        try await service.updateRunStats(runID: runID, topSpeed: 20, avgSpeed: 14, verticalDrop: 300, distanceMeters: 900)
        try await service.finalizeRunRecord(runID: runID, endTimestamp: Date())

        let run = try #require(try await service.fetchRunSnapshot(runID: runID))
        #expect(run.topSpeed == 20, "a nil argument must leave the existing value alone")
        #expect(run.verticalDrop == 300)
    }

    @Test("onset frames are reclaimed by the run they belong to")
    func testRetagFrames() async throws {
        // The ~3 s before a run is confirmed is captured under the previous
        // throwaway id. Those frames carry the turn initiation the score needs.
        let (service, _) = try makeService()
        let throwaway = UUID()
        let realRun = UUID()
        try await service.createRunRecord(runID: realRun, startTimestamp: Date())
        try await service.flushWithGPS(frames: (0..<10).map { frame(runID: throwaway, uptime: Double($0)) }, fix: nil)

        try await service.retagFrames(fromUptime: 0, toUptime: 4, runID: realRun)

        let reclaimed = try await service.fetchFrameDataForRun(runID: realRun)
        #expect(reclaimed.count == 5, "frames at uptime 0 through 4 should now belong to the run")
    }

    @Test("deleting all data leaves nothing behind")
    func testDeleteAllData() async throws {
        let (service, _) = try makeService()
        let runID = UUID()
        try await service.createRunRecord(runID: runID, startTimestamp: Date())
        try await service.flushWithGPS(frames: (0..<5).map { frame(runID: runID, uptime: Double($0)) }, fix: nil)

        try await service.deleteAllData()

        #expect(try await service.frameCount() == 0)
        #expect(try await service.fetchRunSnapshot(runID: runID) == nil)
    }
}
