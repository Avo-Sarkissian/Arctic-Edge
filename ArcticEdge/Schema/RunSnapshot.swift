// RunSnapshot.swift
// ArcticEdge
//
// Sendable value type mirroring RunRecord's analytics fields.
// Used by PostRunViewModel and HistoryViewModel to receive run data from PersistenceService
// across the @ModelActor -> @MainActor boundary under Swift 6 strict concurrency.
// RunRecord (@Model) is not Sendable; RunSnapshot is.

import Foundation

struct RunSnapshot: Sendable {
    let runID: UUID
    let startTimestamp: Date
    let endTimestamp: Date?
    let isOrphaned: Bool
    let topSpeed: Double?
    let avgSpeed: Double?
    let verticalDrop: Double?
    let distanceMeters: Double?
    let resortName: String?

    nonisolated init(from record: RunRecord) {
        self.runID = record.runID
        self.startTimestamp = record.startTimestamp
        self.endTimestamp = record.endTimestamp
        self.isOrphaned = record.isOrphaned
        self.topSpeed = record.topSpeed
        self.avgSpeed = record.avgSpeed
        self.verticalDrop = record.verticalDrop
        self.distanceMeters = record.distanceMeters
        self.resortName = record.resortName
    }
}
