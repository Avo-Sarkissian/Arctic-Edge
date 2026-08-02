// TurnSegmenterTests.swift
// ArcticEdge
//
// Spec for turn segmentation. Turns are the foundation of every per
// turn sub metric, so detection must be robust: real oscillation in the
// gravity referenced yaw rate becomes turns, straight running does not.

import Testing
import Foundation
import simd
@testable import ArcticEdge

struct TurnSegmenterTests {

    /// Build frames whose yaw rate about vertical follows `yaw(t)`.
    /// Gravity points down device z, so rotationRate.z maps to yaw about vertical.
    private func frames(sampleRate fs: Double, seconds: Double, yaw: (Double) -> Double) -> [ScoringFrame] {
        let n = Int(fs * seconds)
        return (0..<n).map { i in
            let t = Double(i) / fs
            return ScoringFrame(
                timestamp: t,
                userAccel: SIMD3(0, 0, 0),
                gravity: SIMD3(0, 0, -1.0),
                rotationRate: SIMD3(0, 0, yaw(t)),
                gpsSpeed: 15.0
            )
        }
    }

    @Test func rhythmicOscillationProducesOneTurnPerHalfCycle() {
        // 0.5 Hz yaw oscillation for 10 s: zero crossings every 1 s,
        // so roughly 9 to 10 detected turns.
        let fs = 50.0
        let f = frames(sampleRate: fs, seconds: 10.0) { t in sin(2 * .pi * 0.5 * t) }
        let turns = TurnSegmenter().detectTurns(f, sampleRate: fs)
        #expect(turns.count >= 8 && turns.count <= 10)
        // Turn durations are about 1 s.
        for turn in turns {
            #expect(turn.duration > 0.3 && turn.duration < 5.0)
        }
    }

    @Test func straightRunningProducesNoTurns() {
        // Tiny high frequency jitter, below the minimum peak yaw rate gate.
        let fs = 50.0
        let f = frames(sampleRate: fs, seconds: 10.0) { t in 0.03 * sin(2 * .pi * 8.0 * t) }
        let turns = TurnSegmenter().detectTurns(f, sampleRate: fs)
        #expect(turns.isEmpty)
    }

    @Test func turnsAlternateDirection() {
        let fs = 50.0
        let f = frames(sampleRate: fs, seconds: 8.0) { t in sin(2 * .pi * 0.5 * t) }
        let turns = TurnSegmenter().detectTurns(f, sampleRate: fs)
        #expect(turns.count >= 4)
        // Consecutive turns should flip left and right.
        for i in 1..<turns.count {
            #expect(turns[i].direction != turns[i - 1].direction)
        }
    }
}
