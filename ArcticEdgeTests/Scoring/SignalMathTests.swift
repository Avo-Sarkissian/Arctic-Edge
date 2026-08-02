// SignalMathTests.swift
// ArcticEdge
//
// Spec for the pure numeric helpers behind the carving score.
// All functions are deterministic and operate on plain arrays so they
// can be exercised without any simulator state.

import Testing
import Foundation
@testable import ArcticEdge

struct SignalMathTests {

    // MARK: Basic statistics

    @Test func meanAndStdOfKnownSample() {
        let xs = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0]
        #expect(abs(SignalMath.mean(xs) - 5.0) < 1e-9)
        // Population standard deviation of this classic sample is 2.0.
        #expect(abs(SignalMath.std(xs) - 2.0) < 1e-9)
    }

    @Test func meanOfEmptyIsZero() {
        #expect(SignalMath.mean([]) == 0)
        #expect(SignalMath.std([]) == 0)
    }

    @Test func percentileInterpolates() {
        let xs = Array(stride(from: 0.0, through: 100.0, by: 1.0)) // 0...100
        #expect(abs(SignalMath.percentile(xs, 0.5) - 50.0) < 1.0)
        #expect(SignalMath.percentile(xs, 0.0) == 0.0)
        #expect(SignalMath.percentile(xs, 1.0) == 100.0)
    }

    @Test func coefficientOfVariation() {
        let xs = [10.0, 10.0, 10.0, 10.0]
        #expect(SignalMath.coefficientOfVariation(xs) == 0) // no spread
        let spread = [8.0, 10.0, 12.0]
        #expect(SignalMath.coefficientOfVariation(spread) > 0)
    }

    @Test func rmsOfConstant() {
        #expect(abs(SignalMath.rms([3.0, 3.0, 3.0]) - 3.0) < 1e-9)
    }

    // MARK: Robust statistics

    @Test func winsorizeClampsOutliers() {
        var xs = Array(stride(from: 1.0, through: 100.0, by: 1.0))
        xs.append(100_000.0) // a single wild spike (e.g. a pocket jolt)
        let w = SignalMath.winsorized(xs, lower: 0.05, upper: 0.95)
        // The spike must be pulled down to the upper band, not left huge.
        #expect((w.max() ?? .infinity) < 1000.0)
        // Count is preserved (winsorizing clamps, does not drop).
        #expect(w.count == xs.count)
    }

    @Test func trimmedMeanIgnoresExtremes() {
        // Two hero turns and two disasters should not move the center much.
        let xs = [0.0, 0.0, 5.0, 5.0, 5.0, 5.0, 5.0, 5.0, 100.0, 100.0]
        let trimmed = SignalMath.trimmedMean(xs, proportion: 0.2)
        #expect(abs(trimmed - 5.0) < 0.5)
    }

    // MARK: Zero phase low pass filter

    @Test func lowPassPreservesSlowAndRejectsFast() {
        let fs = 200.0
        let n = 1000
        let slow = (0..<n).map { sin(2 * .pi * 1.0 * Double($0) / fs) }   // 1 Hz
        let fast = (0..<n).map { sin(2 * .pi * 40.0 * Double($0) / fs) }  // 40 Hz
        let mixed = zip(slow, fast).map { $0 + $1 }
        let filtered = SignalMath.lowPassZeroPhase(mixed, sampleRate: fs, cutoff: 5.0)

        // Compare on the interior to avoid edge transients.
        let interior = 100..<(n - 100)
        let errVsSlow = SignalMath.rms(interior.map { filtered[$0] - slow[$0] })
        // The 40 Hz component (amplitude 1.0) must be largely removed.
        #expect(errVsSlow < 0.2)
    }

    @Test func lowPassIsApproximatelyZeroPhase() {
        // A single Gaussian pulse has one unambiguous peak, so any lag a
        // non zero phase filter introduces is directly measurable.
        let fs = 100.0
        let n = 400
        let pulse = (0..<n).map { i -> Double in exp(-pow((Double(i) - 200.0) / 25.0, 2)) }
        let filtered = SignalMath.lowPassZeroPhase(pulse, sampleRate: fs, cutoff: 10.0)
        let inPeak = (0..<n).max(by: { pulse[$0] < pulse[$1] })!
        let outPeak = (0..<n).max(by: { filtered[$0] < filtered[$1] })!
        #expect(abs(inPeak - outPeak) <= 2) // zero phase: no lag shift
    }

    // MARK: Smoothness metrics (ordering is what matters, not absolute value)

    @Test func sparcRatesSmoothMovementHigherThanJerky() {
        let fs = 100.0
        let n = 300
        // A single smooth bell shaped speed profile.
        let smooth = (0..<n).map { i -> Double in
            let t = Double(i) / Double(n)
            return exp(-pow((t - 0.5) * 6, 2))
        }
        // The same profile contaminated with in band wobble (SPARC focuses
        // on the movement band up to ~10 Hz; higher frequency chatter is
        // scored separately by the chatter penalty).
        let jerky = smooth.enumerated().map { i, v in
            v + 0.2 * sin(2 * .pi * 7.0 * Double(i) / fs)
        }
        let smoothScore = SignalMath.sparc(smooth, sampleRate: fs)
        let jerkyScore = SignalMath.sparc(jerky, sampleRate: fs)
        // SPARC is negative; smoother movement is closer to zero (larger).
        #expect(smoothScore > jerkyScore)
    }

    @Test func ldljRatesSmoothAccelHigherThanJerky() {
        let dt = 0.01
        let n = 300
        let smooth = (0..<n).map { sin(2 * .pi * 1.0 * Double($0) * dt) }
        let jerky = smooth.enumerated().map { i, v in
            v + 0.3 * sin(2 * .pi * 30.0 * Double(i) * dt)
        }
        let smoothLdlj = SignalMath.logDimensionlessJerk(acceleration: smooth, dt: dt)
        let jerkyLdlj = SignalMath.logDimensionlessJerk(acceleration: jerky, dt: dt)
        // Less negative means smoother.
        #expect(smoothLdlj > jerkyLdlj)
    }

    // MARK: Resampling

    @Test func resampleToUniformGridProducesExpectedCount() {
        // 2 seconds of data sampled irregularly.
        let timestamps = stride(from: 0.0, through: 2.0, by: 0.013).map { $0 }
        let values = timestamps.map { sin(2 * .pi * 1.0 * $0) }
        let out = SignalMath.resampleUniform(timestamps: timestamps, values: values, sampleRate: 50.0)
        // 2 seconds at 50 Hz is about 100 samples.
        #expect(out.count >= 95 && out.count <= 101)
    }
}
