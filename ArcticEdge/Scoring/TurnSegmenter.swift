// TurnSegmenter.swift
// ArcticEdge
//
// Segments a run into individual turns from the gravity referenced yaw
// rate. Turns are the foundation of every per turn sub metric, so the
// detector is deliberately conservative: it low passes the yaw rate,
// finds edge change zero crossings, and gates by duration and peak
// magnitude so terrain chatter and straight running do not create turns.
// See docs/CARVING-SCORE.md.

import Foundation

nonisolated enum TurnDirection: Sendable, Equatable {
    case left
    case right
}

nonisolated struct Turn: Sendable, Equatable {
    let startIndex: Int        // index into the uniform analysis grid
    let endIndex: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let direction: TurnDirection

    var duration: TimeInterval { endTime - startTime }
}

nonisolated struct TurnSegmenter {
    /// Edge changes are slow (turns last ~1 to 3 s), so the decision
    /// signal is heavily low passed.
    var cutoffHz: Double = 0.6
    var minDuration: TimeInterval = 0.3
    var maxDuration: TimeInterval = 5.0
    /// Reject candidate turns whose peak yaw rate is below this, so
    /// straight running and small jitters are not counted.
    var minPeakYawRate: Double = 0.15 // rad/s

    /// Detect turns. `sampleRate` is the uniform analysis grid rate; the
    /// returned indices index into that grid (built from the same frames
    /// and rate via SignalMath.resampleUniform, so they align with the
    /// scorer's other resampled channels).
    func detectTurns(_ frames: [ScoringFrame], sampleRate: Double) -> [Turn] {
        guard frames.count > 10, sampleRate > 0 else { return [] }
        let timestamps = frames.map { $0.timestamp }
        let yawRaw = frames.map { $0.yawRateAboutVertical }
        let yawGrid = SignalMath.resampleUniform(timestamps: timestamps, values: yawRaw, sampleRate: sampleRate)
        guard yawGrid.count > 10 else { return [] }
        let yaw = SignalMath.lowPassZeroPhase(yawGrid, sampleRate: sampleRate, cutoff: cutoffHz)
        let t0 = timestamps.first!

        // Edge changes are sign changes of the low passed yaw rate.
        var crossings: [Int] = []
        for i in 1..<yaw.count {
            let prev = yaw[i - 1], curr = yaw[i]
            if (prev <= 0 && curr > 0) || (prev >= 0 && curr < 0) {
                crossings.append(i)
            }
        }
        guard crossings.count >= 2 else { return [] }

        var turns: [Turn] = []
        for k in 1..<crossings.count {
            let s = crossings[k - 1]
            let e = crossings[k]
            let duration = Double(e - s) / sampleRate
            guard duration >= minDuration, duration <= maxDuration else { continue }
            let segment = Array(yaw[s..<e])
            let peak = segment.map(abs).max() ?? 0
            guard peak >= minPeakYawRate else { continue }
            let direction: TurnDirection = SignalMath.mean(segment) >= 0 ? .left : .right
            turns.append(Turn(
                startIndex: s,
                endIndex: e,
                startTime: t0 + Double(s) / sampleRate,
                endTime: t0 + Double(e) / sampleRate,
                direction: direction
            ))
        }
        return turns
    }
}
