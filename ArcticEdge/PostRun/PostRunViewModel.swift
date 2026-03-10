// PostRunViewModel.swift
// ArcticEdge
//
// @Observable @MainActor view model for PostRunAnalysisView.
// Loads FrameSnapshots and RunSnapshot for a completed run, computes stats,
// and provides session aggregates for "today so far" context.
//
// RACE FIX: loadData() calls emergencyFlush before any query.
// This ensures the final ~2 seconds of frames (still in RingBuffer) reach SwiftData
// before the chart data is fetched, preventing truncated post-run charts.
//
// SENDABLE: FrameSnapshot/RunSnapshot (Sendable value types) cross the
// @ModelActor -> @MainActor boundary safely under Swift 6 strict concurrency.

import Foundation
import SwiftData

// MARK: - Value types (Sendable for actor-boundary crossings)

struct RunStats: Sendable {
    var topSpeed: Double = 0         // m/s
    var avgSpeed: Double = 0         // m/s
    var verticalDrop: Double = 0     // meters (estimated: speed * sin(pitch) * dt)
    var distanceMeters: Double = 0   // meters
    var duration: TimeInterval = 0   // seconds
}

struct SessionAggregates: Sendable {
    var runCount: Int = 0
    var totalVertical: Double = 0           // meters (sum of verticalDrop across all runs)
    var totalSkiingTime: TimeInterval = 0   // seconds across completed runs
}

// MARK: - PostRunViewModel

@Observable
@MainActor
final class PostRunViewModel {

    private(set) var snapshots: [FrameSnapshot] = []
    private(set) var stats: RunStats = RunStats()
    private(set) var sessionAggregates: SessionAggregates = SessionAggregates()
    private(set) var isLoading: Bool = false
    private(set) var selectedTimestamp: TimeInterval? = nil

    // MARK: - FrameData (test-injectable Sendable mirror)
    //
    // Mirrors FrameSnapshot numeric fields. Tests use [FrameData] directly;
    // production path maps FrameSnapshot -> FrameData for stats computation.
    // This avoids needing a SwiftData ModelContainer in unit tests.
    struct FrameData: Sendable {
        var timestamp: TimeInterval
        var pitch: Double
        var gpsSpeed: Double?
        var filteredAccelZ: Double
        var userAccelX: Double
        var userAccelY: Double
        var userAccelZ: Double
    }

    // MARK: - Data loading

    // Primary entry: called when post-run sheet auto-presents.
    // emergencyFlush must complete before any fetch to avoid truncated charts.
    func loadData(
        runID: UUID,
        persistenceService: PersistenceService,
        ringBuffer: RingBuffer
    ) async {
        isLoading = true
        defer { isLoading = false }

        // RACE FIX: flush remaining ring buffer frames before querying
        try? await persistenceService.emergencyFlush(ringBuffer: ringBuffer)

        // Fetch FrameSnapshots for this run (Sendable — safe across @ModelActor boundary)
        let fetchedSnapshots = (try? await persistenceService.fetchFrameDataForRun(runID: runID)) ?? []
        snapshots = fetchedSnapshots

        // Compute per-run stats from snapshots
        let frameData = fetchedSnapshots.map {
            FrameData(
                timestamp: $0.timestamp,
                pitch: $0.pitch,
                gpsSpeed: $0.gpsSpeed,
                filteredAccelZ: $0.filteredAccelZ,
                userAccelX: $0.userAccelX,
                userAccelY: $0.userAccelY,
                userAccelZ: $0.userAccelZ
            )
        }
        stats = computeStats(from: frameData)

        // Compute run duration from RunSnapshot (Sendable — safe across @ModelActor boundary)
        if let runSnap = try? await persistenceService.fetchRunSnapshot(runID: runID),
           let end = runSnap.endTimestamp {
            stats.duration = end.timeIntervalSince(runSnap.startTimestamp)
        }

        // Compute session aggregates (all completed runs)
        let completedRuns = (try? await persistenceService.fetchCompletedRunSnapshots()) ?? []
        updateSessionAggregates(from: completedRuns)
    }

    // Test-injectable variant: accepts pre-built FrameData directly.
    // Used by PostRunViewModelTests to avoid needing a real SwiftData PersistenceService.
    func loadDataFromFrameData(_ data: [FrameData]) {
        stats = computeStats(from: data)
    }

    // MARK: - Stats computation (FrameData overload — used by tests and internally)

    func computeStats(from data: [FrameData]) -> RunStats {
        let speeds = data.compactMap { $0.gpsSpeed }.filter { $0 > 0 }
        var result = RunStats()
        result.topSpeed = speeds.max() ?? 0
        result.avgSpeed = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)

        // Vertical drop and distance: integrate over consecutive frame pairs.
        // verticalDrop is estimated: speed * sin(pitch) * dt.
        // pitch is phone tilt (not slope angle) — see Phase 4 calibration concern.
        for (a, b) in zip(data, data.dropFirst()) {
            let dt = b.timestamp - a.timestamp
            guard dt > 0 else { continue }
            let speed = a.gpsSpeed ?? 0
            result.verticalDrop += abs(speed * sin(a.pitch) * dt)
            result.distanceMeters += speed * dt
        }

        return result
    }

    // MARK: - Session aggregates

    private func updateSessionAggregates(from runs: [RunSnapshot]) {
        var agg = SessionAggregates()
        agg.runCount = runs.count
        agg.totalVertical = runs.compactMap { $0.verticalDrop }.reduce(0, +)
        agg.totalSkiingTime = runs.compactMap { run -> TimeInterval? in
            guard let end = run.endTimestamp else { return nil }
            return end.timeIntervalSince(run.startTimestamp)
        }.reduce(0, +)
        sessionAggregates = agg
    }

    // Test-injectable session aggregates — accepts [RunRecord] directly.
    // RunRecord @Model instances can be created without a ModelContainer for testing.
    func loadSessionAggregatesFromRecords(_ records: [RunRecord]) {
        var agg = SessionAggregates()
        agg.runCount = records.count
        agg.totalVertical = records.compactMap { $0.verticalDrop }.reduce(0, +)
        agg.totalSkiingTime = records.compactMap { run -> TimeInterval? in
            guard let end = run.endTimestamp else { return nil }
            return end.timeIntervalSince(run.startTimestamp)
        }.reduce(0, +)
        sessionAggregates = agg
    }

    // MARK: - Scrubber

    // Returns the FrameSnapshot with timestamp nearest to the selected value.
    func selectSnapshot(at timestamp: TimeInterval) -> FrameSnapshot? {
        selectedTimestamp = timestamp
        return snapshots.min(by: { abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp) })
    }

    // Scrubber lookup on FrameData — used by tests (no ModelContainer needed).
    func selectFrameData(at timestamp: TimeInterval, from data: [FrameData]) -> FrameData? {
        data.min(by: { abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp) })
    }
}
