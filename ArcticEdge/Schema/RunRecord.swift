// RunRecord.swift
// ArcticEdge
//
// SwiftData @Model representing a single ski run session.
// isOrphaned is set true during crash recovery when a run has no endTimestamp
// and the UserDefaults session sentinel was still set on relaunch.

import SwiftData
import Foundation

@Model
final class RunRecord {
    #Index<RunRecord>([\.runID], [\.startTimestamp])

    var runID: UUID
    var startTimestamp: Date
    var endTimestamp: Date?
    var isOrphaned: Bool

    // Phase 3 analytics fields — all Optional for lightweight migration from V1.
    // Do NOT include in init(); SwiftData initialises them to nil via lightweight migration.
    var topSpeed: Double?
    var avgSpeed: Double?
    var verticalDrop: Double?
    var distanceMeters: Double?
    var resortName: String?

    // Carving score (CRVG-01). Optional for lightweight migration; do NOT add
    // to init(). Computed post-run by PostRunViewModel and written via
    // PersistenceService.updateCarvingScore. carvingScoreVersion records the
    // frozen model version so runs stay comparable across recalibration.
    var carvingScore: Double?
    var carvingScoreVersion: String?

    // Coordinate the run started at, captured from the first trustworthy GPS fix.
    // Reverse geocoding (HIST-02) needs a location to resolve a resort name from.
    var latitude: Double?
    var longitude: Double?

    init(runID: UUID, startTimestamp: Date) {
        self.runID = runID
        self.startTimestamp = startTimestamp
        self.endTimestamp = nil
        self.isOrphaned = false
    }
}
