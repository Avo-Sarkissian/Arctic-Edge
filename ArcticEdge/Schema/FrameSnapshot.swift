// FrameSnapshot.swift
// ArcticEdge
//
// Sendable value type mirroring FrameRecord's analytics fields.
// Used by PostRunViewModel to receive frame data from PersistenceService
// across the @ModelActor -> @MainActor boundary under Swift 6 strict concurrency.
// FrameRecord (@Model) is not Sendable; FrameSnapshot is.

import Foundation

// nonisolated so members stay usable off the main actor: SWIFT_DEFAULT_ACTOR_ISOLATION
// is MainActor, which would otherwise isolate the computed projections below.
nonisolated struct FrameSnapshot: Sendable {
    let timestamp: TimeInterval
    let runID: UUID
    let pitch: Double
    let roll: Double
    let yaw: Double
    let userAccelX: Double
    let userAccelY: Double
    let userAccelZ: Double
    // Gravity and rotationRate (gyro) are required by the carving score
    // engine to project signals into a gravity aligned frame. They were
    // previously dropped from this snapshot.
    let gravityX: Double
    let gravityY: Double
    let gravityZ: Double
    let rotationRateX: Double
    let rotationRateY: Double
    let rotationRateZ: Double
    let filteredAccelZ: Double
    // Gravity-referenced channels. nil on rows captured before the projection
    // existed; charts fall back to drawing nothing rather than a bogus line.
    let filteredVerticalAccel: Double?
    let horizontalAccelMagnitude: Double?
    let gpsSpeed: Double?
    // Accuracy of the fix that gpsSpeed came from, so stats can reject bad samples.
    let gpsHorizontalAccuracy: Double?
    let gpsSpeedAccuracy: Double?
    // Barometric relative altitude: the vertical drop source.
    let relativeAltitude: Double?

    nonisolated init(from record: FrameRecord) {
        self.timestamp = record.timestamp
        self.runID = record.runID
        self.pitch = record.pitch
        self.roll = record.roll
        self.yaw = record.yaw
        self.userAccelX = record.userAccelX
        self.userAccelY = record.userAccelY
        self.userAccelZ = record.userAccelZ
        self.gravityX = record.gravityX
        self.gravityY = record.gravityY
        self.gravityZ = record.gravityZ
        self.rotationRateX = record.rotationRateX
        self.rotationRateY = record.rotationRateY
        self.rotationRateZ = record.rotationRateZ
        self.filteredAccelZ = record.filteredAccelZ
        self.filteredVerticalAccel = record.filteredVerticalAccel
        self.horizontalAccelMagnitude = record.horizontalAccelMagnitude
        self.gpsSpeed = record.gpsSpeed
        self.gpsHorizontalAccuracy = record.gpsHorizontalAccuracy
        self.gpsSpeedAccuracy = record.gpsSpeedAccuracy
        self.relativeAltitude = record.relativeAltitude
    }

    /// Projection used by the statistics calculator.
    var statsFrame: StatsFrame {
        StatsFrame(
            timestamp: timestamp,
            gpsSpeed: gpsSpeed,
            gpsHorizontalAccuracy: gpsHorizontalAccuracy,
            gpsSpeedAccuracy: gpsSpeedAccuracy,
            relativeAltitude: relativeAltitude
        )
    }
}
