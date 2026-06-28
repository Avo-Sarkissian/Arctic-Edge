// ScoringFrameTests.swift
// ArcticEdge
//
// Spec for the gravity projection that makes a pocket worn phone's
// signals orientation robust. The phone pose is arbitrary, so every
// axis specific feature is defined relative to the gravity vector.

import Testing
import Foundation
import simd
@testable import ArcticEdge

struct ScoringFrameTests {

    private func frame(
        userAccel: SIMD3<Double>,
        gravity: SIMD3<Double>,
        rotationRate: SIMD3<Double> = .zero,
        gpsSpeed: Double? = nil
    ) -> ScoringFrame {
        ScoringFrame(timestamp: 0, userAccel: userAccel, gravity: gravity, rotationRate: rotationRate, gpsSpeed: gpsSpeed)
    }

    @Test func accelerationAlongGravityIsAllVerticalNoHorizontal() {
        // Gravity down the device z axis; acceleration purely along it.
        let f = frame(userAccel: SIMD3(0, 0, 2.0), gravity: SIMD3(0, 0, -1.0))
        #expect(abs(f.horizontalAccelMagnitude) < 1e-9)
        #expect(abs(abs(f.verticalAccel) - 2.0) < 1e-9)
    }

    @Test func accelerationPerpendicularToGravityIsAllHorizontal() {
        // Gravity down z; acceleration purely in the horizontal plane.
        let f = frame(userAccel: SIMD3(1.5, 0, 0), gravity: SIMD3(0, 0, -1.0))
        #expect(abs(f.verticalAccel) < 1e-9)
        #expect(abs(f.horizontalAccelMagnitude - 1.5) < 1e-9)
    }

    @Test func projectionIsOrientationInvariant() {
        // Same physical acceleration relative to gravity, but the device
        // is rotated arbitrarily (pocket pose). Projections must match.
        let q = simd_quatd(angle: 0.9, axis: normalize(SIMD3(0.3, 0.7, 0.2)))
        let accelWorld = SIMD3(1.5, 0.0, 2.0)
        let gravityWorld = SIMD3(0.0, 0.0, -1.0)
        let flat = frame(userAccel: accelWorld, gravity: gravityWorld)
        let rotated = frame(userAccel: q.act(accelWorld), gravity: q.act(gravityWorld))
        #expect(abs(flat.verticalAccel - rotated.verticalAccel) < 1e-9)
        #expect(abs(flat.horizontalAccelMagnitude - rotated.horizontalAccelMagnitude) < 1e-9)
    }

    @Test func yawRateAboutVerticalPicksRotationAroundGravity() {
        // Rotation purely about the gravity (vertical) axis.
        let f = frame(userAccel: .zero, gravity: SIMD3(0, 0, -1.0), rotationRate: SIMD3(0, 0, 1.2))
        #expect(abs(abs(f.yawRateAboutVertical) - 1.2) < 1e-9)
    }

    @Test func angularSpeedIsRotationInvariantMagnitude() {
        let f = frame(userAccel: .zero, gravity: SIMD3(0, 0, -1.0), rotationRate: SIMD3(0.3, 0.4, 0.0))
        #expect(abs(f.angularSpeed - 0.5) < 1e-9) // 3-4-5 triangle
    }
}
