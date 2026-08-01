// FilteredFrame.swift
// ArcticEdge
//
// Sendable value type carrying all extracted IMU sensor fields from CMDeviceMotion.
// Constructed by MotionManager after projecting acceleration onto gravity and
// high-pass filtering the vertical component.
// All stored properties are value types, so Sendable conformance is structural.

import Foundation
import simd

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
    // Legacy channel: high-pass of the raw device-frame z axis. For a pocket-worn
    // phone the device frame is arbitrary, so this is an orientation-dependent
    // projection with no physical meaning. Retained only so existing rows keep
    // their column; nothing reads it any more.
    let filteredAccelZ: Double

    // Gravity-referenced channels. These are the honest ones: gravity is the only
    // per-frame orientation anchor a pocket phone has, so projecting onto it makes
    // the values comparable between runs, skiers, and pocket positions.
    // Defaulted so test fixtures that only care about the raw axes stay concise.
    // Production always supplies both from MotionManager's gravity projection.
    var filteredVerticalAccel: Double = 0     // high-pass of acceleration along gravity (g)
    var horizontalAccelMagnitude: Double = 0  // |acceleration in the horizontal plane| (g)
}

nonisolated extension FilteredFrame {

    /// Unit vector along gravity. Falls back to device z if gravity is degenerate,
    /// which happens only in free fall.
    static func downAxis(gx: Double, gy: Double, gz: Double) -> SIMD3<Double> {
        let gravity = SIMD3(gx, gy, gz)
        let magnitude = simd_length(gravity)
        guard magnitude > 1e-9 else { return SIMD3(0, 0, -1) }
        return gravity / magnitude
    }

    /// Acceleration along gravity and the magnitude of what is left in the
    /// horizontal plane. Mirrors ScoringFrame so the live view and the scoring
    /// engine describe the same physical quantities.
    static func project(
        accel: SIMD3<Double>,
        gravityX: Double, gravityY: Double, gravityZ: Double
    ) -> (vertical: Double, horizontalMagnitude: Double) {
        let down = downAxis(gx: gravityX, gy: gravityY, gz: gravityZ)
        let vertical = simd_dot(accel, down)
        let horizontal = accel - vertical * down
        return (vertical, simd_length(horizontal))
    }
}
