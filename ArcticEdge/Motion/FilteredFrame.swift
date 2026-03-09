// FilteredFrame.swift
// ArcticEdge
//
// Sendable value type carrying all extracted IMU sensor fields from CMDeviceMotion.
// Constructed by MotionManager after applying the high-pass filter to userAcceleration.z.
// All stored properties are value types, so Sendable conformance is structural.

import Foundation

nonisolated struct FilteredFrame: Sendable {
    let timestamp: TimeInterval   // CMDeviceMotion.timestamp
    let runID: UUID
    let pitch: Double             // attitude.pitch (radians)
    let roll: Double              // attitude.roll (radians)
    let yaw: Double               // attitude.yaw (radians)
    let userAccelX: Double        // userAcceleration.x (g)
    let userAccelY: Double        // userAcceleration.y (g)
    let userAccelZ: Double        // userAcceleration.z (g)
    let gravityX: Double          // gravity.x
    let gravityY: Double          // gravity.y
    let gravityZ: Double          // gravity.z
    let rotationRateX: Double     // rotationRate.x (rad/s)
    let rotationRateY: Double     // rotationRate.y (rad/s)
    let rotationRateZ: Double     // rotationRate.z (rad/s)
    let filteredAccelZ: Double    // high-pass filtered userAcceleration.z (carve-pressure axis)
}
