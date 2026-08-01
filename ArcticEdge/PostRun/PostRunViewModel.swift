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
import simd

// MARK: - Value types (Sendable for actor-boundary crossings)

// RunStats now lives in RunStatsCalculator.swift, where it is computed.

struct SessionAggregates: Sendable {
    var runCount: Int = 0
    var totalVertical: Double? = nil        // meters; nil when no run measured vertical
    var totalSkiingTime: TimeInterval = 0   // seconds across completed runs
}

// MARK: - PostRunViewModel

@Observable
@MainActor
final class PostRunViewModel {

    private(set) var snapshots: [FrameSnapshot] = []
    private(set) var stats: RunStats = RunStats()
    private(set) var carvingScore: CarvingScore? = nil
    private(set) var sessionAggregates: SessionAggregates = SessionAggregates()
    private(set) var isLoading: Bool = false
    private(set) var selectedTimestamp: TimeInterval? = nil

    // MARK: - Data loading

    // Primary entry: called when the post-run sheet presents.
    //
    // This view is now a reader. Stats and the carving score are computed and
    // persisted at run finalization by RunFinalizer, so opening the sheet no
    // longer decides whether a run gets scored. The view falls back to computing
    // in-memory only when the persisted values are missing, which covers runs
    // recorded before finalization did this work.
    func loadData(
        runID: UUID,
        persistenceService: PersistenceService,
        ringBuffer: RingBuffer,
        isLiveRun: Bool = true
    ) async {
        isLoading = true
        defer { isLoading = false }

        // RACE FIX: flush remaining ring buffer frames before querying, so the
        // final couple of seconds reach storage. Only meaningful for the run that
        // just ended: opening an old history row must not disturb live capture.
        if isLiveRun {
            try? await persistenceService.emergencyFlush(ringBuffer: ringBuffer)
        }

        // Fetch FrameSnapshots for this run (Sendable — safe across @ModelActor boundary)
        let fetchedSnapshots = (try? await persistenceService.fetchFrameDataForRun(runID: runID)) ?? []
        snapshots = fetchedSnapshots

        let runSnapshot = try? await persistenceService.fetchRunSnapshot(runID: runID)

        // Prefer the values written at finalization.
        var loaded = RunStats(
            topSpeed: runSnapshot?.topSpeed,
            avgSpeed: runSnapshot?.avgSpeed,
            verticalDrop: runSnapshot?.verticalDrop,
            distanceMeters: runSnapshot?.distanceMeters,
            duration: runSnapshot?.duration ?? 0
        )
        if loaded.topSpeed == nil && loaded.distanceMeters == nil && !fetchedSnapshots.isEmpty {
            let computed = RunStatsCalculator.computeStats(from: fetchedSnapshots.map(\.statsFrame))
            loaded.topSpeed = computed.topSpeed
            loaded.avgSpeed = computed.avgSpeed
            loaded.verticalDrop = computed.verticalDrop
            loaded.distanceMeters = computed.distanceMeters
        }
        stats = loaded

        // Carving score: recompute only when the run has no persisted score, or
        // its score came from an older model version. The engine does FFT-scale
        // work, so re-running it on every sheet open was pure waste.
        let score = await resolveCarvingScore(
            runID: runID,
            snapshot: runSnapshot,
            frames: fetchedSnapshots,
            persistenceService: persistenceService
        )
        carvingScore = score

        // Compute session aggregates (all completed runs)
        let completedRuns = (try? await persistenceService.fetchCompletedRunSnapshots()) ?? []
        updateSessionAggregates(from: completedRuns)
    }

    private func resolveCarvingScore(
        runID: UUID,
        snapshot: RunSnapshot?,
        frames: [FrameSnapshot],
        persistenceService: PersistenceService
    ) async -> CarvingScore? {
        guard !frames.isEmpty else { return nil }
        let score = await computeCarvingScore(from: frames)
        // Persist when finalization did not, or when the stored score predates
        // the current model version.
        let storedIsCurrent = snapshot?.carvingScore != nil
            && snapshot?.carvingScoreVersion == score.modelVersion
        if !storedIsCurrent, let overall = score.overall {
            try? await persistenceService.updateCarvingScore(
                runID: runID, score: overall, version: score.modelVersion
            )
        }
        return score
    }

    // MARK: - Carving score

    // Build ScoringFrames from the persisted snapshots and run the engine
    // off the main actor (it does FFT/DSP work). Returns the full score so
    // the UI can show the headline number and the pillar/sub metric drill down.
    private func computeCarvingScore(from snapshots: [FrameSnapshot]) async -> CarvingScore {
        let frames = snapshots.map { snapshot in
            ScoringFrame(
                timestamp: snapshot.timestamp,
                userAccel: SIMD3(snapshot.userAccelX, snapshot.userAccelY, snapshot.userAccelZ),
                gravity: SIMD3(snapshot.gravityX, snapshot.gravityY, snapshot.gravityZ),
                rotationRate: SIMD3(snapshot.rotationRateX, snapshot.rotationRateY, snapshot.rotationRateZ),
                gpsSpeed: snapshot.gpsSpeed
            )
        }
        return await Task.detached { CarvingScorer.score(frames: frames) }.value
    }

    // Test-injectable variant: accepts pre-built StatsFrames directly.
    // Used by PostRunViewModelTests to avoid needing a real SwiftData PersistenceService.
    func loadDataFromFrameData(_ data: [StatsFrame]) {
        stats = RunStatsCalculator.computeStats(from: data)
    }

    // MARK: - Session aggregates

    private func updateSessionAggregates(from runs: [RunSnapshot]) {
        var agg = SessionAggregates()
        agg.runCount = runs.count
        // nil rather than 0 when no run measured vertical: a day with no barometer
        // data has unknown vertical, not zero vertical.
        let verticals = runs.compactMap { $0.verticalDrop }
        agg.totalVertical = verticals.isEmpty ? nil : verticals.reduce(0, +)
        agg.totalSkiingTime = runs.compactMap { $0.duration }.reduce(0, +)
        sessionAggregates = agg
    }

    // Test-injectable session aggregates — accepts [RunRecord] directly.
    // RunRecord @Model instances can be created without a ModelContainer for testing.
    func loadSessionAggregatesFromRecords(_ records: [RunRecord]) {
        var agg = SessionAggregates()
        agg.runCount = records.count
        let verticals = records.compactMap { $0.verticalDrop }
        agg.totalVertical = verticals.isEmpty ? nil : verticals.reduce(0, +)
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

    // Scrubber lookup on StatsFrame — used by tests (no ModelContainer needed).
    func selectFrameData(at timestamp: TimeInterval, from data: [StatsFrame]) -> StatsFrame? {
        data.min(by: { abs($0.timestamp - timestamp) < abs($1.timestamp - timestamp) })
    }
}
