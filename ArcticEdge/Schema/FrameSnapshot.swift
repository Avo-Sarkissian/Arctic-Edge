// FrameSnapshot.swift
// ArcticEdge
//
// Sendable value type mirroring FrameRecord's analytics fields.
// Used by PostRunViewModel to receive frame data from PersistenceService
// across the @ModelActor -> @MainActor boundary under Swift 6 strict concurrency.
// FrameRecord (@Model) is not Sendable; FrameSnapshot is.

import Foundation

struct FrameSnapshot: Sendable {
    let timestamp: TimeInterval
    let runID: UUID
    let pitch: Double
    let roll: Double
    let yaw: Double
    let userAccelX: Double
    let userAccelY: Double
    let userAccelZ: Double
    let filteredAccelZ: Double
    let gpsSpeed: Double?

    nonisolated init(from record: FrameRecord) {
        self.timestamp = record.timestamp
        self.runID = record.runID
        self.pitch = record.pitch
        self.roll = record.roll
        self.yaw = record.yaw
        self.userAccelX = record.userAccelX
        self.userAccelY = record.userAccelY
        self.userAccelZ = record.userAccelZ
        self.filteredAccelZ = record.filteredAccelZ
        self.gpsSpeed = record.gpsSpeed
    }
}
