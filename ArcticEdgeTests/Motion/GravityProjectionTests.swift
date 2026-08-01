// GravityProjectionTests.swift
// ArcticEdgeTests/Motion
//
// The property that makes the live and post-run signals honest: two skiers with
// the phone in different pocket orientations must read the same numbers from the
// same physical motion. A raw device axis cannot do this; a gravity projection can.

import Testing
import Foundation
import simd
@testable import ArcticEdge

@Suite("Gravity projection")
struct GravityProjectionTests {

    /// Rotates a vector about the x axis. Stands in for the phone sitting at a
    /// different angle in the pocket.
    private func rotateAboutX(_ v: SIMD3<Double>, radians: Double) -> SIMD3<Double> {
        let c = cos(radians), s = sin(radians)
        return SIMD3(v.x, c * v.y - s * v.z, s * v.y + c * v.z)
    }

    @Test("vertical and horizontal components are invariant to pocket orientation")
    func testProjectionIsOrientationInvariant() {
        // A fixed physical acceleration and gravity, observed through two device
        // orientations 40 degrees apart.
        let accelWorld = SIMD3(0.30, 0.15, -0.85)
        let gravityWorld = SIMD3(0.0, 0.0, -1.0)

        let upright = FilteredFrame.project(
            accel: accelWorld,
            gravityX: gravityWorld.x, gravityY: gravityWorld.y, gravityZ: gravityWorld.z
        )

        let angle = 40.0 * .pi / 180
        let accelRotated = rotateAboutX(accelWorld, radians: angle)
        let gravityRotated = rotateAboutX(gravityWorld, radians: angle)
        let tilted = FilteredFrame.project(
            accel: accelRotated,
            gravityX: gravityRotated.x, gravityY: gravityRotated.y, gravityZ: gravityRotated.z
        )

        #expect(abs(upright.vertical - tilted.vertical) < 1e-9,
                "vertical load must not depend on how the phone sits")
        #expect(abs(upright.horizontalMagnitude - tilted.horizontalMagnitude) < 1e-9,
                "horizontal load must not depend on how the phone sits")
    }

    @Test("the raw device axis is NOT orientation invariant")
    func testRawAxisVariesWithOrientation() {
        // The regression this replaced: userAccel.z changes with pocket pose even
        // though the skiing did not.
        let accelWorld = SIMD3(0.30, 0.15, -0.85)
        let rotated = rotateAboutX(accelWorld, radians: 40.0 * .pi / 180)
        #expect(abs(accelWorld.z - rotated.z) > 0.1,
                "raw z must differ, demonstrating why it cannot be a physical metric")
    }

    @Test("pure vertical acceleration produces no horizontal component")
    func testPureVerticalHasNoHorizontal() {
        let result = FilteredFrame.project(
            accel: SIMD3(0, 0, -0.5),
            gravityX: 0, gravityY: 0, gravityZ: -1
        )
        #expect(abs(result.vertical - 0.5) < 1e-9)
        #expect(result.horizontalMagnitude < 1e-9)
    }

    @Test("pure lateral acceleration produces no vertical component")
    func testPureLateralHasNoVertical() {
        let result = FilteredFrame.project(
            accel: SIMD3(0.7, 0, 0),
            gravityX: 0, gravityY: 0, gravityZ: -1
        )
        #expect(abs(result.vertical) < 1e-9)
        #expect(abs(result.horizontalMagnitude - 0.7) < 1e-9)
    }

    @Test("degenerate gravity falls back without producing NaN")
    func testDegenerateGravityIsSafe() {
        // Free fall drives the gravity estimate toward zero. The result must stay
        // finite rather than poisoning every downstream metric with NaN.
        let result = FilteredFrame.project(
            accel: SIMD3(0.1, 0.2, 0.3),
            gravityX: 0, gravityY: 0, gravityZ: 0
        )
        #expect(result.vertical.isFinite)
        #expect(result.horizontalMagnitude.isFinite)
    }

    @Test("projection matches the scoring engine's own definition")
    func testMatchesScoringFrame() {
        // The live view and the score must describe the same physical quantity.
        let accel = SIMD3(0.4, -0.2, 0.6)
        let gravity = SIMD3(0.1, 0.2, -0.97)

        let projected = FilteredFrame.project(
            accel: accel,
            gravityX: gravity.x, gravityY: gravity.y, gravityZ: gravity.z
        )
        let scoring = ScoringFrame(
            timestamp: 0, userAccel: accel, gravity: gravity,
            rotationRate: .zero, gpsSpeed: nil
        )

        #expect(abs(projected.vertical - scoring.verticalAccel) < 1e-12)
        #expect(abs(projected.horizontalMagnitude - scoring.horizontalAccelMagnitude) < 1e-12)
    }
}
