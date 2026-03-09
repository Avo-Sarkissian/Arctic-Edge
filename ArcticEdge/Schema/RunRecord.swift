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

    init(runID: UUID, startTimestamp: Date) {
        self.runID = runID
        self.startTimestamp = startTimestamp
        self.endTimestamp = nil
        self.isOrphaned = false
    }
}
