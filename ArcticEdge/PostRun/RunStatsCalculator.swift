// RunStatsCalculator.swift
// ArcticEdge
//
// Pure, Sendable computation of per-run statistics from persisted frames.
//
// This was previously inline in PostRunViewModel, which meant stats existed only
// while a post-run sheet was open and were never written to the RunRecord. It is
// extracted here so run finalization can compute them for every run, and so the
// arithmetic is testable without a SwiftData container.
//
// Honesty rules applied here:
// - Every stat is Optional. nil means "we could not measure this", which the UI
//   renders as a dash. A fabricated zero would read as a real measurement.
// - Speed samples are rejected unless the fix they came from was accurate enough.
//   topSpeed used to be a raw max() over unfiltered GPS, so one bad fix in trees
//   became the run's advertised top speed.
// - Vertical drop comes only from barometric altitude. There is no honest way to
//   derive descent from a pocket phone's attitude, so with no barometer data the
//   answer is nil rather than a guess.

import Foundation

// MARK: - RunStats

/// Per-run statistics. Every measurement is Optional: nil means the run did not
/// carry enough trustworthy data to report it, and the UI shows a dash. Defaulting
/// to 0 would present "no data" as "zero metres", which is a different claim.
nonisolated struct RunStats: Sendable, Equatable {
    var topSpeed: Double?        // m/s, 95th percentile of accuracy-gated samples
    var avgSpeed: Double?        // m/s, distance over moving time
    var verticalDrop: Double?    // meters, barometric descent only
    var distanceMeters: Double?  // meters, integrated from gated speed
    var duration: TimeInterval = 0

    init(
        topSpeed: Double? = nil,
        avgSpeed: Double? = nil,
        verticalDrop: Double? = nil,
        distanceMeters: Double? = nil,
        duration: TimeInterval = 0
    ) {
        self.topSpeed = topSpeed
        self.avgSpeed = avgSpeed
        self.verticalDrop = verticalDrop
        self.distanceMeters = distanceMeters
        self.duration = duration
    }
}

// MARK: - StatsFrame

/// The subset of a persisted frame that statistics need. Sendable so the
/// calculation can run off the main actor.
nonisolated struct StatsFrame: Sendable {
    let timestamp: TimeInterval          // CMDeviceMotion uptime
    let gpsSpeed: Double?
    let gpsHorizontalAccuracy: Double?
    let gpsSpeedAccuracy: Double?
    let relativeAltitude: Double?

    init(
        timestamp: TimeInterval,
        gpsSpeed: Double? = nil,
        gpsHorizontalAccuracy: Double? = nil,
        gpsSpeedAccuracy: Double? = nil,
        relativeAltitude: Double? = nil
    ) {
        self.timestamp = timestamp
        self.gpsSpeed = gpsSpeed
        self.gpsHorizontalAccuracy = gpsHorizontalAccuracy
        self.gpsSpeedAccuracy = gpsSpeedAccuracy
        self.relativeAltitude = relativeAltitude
    }

    /// A speed sample is usable only when the underlying fix was good enough.
    /// A missing accuracy value is treated as unknown-but-acceptable: older data
    /// predates accuracy capture, and discarding it would erase whole seasons.
    var usableSpeed: Double? {
        guard let speed = gpsSpeed, speed >= 0 else { return nil }
        if let horizontal = gpsHorizontalAccuracy, horizontal < 0 || horizontal > 25 { return nil }
        if let speedAccuracy = gpsSpeedAccuracy, speedAccuracy >= 0, speedAccuracy > 3 { return nil }
        // Physical plausibility: 45 m/s is 162 km/h, beyond any recreational run.
        guard speed <= 45 else { return nil }
        return speed
    }
}

// MARK: - RunStatsCalculator

nonisolated enum RunStatsCalculator {

    /// Minimum number of usable speed samples before speed stats are reported.
    /// A run with two good fixes cannot honestly claim an average speed.
    static let minimumSpeedSamples = 5

    static func computeStats(from frames: [StatsFrame]) -> RunStats {
        var stats = RunStats()
        let speeds = frames.compactMap { $0.usableSpeed }

        if speeds.count >= minimumSpeedSamples {
            // 95th percentile rather than max(): max is maximally sensitive to the
            // single worst outlier, which is the metric skiers screenshot.
            stats.topSpeed = percentile(speeds, 0.95)
            stats.avgSpeed = movingAverageSpeed(frames: frames)
            stats.distanceMeters = integratedDistance(frames: frames)
        }

        stats.verticalDrop = barometricDescent(frames: frames)
        return stats
    }

    // MARK: - Speed

    /// Linear-interpolated percentile of a sample set.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    /// Distance-weighted mean speed over moving time, not a frame-count-weighted
    /// mean of instantaneous samples. Frames arrive at 100 Hz while GPS updates at
    /// about 1 Hz, so a plain mean over frames weights each fix by how many frames
    /// happened to share it rather than by how long it applied.
    static func movingAverageSpeed(frames: [StatsFrame]) -> Double? {
        var distance = 0.0
        var movingTime = 0.0
        for (a, b) in zip(frames, frames.dropFirst()) {
            let dt = b.timestamp - a.timestamp
            guard dt > 0, dt < 1.0 else { continue }   // skip gaps in capture
            guard let speed = a.usableSpeed, speed > 0.5 else { continue }  // exclude standing still
            distance += speed * dt
            movingTime += dt
        }
        guard movingTime > 0 else { return nil }
        return distance / movingTime
    }

    /// Along-slope distance from gated speed integrated over frame intervals.
    static func integratedDistance(frames: [StatsFrame]) -> Double? {
        var distance = 0.0
        var contributed = false
        for (a, b) in zip(frames, frames.dropFirst()) {
            let dt = b.timestamp - a.timestamp
            guard dt > 0, dt < 1.0 else { continue }
            guard let speed = a.usableSpeed else { continue }
            distance += speed * dt
            contributed = true
        }
        return contributed ? distance : nil
    }

    // MARK: - Vertical

    /// Sum of downward barometric altitude changes across the run.
    ///
    /// Only descent counts: a chairlift segment bleeding into the tail of a run
    /// should not cancel out real vertical, and a traverse should not add any.
    /// Returns nil when the run carries no barometer data, which is the honest
    /// answer for a device without one.
    static func barometricDescent(frames: [StatsFrame]) -> Double? {
        let altitudes = frames.compactMap { $0.relativeAltitude }
        guard altitudes.count >= 2 else { return nil }
        var descent = 0.0
        for (a, b) in zip(altitudes, altitudes.dropFirst()) {
            let delta = b - a
            // Ignore sub-decimeter jitter: the sensor resolves about 0.1 m and
            // summing noise across thousands of frames would invent vertical.
            if delta < -0.1 { descent += -delta }
        }
        return descent
    }
}
