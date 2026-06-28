// SignalMath.swift
// ArcticEdge
//
// Pure numeric helpers for the carving score. Deterministic, no state,
// no platform dependencies, so they are fully unit testable. All inputs
// are plain Double arrays. See docs/CARVING-SCORE.md.

import Foundation

nonisolated enum SignalMath {

    // MARK: Basic statistics

    static func mean(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Population standard deviation.
    static func std(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let m = mean(xs)
        let variance = xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count)
        return variance.squareRoot()
    }

    static func rms(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.reduce(0) { $0 + $1 * $1 } / Double(xs.count)
        return s.squareRoot()
    }

    /// Coefficient of variation (std / |mean|). Zero when mean is ~0.
    static func coefficientOfVariation(_ xs: [Double]) -> Double {
        let m = mean(xs)
        guard abs(m) > 1e-12 else { return 0 }
        return std(xs) / abs(m)
    }

    /// Linear interpolated percentile. `p` in 0...1.
    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        if sorted.count == 1 { return sorted[0] }
        let clampedP = min(max(p, 0), 1)
        let rank = clampedP * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down))
        let hi = Int(rank.rounded(.up))
        let frac = rank - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    // MARK: Robust statistics

    /// Clamp values to the [lower, upper] percentile band (winsorizing).
    /// Count is preserved; extremes are pulled in, not dropped.
    static func winsorized(_ xs: [Double], lower: Double = 0.05, upper: Double = 0.95) -> [Double] {
        guard xs.count > 1 else { return xs }
        let lo = percentile(xs, lower)
        let hi = percentile(xs, upper)
        return xs.map { min(max($0, lo), hi) }
    }

    /// Mean after dropping `proportion` of the smallest and largest values.
    static func trimmedMean(_ xs: [Double], proportion: Double = 0.1) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        let k = Int((Double(sorted.count) * proportion).rounded(.down))
        guard k > 0, sorted.count - 2 * k > 0 else { return mean(sorted) }
        return mean(Array(sorted[k..<(sorted.count - k)]))
    }

    static func pearsonCorrelation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count > 1 else { return 0 }
        let ma = mean(a), mb = mean(b)
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<a.count {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        guard da > 0, db > 0 else { return 0 }
        return num / (da * db).squareRoot()
    }

    // MARK: Zero phase low pass (2nd order Butterworth, applied forward and back)

    /// Forward backward (filtfilt) low pass. Zero phase, so it does not
    /// shift feature timing. Effective order is doubled.
    static func lowPassZeroPhase(_ xs: [Double], sampleRate: Double, cutoff: Double) -> [Double] {
        guard xs.count > 6, sampleRate > 0, cutoff > 0, cutoff < sampleRate / 2 else { return xs }
        let (b, a) = butterworthLowPassCoefficients(sampleRate: sampleRate, cutoff: cutoff)
        let forward = applyBiquad(xs, b: b, a: a)
        let backward = applyBiquad(Array(forward.reversed()), b: b, a: a)
        return Array(backward.reversed())
    }

    /// RBJ cookbook 2nd order low pass coefficients, normalized so a0 = 1.
    private static func butterworthLowPassCoefficients(sampleRate: Double, cutoff: Double) -> (b: (Double, Double, Double), a: (Double, Double, Double)) {
        let w0 = 2.0 * Double.pi * cutoff / sampleRate
        let cosw = cos(w0)
        let sinw = sin(w0)
        let q = 1.0 / 2.0.squareRoot() // Butterworth
        let alpha = sinw / (2.0 * q)
        let a0 = 1.0 + alpha
        let b0 = (1.0 - cosw) / 2.0 / a0
        let b1 = (1.0 - cosw) / a0
        let b2 = (1.0 - cosw) / 2.0 / a0
        let a1 = (-2.0 * cosw) / a0
        let a2 = (1.0 - alpha) / a0
        return ((b0, b1, b2), (1.0, a1, a2))
    }

    private static func applyBiquad(_ x: [Double], b: (Double, Double, Double), a: (Double, Double, Double)) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let xn = x[i]
            let yn = b.0 * xn + b.1 * x1 + b.2 * x2 - a.1 * y1 - a.2 * y2
            y[i] = yn
            x2 = x1; x1 = xn
            y2 = y1; y1 = yn
        }
        return y
    }

    // MARK: Smoothness metrics

    /// Log dimensionless jerk on acceleration (LDLJ-A). Scale invariant
    /// smoothness from accelerometer data, avoiding velocity integration
    /// drift. Less negative means smoother. Mean is removed to cancel any
    /// residual gravity component.
    static func logDimensionlessJerk(acceleration: [Double], dt: Double) -> Double {
        guard acceleration.count > 3, dt > 0 else { return 0 }
        let m = mean(acceleration)
        let centered = acceleration.map { $0 - m }
        let peak = centered.map(abs).max() ?? 0
        guard peak > 1e-12 else { return 0 }
        var jerkSquaredIntegral = 0.0
        for i in 1..<centered.count {
            let jerk = (centered[i] - centered[i - 1]) / dt
            jerkSquaredIntegral += jerk * jerk * dt
        }
        let duration = Double(acceleration.count - 1) * dt
        let dimensionlessJerk = (duration / (peak * peak)) * jerkSquaredIntegral
        guard dimensionlessJerk > 0 else { return 0 }
        return -log(dimensionlessJerk)
    }

    /// Spectral arc length (SPARC). Smoothness of a movement profile from
    /// the arc length of its normalized magnitude spectrum up to `fc`.
    /// Less negative means smoother. Rotation invariant when applied to a
    /// speed or angular speed profile.
    static func sparc(_ movement: [Double], sampleRate: Double, fc: Double = 10.0, amplitudeThreshold: Double = 0.05) -> Double {
        let n = movement.count
        guard n >= 4, sampleRate > 0 else { return 0 }
        let basePower = Int(ceil(log2(Double(n))))
        let nfft = Int(pow(2.0, Double(basePower + 2))) // pad for resolution
        let mags = magnitudeSpectrum(movement, nfft: nfft)
        guard let maxMag = mags.max(), maxMag > 0 else { return 0 }
        let normalized = mags.map { $0 / maxMag }
        let df = sampleRate / Double(nfft)
        let fcIndex = min(Int(fc / df), normalized.count - 1)
        guard fcIndex >= 1 else { return 0 }
        let band = Array(normalized[0...fcIndex])
        guard let first = band.firstIndex(where: { $0 >= amplitudeThreshold }),
              let last = band.lastIndex(where: { $0 >= amplitudeThreshold }),
              last > first else { return 0 }
        let selected = Array(band[first...last])
        let fRange = Double(last - first) * df
        guard fRange > 0 else { return 0 }
        var arcLength = 0.0
        let dfNormalized = df / fRange
        for i in 1..<selected.count {
            let dMag = selected[i] - selected[i - 1]
            arcLength += (dfNormalized * dfNormalized + dMag * dMag).squareRoot()
        }
        return -arcLength
    }

    /// Naive single sided magnitude spectrum (DFT) for bins 0...nfft/2.
    /// Adequate for the short windows used here; no Accelerate dependency.
    private static func magnitudeSpectrum(_ x: [Double], nfft: Int) -> [Double] {
        let n = x.count
        let halfBins = nfft / 2
        var mags = [Double](repeating: 0, count: halfBins + 1)
        for k in 0...halfBins {
            var re = 0.0, im = 0.0
            let w = -2.0 * Double.pi * Double(k) / Double(nfft)
            for i in 0..<n {
                let angle = w * Double(i)
                re += x[i] * cos(angle)
                im += x[i] * sin(angle)
            }
            mags[k] = (re * re + im * im).squareRoot()
        }
        return mags
    }

    // MARK: Resampling

    /// Linear resample onto a uniform grid from the first to the last
    /// timestamp at `sampleRate`. Used to put irregularly sampled frames
    /// (rate throttles under thermal or power saver pressure) on a fixed grid.
    static func resampleUniform(timestamps: [Double], values: [Double], sampleRate: Double) -> [Double] {
        guard timestamps.count == values.count, timestamps.count >= 2, sampleRate > 0 else { return values }
        let t0 = timestamps.first!
        let tEnd = timestamps.last!
        let duration = tEnd - t0
        guard duration > 0 else { return values }
        let n = Int((duration * sampleRate).rounded(.down)) + 1
        var out = [Double]()
        out.reserveCapacity(n)
        var j = 0
        for i in 0..<n {
            let t = t0 + Double(i) / sampleRate
            while j < timestamps.count - 2 && timestamps[j + 1] < t { j += 1 }
            let t1 = timestamps[j], t2 = timestamps[j + 1]
            let frac = t2 > t1 ? (t - t1) / (t2 - t1) : 0
            out.append(values[j] + (values[j + 1] - values[j]) * min(max(frac, 0), 1))
        }
        return out
    }
}
