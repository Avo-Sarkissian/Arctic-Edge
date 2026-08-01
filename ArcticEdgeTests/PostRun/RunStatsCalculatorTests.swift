// RunStatsCalculatorTests.swift
// ArcticEdgeTests/PostRun
//
// The statistics a skier reads and compares. Each test pins one honesty
// property: bad fixes are rejected, unmeasured values stay nil, and no metric
// is invented from a signal that cannot support it.

import Testing
import Foundation
@testable import ArcticEdge

@Suite("RunStatsCalculator")
struct RunStatsCalculatorTests {

    private func frame(
        _ t: Double,
        speed: Double? = nil,
        horizontal: Double? = 5,
        speedAccuracy: Double? = 1,
        altitude: Double? = nil
    ) -> StatsFrame {
        StatsFrame(
            timestamp: t,
            gpsSpeed: speed,
            gpsHorizontalAccuracy: horizontal,
            gpsSpeedAccuracy: speedAccuracy,
            relativeAltitude: altitude
        )
    }

    // MARK: - Speed gating

    @Test("a single bad fix does not become the run's top speed")
    func testOutlierFixIsRejected() {
        // A 90 m accuracy fix reporting 40 m/s is the classic tree-cover glitch
        // that used to survive straight to the TOP SPEED card.
        var frames = (0..<20).map { frame(Double($0), speed: 12) }
        frames.append(frame(20, speed: 40, horizontal: 90))

        let stats = RunStatsCalculator.computeStats(from: frames)
        let top = try! #require(stats.topSpeed)
        #expect(top < 15, "the inaccurate 40 m/s sample must not set top speed, got \(top)")
    }

    @Test("physically implausible speeds are rejected even with a good accuracy claim")
    func testImplausibleSpeedRejected() {
        var frames = (0..<20).map { frame(Double($0), speed: 12) }
        frames.append(frame(20, speed: 120, horizontal: 3, speedAccuracy: 0.5))

        let stats = RunStatsCalculator.computeStats(from: frames)
        let top = try! #require(stats.topSpeed)
        #expect(top < 15, "432 km/h is not a ski run")
    }

    @Test("poor speed accuracy disqualifies a sample")
    func testPoorSpeedAccuracyRejected() {
        let good = frame(0, speed: 10, speedAccuracy: 0.5)
        let bad = frame(1, speed: 30, speedAccuracy: 9)
        #expect(good.usableSpeed == 10)
        #expect(bad.usableSpeed == nil)
    }

    @Test("a missing accuracy value does not disqualify an otherwise good sample")
    func testMissingAccuracyIsAccepted() {
        // Pre-migration frames carry no accuracy. Discarding them would erase
        // every run recorded before accuracy capture existed.
        let legacy = StatsFrame(timestamp: 0, gpsSpeed: 14)
        #expect(legacy.usableSpeed == 14)
    }

    @Test("top speed uses a high percentile, not the raw maximum")
    func testTopSpeedIsPercentile() {
        let speeds: [Double] = [5, 10, 12, 14, 15, 16, 18, 20, 22, 40]
        let frames = speeds.enumerated().map { frame(Double($0.offset), speed: $0.element) }
        let stats = RunStatsCalculator.computeStats(from: frames)
        let top = try! #require(stats.topSpeed)
        #expect(top < 40, "max() would return 40; the percentile must damp the outlier")
        #expect(top > 20, "but it should still sit near the fast end, got \(top)")
    }

    @Test("too few usable samples yields no speed stats at all")
    func testMinimumSampleGate() {
        let frames = (0..<3).map { frame(Double($0), speed: 10) }
        let stats = RunStatsCalculator.computeStats(from: frames)
        #expect(stats.topSpeed == nil)
        #expect(stats.avgSpeed == nil)
        #expect(stats.distanceMeters == nil)
    }

    // MARK: - Average speed

    @Test("average speed is distance over moving time, excluding standing still")
    func testAverageExcludesStationaryTime() {
        // Ten seconds at 20 m/s then ten stopped. A frame-count-weighted mean
        // would report 10 m/s; moving average should stay at 20.
        var frames: [StatsFrame] = []
        for i in 0..<10 { frames.append(frame(Double(i) * 0.1, speed: 20)) }
        for i in 10..<20 { frames.append(frame(Double(i) * 0.1, speed: 0)) }

        let avg = try! #require(RunStatsCalculator.movingAverageSpeed(frames: frames))
        #expect(abs(avg - 20) < 0.5, "expected ~20 m/s moving average, got \(avg)")
    }

    @Test("gaps in capture do not inflate distance")
    func testCaptureGapIsSkipped() {
        // A 30 s suspension between two frames must not integrate as 30 s of travel.
        let frames = [frame(0, speed: 20), frame(30, speed: 20), frame(30.1, speed: 20)]
        let distance = RunStatsCalculator.integratedDistance(frames: frames)
        if let distance {
            #expect(distance < 10, "the 30 s gap must be skipped, got \(distance) m")
        }
    }

    // MARK: - Vertical

    @Test("vertical drop is nil without barometer data")
    func testVerticalNilWithoutAltitude() {
        // There is no honest way to derive descent from a pocket phone's attitude,
        // so with no barometer the answer is "unknown", not a number.
        let frames = (0..<20).map { frame(Double($0), speed: 15) }
        let stats = RunStatsCalculator.computeStats(from: frames)
        #expect(stats.verticalDrop == nil)
    }

    @Test("vertical drop sums barometric descent only")
    func testBarometricDescent() {
        // Down 100 m, then up 20 m on a lift. Only the descent counts.
        var frames: [StatsFrame] = []
        for i in 0...100 { frames.append(frame(Double(i), altitude: -Double(i))) }
        for i in 1...20 { frames.append(frame(Double(100 + i), altitude: -100 + Double(i))) }

        let descent = try! #require(RunStatsCalculator.barometricDescent(frames: frames))
        #expect(abs(descent - 100) < 1.0, "expected ~100 m of descent, got \(descent)")
    }

    @Test("barometer jitter does not accumulate into invented vertical")
    func testJitterIsIgnored() {
        // A stationary phone whose barometer wobbles by centimetres must report
        // no descent, not thousands of summed noise samples.
        let jitter: [Double] = (0..<500).map { i in (i % 2 == 0) ? 0.02 : -0.02 }
        let frames = jitter.enumerated().map { frame(Double($0.offset), altitude: $0.element) }

        let descent = try! #require(RunStatsCalculator.barometricDescent(frames: frames))
        #expect(descent == 0, "sub-decimetre wobble must not integrate, got \(descent)")
    }

    // MARK: - Percentile helper

    @Test("percentile interpolates between samples")
    func testPercentileMath() {
        let values: [Double] = [0, 10, 20, 30, 40]
        #expect(RunStatsCalculator.percentile(values, 0.0) == 0)
        #expect(RunStatsCalculator.percentile(values, 1.0) == 40)
        #expect(RunStatsCalculator.percentile(values, 0.5) == 20)
        #expect(RunStatsCalculator.percentile([], 0.95) == nil)
    }
}
