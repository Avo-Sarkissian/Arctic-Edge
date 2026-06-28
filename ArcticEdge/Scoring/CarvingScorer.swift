// CarvingScorer.swift
// ArcticEdge
//
// Computes the 0...100 carving score for one run from its motion frames.
// Pipeline: resample to a uniform grid, gravity project, segment turns,
// compute per pillar sub metrics, normalize against the frozen model
// anchors, and aggregate with a geometric mean across pillars (which
// limits gaming by maxing a single dimension). See docs/CARVING-SCORE.md.

import Foundation

nonisolated enum CarvingScorer {

    static func score(frames: [ScoringFrame], model: CarvingScoreModel = .v1) -> CarvingScore {
        let fs = model.analysisSampleRate

        // Basic data quality, independent of whether we can score.
        let duration = (frames.last?.timestamp ?? 0) - (frames.first?.timestamp ?? 0)
        let medianRate = medianSampleRate(frames)
        let gpsCoverage = frames.isEmpty ? 0 : Double(frames.filter { $0.gpsSpeed != nil }.count) / Double(frames.count)

        let turns = TurnSegmenter().detectTurns(frames, sampleRate: fs)

        // Minimum data gate: refuse to invent a number from too little signal.
        guard frames.count > 10,
              duration >= model.minDurationSeconds,
              turns.count >= model.minTurns else {
            let quality = DataQuality(
                turnCount: turns.count,
                durationSeconds: max(0, duration),
                medianSampleRate: medianRate,
                gpsCoverage: gpsCoverage,
                sufficientData: false
            )
            return .insufficient(version: model.version, quality: quality)
        }

        // Uniform grid channels, aligned with the turn indices (same frames,
        // same rate, same resampler as the segmenter).
        let timestamps = frames.map { $0.timestamp }
        let vertical = SignalMath.resampleUniform(timestamps: timestamps, values: frames.map { $0.verticalAccel }, sampleRate: fs)
        let horizontal = SignalMath.resampleUniform(timestamps: timestamps, values: frames.map { $0.horizontalAccelMagnitude }, sampleRate: fs)
        let angularSpeed = SignalMath.resampleUniform(timestamps: timestamps, values: frames.map { $0.angularSpeed }, sampleRate: fs)
        let yaw = SignalMath.resampleUniform(timestamps: timestamps, values: frames.map { $0.yawRateAboutVertical }, sampleRate: fs)
        let speed = SignalMath.resampleUniform(timestamps: timestamps, values: carryForwardSpeed(frames), sampleRate: fs)

        let gridCount = min(vertical.count, min(horizontal.count, min(angularSpeed.count, min(yaw.count, speed.count))))
        let span = turnSpan(turns, gridCount: gridCount)

        // Pillar A: Control and Smoothness (no GPS).
        let edgeSmoothRaw = SignalMath.sparc(slice(angularSpeed, span), sampleRate: fs)
        let linkageRaw = SignalMath.logDimensionlessJerk(acceleration: slice(horizontal, span), dt: 1.0 / fs)
        let chatterRaw = chatterEnergy(slice(vertical, span), sampleRate: fs, cutoff: model.chatterCutoffHz)

        // Pillar B: Rhythm and Symmetry (no GPS).
        let cadenceRaw = SignalMath.coefficientOfVariation(turns.map { $0.duration })
        let symmetryRaw = symmetryIndex(turns, horizontal: horizontal)

        var subMetrics: [SubMetricValue] = [
            sub(.edgeTransitionSmoothness, edgeSmoothRaw, model),
            sub(.linkageSmoothness, linkageRaw, model),
            sub(.chatter, chatterRaw, model),
            sub(.cadenceRegularity, cadenceRaw, model),
            sub(.symmetry, symmetryRaw, model)
        ]

        let control01 = SignalMath.mean([
            model.anchor(.edgeTransitionSmoothness).normalize(edgeSmoothRaw),
            model.anchor(.linkageSmoothness).normalize(linkageRaw),
            model.anchor(.chatter).normalize(chatterRaw)
        ])
        let rhythm01 = SignalMath.mean([
            model.anchor(.cadenceRegularity).normalize(cadenceRaw),
            model.anchor(.symmetry).normalize(symmetryRaw)
        ])

        // Pillar C: Carving Intensity (GPS gated, quarantined).
        var intensity01: Double? = nil
        if gpsCoverage >= model.minGPSCoverage {
            let purityRaw = carvePurity(turns, horizontal: horizontal, yaw: yaw, speed: speed)
            let shapeRaw = turnShapeConsistency(turns, yaw: yaw, speed: speed)
            if let purityRaw, let shapeRaw {
                subMetrics.append(sub(.carvePurity, purityRaw, model))
                subMetrics.append(sub(.turnShapeConsistency, shapeRaw, model))
                intensity01 = SignalMath.mean([
                    model.anchor(.carvePurity).normalize(purityRaw),
                    model.anchor(.turnShapeConsistency).normalize(shapeRaw)
                ])
            }
        }

        // Geometric mean across available pillars limits compensability.
        var pillarPairs: [(weight: Double, value: Double)] = [
            (model.weightControl, control01),
            (model.weightRhythm, rhythm01)
        ]
        if let intensity01 {
            pillarPairs.append((model.weightIntensity, intensity01))
        }
        let overall = geometricMean(pillarPairs) * 100

        let quality = DataQuality(
            turnCount: turns.count,
            durationSeconds: duration,
            medianSampleRate: medianRate,
            gpsCoverage: gpsCoverage,
            sufficientData: true
        )

        return CarvingScore(
            overall: min(max(overall, 0), 100),
            pillars: PillarScores(
                controlSmoothness: control01 * 100,
                rhythmSymmetry: rhythm01 * 100,
                carvingIntensity: intensity01.map { $0 * 100 }
            ),
            subMetrics: subMetrics,
            turnCount: turns.count,
            dataQuality: quality,
            modelVersion: model.version
        )
    }

    // MARK: Sub metric helpers

    private static func sub(_ id: SubMetricID, _ raw: Double, _ model: CarvingScoreModel) -> SubMetricValue {
        SubMetricValue(id: id.rawValue, label: id.label, normalized: model.anchor(id).normalize(raw) * 100, raw: raw)
    }

    /// High frequency energy above `cutoff`, as RMS of the high pass
    /// residual (signal minus its low pass). High means edge chatter.
    private static func chatterEnergy(_ xs: [Double], sampleRate: Double, cutoff: Double) -> Double {
        guard xs.count > 6 else { return 0 }
        let low = SignalMath.lowPassZeroPhase(xs, sampleRate: sampleRate, cutoff: cutoff)
        let high = zip(xs, low).map { $0 - $1 }
        return SignalMath.rms(high)
    }

    /// Balance of left vs right turns in peak load and duration. 1 is
    /// perfectly symmetric. Single pocket IMU can do left/right TURN
    /// symmetry (not per ski symmetry).
    private static func symmetryIndex(_ turns: [Turn], horizontal: [Double]) -> Double {
        func peakLoad(_ turn: Turn) -> Double {
            slice(horizontal, (turn.startIndex, min(turn.endIndex, horizontal.count))).max() ?? 0
        }
        let left = turns.filter { $0.direction == .left }
        let right = turns.filter { $0.direction == .right }
        guard !left.isEmpty, !right.isEmpty else { return 0.5 }
        let loadSym = balance(SignalMath.mean(left.map(peakLoad)), SignalMath.mean(right.map(peakLoad)))
        let durSym = balance(SignalMath.mean(left.map { $0.duration }), SignalMath.mean(right.map { $0.duration }))
        return (loadSym + durSym) / 2
    }

    private static func balance(_ a: Double, _ b: Double) -> Double {
        let sum = a + b
        guard sum > 1e-9 else { return 1 }
        return 1 - abs(a - b) / sum
    }

    /// Agreement between measured horizontal load and the centripetal
    /// estimate v * yawRate. High agreement is a clean carve; divergence
    /// is skidding. Needs GPS speed.
    private static func carvePurity(_ turns: [Turn], horizontal: [Double], yaw: [Double], speed: [Double]) -> Double? {
        var correlations: [Double] = []
        for turn in turns {
            let s = turn.startIndex
            let e = min(turn.endIndex, min(horizontal.count, min(yaw.count, speed.count)))
            guard e - s >= 3 else { continue }
            let measured = Array(horizontal[s..<e])
            let centripetal = (s..<e).map { abs(speed[$0] * yaw[$0]) }
            correlations.append(max(0, SignalMath.pearsonCorrelation(measured, centripetal)))
        }
        guard correlations.count >= 2 else { return nil }
        return SignalMath.mean(correlations)
    }

    /// Consistency of per turn radius (v / yawRate). Lower variation is a
    /// more controlled, repeatable arc. Needs GPS speed.
    private static func turnShapeConsistency(_ turns: [Turn], yaw: [Double], speed: [Double]) -> Double? {
        var radii: [Double] = []
        for turn in turns {
            let s = turn.startIndex
            let e = min(turn.endIndex, min(yaw.count, speed.count))
            guard e - s >= 3 else { continue }
            let meanSpeed = SignalMath.mean(Array(speed[s..<e]))
            let meanAbsYaw = SignalMath.mean((s..<e).map { abs(yaw[$0]) })
            guard meanAbsYaw > 1e-3 else { continue }
            radii.append(meanSpeed / meanAbsYaw)
        }
        guard radii.count >= 2 else { return nil }
        return SignalMath.coefficientOfVariation(SignalMath.winsorized(radii))
    }

    // MARK: Plumbing

    private static func medianSampleRate(_ frames: [ScoringFrame]) -> Double {
        guard frames.count >= 2 else { return 0 }
        var deltas: [Double] = []
        for i in 1..<frames.count {
            let dt = frames[i].timestamp - frames[i - 1].timestamp
            if dt > 0 { deltas.append(dt) }
        }
        guard !deltas.isEmpty else { return 0 }
        let medianDt = SignalMath.percentile(deltas, 0.5)
        return medianDt > 0 ? 1.0 / medianDt : 0
    }

    /// Carry the last known GPS speed forward so the speed channel can be
    /// resampled onto the analysis grid. Coverage is tracked separately to
    /// decide whether the GPS dependent pillar is trustworthy.
    private static func carryForwardSpeed(_ frames: [ScoringFrame]) -> [Double] {
        var out = [Double]()
        out.reserveCapacity(frames.count)
        var last = 0.0
        for f in frames {
            if let s = f.gpsSpeed { last = s }
            out.append(last)
        }
        return out
    }

    private static func turnSpan(_ turns: [Turn], gridCount: Int) -> (Int, Int) {
        let start = max(0, turns.first?.startIndex ?? 0)
        let end = min(gridCount, turns.last?.endIndex ?? gridCount)
        return (start, max(start, end))
    }

    private static func slice(_ xs: [Double], _ span: (Int, Int)) -> [Double] {
        let lo = min(max(span.0, 0), xs.count)
        let hi = min(max(span.1, lo), xs.count)
        return Array(xs[lo..<hi])
    }

    /// Weighted geometric mean of pillar scores in 0...1. A floor avoids
    /// log(0); a single weak pillar still drags the product down, which is
    /// the intended anti gaming behavior.
    private static func geometricMean(_ pairs: [(weight: Double, value: Double)]) -> Double {
        var weightSum = 0.0
        var logSum = 0.0
        for pair in pairs {
            let v = max(pair.value, 0.001)
            logSum += pair.weight * log(v)
            weightSum += pair.weight
        }
        guard weightSum > 0 else { return 0 }
        return exp(logSum / weightSum)
    }
}
