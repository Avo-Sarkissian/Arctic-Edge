// RunFinalizer.swift
// ArcticEdge
//
// Computes and persists everything a finished run should carry: statistics, the
// carving score, and the coordinate history needs to name the resort.
//
// Why finalization and not the post-run view: the carving score is the product's
// headline feature, but it used to be computed only when PostRunAnalysisView
// happened to load. That view is reached through a sheet, gated on the app being
// foregrounded on the live tab at the exact moment a run ended. A skier taking
// twenty runs and glancing at three sheets ended the day with seventeen runs
// carrying no score, silently. Run finalization is the one moment guaranteed to
// happen for every run, so the work belongs here.
//
// This runs off the main actor: it fetches frames, does FFT-scale DSP, and writes
// back through the model actor.

import Foundation
import simd

nonisolated struct RunFinalizer: Sendable {

    let persistence: PersistenceService

    /// Computes stats and the carving score for a finished run and writes both to
    /// its RunRecord. Safe to call more than once: the result is deterministic for
    /// a given frame set.
    func finalize(runID: UUID) async {
        let snapshots = (try? await persistence.fetchFrameDataForRun(runID: runID)) ?? []
        guard !snapshots.isEmpty else { return }

        // Statistics.
        let stats = RunStatsCalculator.computeStats(from: snapshots.map(\.statsFrame))
        try? await persistence.updateRunStats(
            runID: runID,
            topSpeed: stats.topSpeed,
            avgSpeed: stats.avgSpeed,
            verticalDrop: stats.verticalDrop,
            distanceMeters: stats.distanceMeters
        )

        // Carving score. A run below the data gate returns nil overall, which is
        // persisted as "no score" rather than a misleading zero.
        let score = CarvingScorer.score(frames: snapshots.map(Self.scoringFrame))
        if let overall = score.overall {
            try? await persistence.updateCarvingScore(
                runID: runID,
                score: overall,
                version: score.modelVersion
            )
        }
    }

    /// Stores the coordinate a run started at, taken from the first trustworthy
    /// fix seen while the run was active. History reverse geocodes from this.
    func recordCoordinate(runID: UUID, latitude: Double, longitude: Double) async {
        try? await persistence.updateRunCoordinate(runID: runID, latitude: latitude, longitude: longitude)
    }

    private static func scoringFrame(_ snapshot: FrameSnapshot) -> ScoringFrame {
        ScoringFrame(
            timestamp: snapshot.timestamp,
            userAccel: SIMD3(snapshot.userAccelX, snapshot.userAccelY, snapshot.userAccelZ),
            gravity: SIMD3(snapshot.gravityX, snapshot.gravityY, snapshot.gravityZ),
            rotationRate: SIMD3(snapshot.rotationRateX, snapshot.rotationRateY, snapshot.rotationRateZ),
            gpsSpeed: snapshot.gpsSpeed
        )
    }
}
