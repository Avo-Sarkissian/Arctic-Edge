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

    // Phase 3: GPS speed snapshot stamped at flush time by AppModel (plan 03-06).
    // nil at record creation; set by PersistenceService.flushWithGPS(frames:gpsSpeed:).
    var gpsSpeed: Double?

    // Optional fields below are set after construction so SwiftData lightweight
    // migration can add them as nil columns. Do NOT move them into init().

    // Accuracy of the GPS fix this frame's speed came from. Needed to reject the
    // bad fixes that used to inflate top speed; the accuracy data was previously
    // captured by GPSManager and then thrown away before reaching storage.
    var gpsHorizontalAccuracy: Double?
    var gpsSpeedAccuracy: Double?

    // Wall-clock instant for this frame. `timestamp` is CMDeviceMotion uptime,
    // which is monotonic but meaningless as a date, so retention pruning and any
    // time-of-day query need a real Date.
    var wallClock: Date?

    // Barometric relative altitude in meters, stamped at flush time alongside the
    // GPS fix. The only honest source of vertical drop for a pocket-worn phone.
    var relativeAltitude: Double?

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
