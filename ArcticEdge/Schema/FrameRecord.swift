// FrameRecord.swift
// ArcticEdge
//
// SwiftData @Model for persisting a single FilteredFrame to disk.
// Indexes on timestamp, runID, and composite (runID, timestamp) support
// per-run queries sorted by time without full-table scans.

import SwiftData
import Foundation

@Model
final class FrameRecord {
    #Index<FrameRecord>([\.timestamp], [\.runID], [\.runID, \.timestamp])

    var timestamp: TimeInterval
    var runID: UUID
    var pitch: Double
    var roll: Double
    var yaw: Double
    var userAccelX: Double
    var userAccelY: Double
    var userAccelZ: Double
    var gravityX: Double
    var gravityY: Double
    var gravityZ: Double
    var rotationRateX: Double
    var rotationRateY: Double
    var rotationRateZ: Double
    var filteredAccelZ: Double

    init(from frame: FilteredFrame) {
        self.timestamp = frame.timestamp
        self.runID = frame.runID
        self.pitch = frame.pitch
        self.roll = frame.roll
        self.yaw = frame.yaw
        self.userAccelX = frame.userAccelX
        self.userAccelY = frame.userAccelY
        self.userAccelZ = frame.userAccelZ
        self.gravityX = frame.gravityX
        self.gravityY = frame.gravityY
        self.gravityZ = frame.gravityZ
        self.rotationRateX = frame.rotationRateX
        self.rotationRateY = frame.rotationRateY
        self.rotationRateZ = frame.rotationRateZ
        self.filteredAccelZ = frame.filteredAccelZ
    }
}
