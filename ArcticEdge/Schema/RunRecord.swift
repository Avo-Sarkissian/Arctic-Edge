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

    init(runID: UUID, startTimestamp: Date) {
        self.runID = runID
        self.startTimestamp = startTimestamp
        self.endTimestamp = nil
        self.isOrphaned = false
    }
}
