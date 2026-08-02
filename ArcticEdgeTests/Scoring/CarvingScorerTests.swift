// CarvingScorerTests.swift
// ArcticEdge
//
// End to end spec for the carving score. The key invariants:
//  - a smooth, rhythmic, symmetric run scores higher than a jerky one
//  - too little data yields no score (nil), never a misleading number
//  - the GPS free pillars still produce a score when GPS is absent
//  - the score stays within 0...100

import Testing
import Foundation
import simd
@testable import ArcticEdge

struct CarvingScorerTests {

    // MARK: Synthetic run generators

    /// A clean, rhythmic, symmetric carving run: smooth yaw oscillation,
    /// smooth lateral loading, no high frequency chatter.
    private func cleanRun(seconds: Double = 14.0, fs: Double = 50.0, gps: Double? = 15.0) -> [ScoringFrame] {
        let n = Int(fs * seconds)
        let f = 0.5 // 1 s turns
        return (0..<n).map { i in
            let t = Double(i) / fs
            let yaw = 1.0 * sin(2 * .pi * f * t)
            let lateral = 1.2 * sin(2 * .pi * f * t)           // smooth load
            let vertical = 0.15 * sin(2 * .pi * 2 * f * t)     // gentle cross under
            return ScoringFrame(
                timestamp: t,
                userAccel: SIMD3(lateral, 0, vertical),
                gravity: SIMD3(0, 0, -1.0),
                rotationRate: SIMD3(0, 0, yaw),
                gpsSpeed: gps
            )
        }
    }

    /// A jerky, irregular, asymmetric run: chatter on accel and gyro,
    /// uneven cadence, weaker and noisier turns. Same overall rhythm band.
    private func jerkyRun(seconds: Double = 14.0, fs: Double = 50.0, gps: Double? = 15.0) -> [ScoringFrame] {
        let n = Int(fs * seconds)
        let f = 0.5
        return (0..<n).map { i in
            let t = Double(i) / fs
            // Irregular cadence: wobble the phase a little over time.
            let phase = 2 * .pi * f * t + 0.6 * sin(2 * .pi * 0.13 * t)
            let base = sin(phase)
            // Asymmetry: left turns (base > 0) are loaded harder than right.
            let asym = base > 0 ? 1.3 : 0.7
            let chatterA = 0.5 * sin(2 * .pi * 21.0 * t) + 0.3 * sin(2 * .pi * 33.0 * t)
            let chatterG = 0.6 * sin(2 * .pi * 24.0 * t)
            let yaw = 1.0 * base + chatterG
            let lateral = 1.2 * base * asym + chatterA
            let vertical = 0.15 * sin(2 * .pi * 2 * f * t) + 0.4 * sin(2 * .pi * 27.0 * t)
            return ScoringFrame(
                timestamp: t,
                userAccel: SIMD3(lateral, 0, vertical),
                gravity: SIMD3(0, 0, -1.0),
                rotationRate: SIMD3(0, 0, yaw),
                gpsSpeed: gps
            )
        }
    }

    // MARK: Tests

    @Test func cleanRunOutscoresJerkyRun() {
        let clean = CarvingScorer.score(frames: cleanRun())
        let jerky = CarvingScorer.score(frames: jerkyRun())
        #expect(clean.overall != nil)
        #expect(jerky.overall != nil)
        #expect((clean.overall ?? 0) > (jerky.overall ?? 0))
    }

    @Test func insufficientDataYieldsNoScore() {
        let frames = Array(cleanRun().prefix(20)) // far below the min turn gate
        let score = CarvingScorer.score(frames: frames)
        #expect(score.overall == nil)
        #expect(score.dataQuality.sufficientData == false)
    }

    @Test func scoreIsProducedWithoutGPS() {
        // GPS absent: pillar C (carving intensity) drops out, but the
        // GPS free pillars A and B still produce a score.
        let score = CarvingScorer.score(frames: cleanRun(gps: nil))
        #expect(score.overall != nil)
        #expect(score.pillars.carvingIntensity == nil)
        #expect(score.dataQuality.gpsCoverage < 0.01)
    }

    @Test func overallStaysWithinBounds() {
        for frames in [cleanRun(), jerkyRun(), cleanRun(gps: nil)] {
            let score = CarvingScorer.score(frames: frames)
            if let overall = score.overall {
                #expect(overall >= 0 && overall <= 100)
            }
        }
    }

    @Test func scoreReportsModelVersionAndTurnCount() {
        let score = CarvingScorer.score(frames: cleanRun())
        #expect(score.modelVersion == CarvingScoreModel.v1.version)
        #expect(score.turnCount >= 8)
    }
}
