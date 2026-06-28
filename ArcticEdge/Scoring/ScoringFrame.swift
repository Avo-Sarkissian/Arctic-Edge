// ScoringFrame.swift
// ArcticEdge
//
// Input sample for the carving score engine. The phone is pocket worn,
// so its device frame orientation is arbitrary. Every axis specific
// feature is derived relative to the gravity vector, which is the only
// reliable per frame orientation anchor. See docs/CARVING-SCORE.md.

import Foundation
import simd

nonisolated struct ScoringFrame: Sendable, Equatable {
    let timestamp: TimeInterval        // seconds, monotonic device uptime
    let userAccel: SIMD3<Double>       // g, device frame, gravity removed
    let gravity: SIMD3<Double>         // g, device frame
    let rotationRate: SIMD3<Double>    // rad/s, device frame (gyro)
    let gpsSpeed: Double?              // m/s, optional (stamped periodically)
}

nonisolated extension ScoringFrame {

    /// Unit vector pointing down (along gravity). Falls back to device z
    /// if gravity is degenerate, which should not happen in practice.
    var downAxis: SIMD3<Double> {
        let mag = simd_length(gravity)
        guard mag > 1e-9 else { return SIMD3(0, 0, -1) }
        return gravity / mag
    }

    /// Acceleration component along gravity (gravity aligned vertical).
    var verticalAccel: Double {
        simd_dot(userAccel, downAxis)
    }

    /// Magnitude of the acceleration in the horizontal plane. This is
    /// orientation robust in magnitude. It cannot be split into lateral
    /// vs fore aft without a heading, which a pocket phone does not have.
    var horizontalAccelMagnitude: Double {
        let v = verticalAccel
        let horizontal = userAccel - v * downAxis
        return simd_length(horizontal)
    }

    /// Turn rate about the vertical (gravity) axis. Orientation robust.
    var yawRateAboutVertical: Double {
        simd_dot(rotationRate, downAxis)
    }

    /// Total angular speed. Rotation invariant by construction.
    var angularSpeed: Double {
        simd_length(rotationRate)
    }
}
