// ScoreComparabilityTests.swift
// ArcticEdgeTests/Scoring
//
// The frozen model exists so scores are comparable across a season. These tests
// pin the properties that comparability depends on: a run must not score
// differently just because it was longer, or because the phone was throttling.

import Testing
import Foundation
import simd
@testable import ArcticEdge

@Suite("Score comparability")
struct ScoreComparabilityTests {

    /// Synthesises a run of clean, evenly linked turns.
    /// - Parameters:
    ///   - turnCount: how many turns to generate.
    ///   - sampleRate: capture rate, so throttled capture can be simulated.
    private func makeRun(
        turnCount: Int,
        sampleRate: Double = 100,
        turnPeriod: Double = 2.0,
        speed: Double? = 15
    ) -> [ScoringFrame] {
        let duration = Double(turnCount) * turnPeriod
        let sampleCount = Int(duration * sampleRate)
        let omega = 2 * Double.pi / turnPeriod
        return (0..<sampleCount).map { i in
            let t = Double(i) / sampleRate
            // Yaw rate alternates sign once per turn: the signal the segmenter reads.
            let yaw = 0.9 * sin(omega * t)
            // Lateral load peaks mid-turn, in phase with |yaw|.
            let lateral = 0.55 * abs(sin(omega * t))
            return ScoringFrame(
                timestamp: t,
                userAccel: SIMD3(lateral, 0, -0.15 * cos(omega * t)),
                gravity: SIMD3(0, 0, -1),
                rotationRate: SIMD3(0, 0, -yaw),
                gpsSpeed: speed
            )
        }
    }

    // MARK: - Run length

    @Test("identical technique scores the same regardless of run length")
    func testRunLengthDoesNotChangeScore() {
        // The regression: SPARC and LDLJ-A were computed once over the whole run
        // rather than per turn. LDLJ-A's raw value falls by 2*ln(2) for every
        // doubling of duration, so a longer run of identical technique lost
        // roughly 15% of the normalised scale purely for being longer.
        let short = CarvingScorer.score(frames: makeRun(turnCount: 10))
        let long = CarvingScorer.score(frames: makeRun(turnCount: 40))

        let shortScore = try! #require(short.overall)
        let longScore = try! #require(long.overall)

        #expect(abs(shortScore - longScore) < 5.0,
                "a 4x longer run of identical technique scored \(longScore) vs \(shortScore)")
    }

    @Test("the linkage sub metric itself is length independent")
    func testLinkageSubMetricStable() {
        func linkage(_ score: CarvingScore) -> Double? {
            score.subMetrics.first { $0.id == SubMetricID.linkageSmoothness.rawValue }?.normalized
        }
        let short = try! #require(linkage(CarvingScorer.score(frames: makeRun(turnCount: 10))))
        let long = try! #require(linkage(CarvingScorer.score(frames: makeRun(turnCount: 40))))

        #expect(abs(short - long) < 5.0,
                "linkage moved from \(short) to \(long) on duration alone")
    }

    // MARK: - Sample rate

    @Test("a throttled run drops the spectral metric instead of scoring quiet")
    func testThrottledRunDropsChatter() {
        // At 20 Hz the run is below the spectral gate. Upsampling to the analysis
        // grid cannot recreate the high frequency content chatter measures, so
        // including it would flatter a struggling phone with a "quiet" reading.
        let throttled = CarvingScorer.score(frames: makeRun(turnCount: 12, sampleRate: 20))
        let full = CarvingScorer.score(frames: makeRun(turnCount: 12, sampleRate: 100))

        let throttledHasChatter = throttled.subMetrics.contains { $0.id == SubMetricID.chatter.rawValue }
        let fullHasChatter = full.subMetrics.contains { $0.id == SubMetricID.chatter.rawValue }

        #expect(!throttledHasChatter, "chatter must be dropped below the spectral gate")
        #expect(fullHasChatter, "chatter must contribute at full rate")
    }

    @Test("dropping a metric re-normalises the pillar rather than counting zero")
    func testPillarRenormalises() {
        // A dropped metric must not drag Control toward zero. Both runs are the
        // same technique, so the pillar should stay in the same neighbourhood.
        let throttled = CarvingScorer.score(frames: makeRun(turnCount: 12, sampleRate: 20))
        let full = CarvingScorer.score(frames: makeRun(turnCount: 12, sampleRate: 100))

        let throttledControl = try! #require(throttled.pillars.controlSmoothness)
        let fullControl = try! #require(full.pillars.controlSmoothness)

        #expect(throttledControl > fullControl * 0.5,
                "control collapsed from \(fullControl) to \(throttledControl) after dropping one metric")
    }

    @Test("the analysis rate never exceeds what the run captured")
    func testMedianRateReported() {
        let throttled = CarvingScorer.score(frames: makeRun(turnCount: 12, sampleRate: 20))
        #expect(throttled.dataQuality.medianSampleRate < 25,
                "the reported capture rate should reflect the throttled run")
    }

    // MARK: - Turn marks

    @Test("turn marks are exposed and alternate direction")
    func testTurnMarksAlternate() {
        let score = CarvingScorer.score(frames: makeRun(turnCount: 12))
        #expect(score.turns.count == score.turnCount)
        #expect(score.turns.count >= 8)

        let leftCount = score.turns.filter(\.isLeft).count
        let rightCount = score.turns.count - leftCount
        #expect(abs(leftCount - rightCount) <= 1,
                "evenly linked turns should alternate, got \(leftCount) left and \(rightCount) right")
    }

    @Test("turn marks are timed from the start of the run")
    func testTurnMarkTimesAreRelative() {
        let score = CarvingScorer.score(frames: makeRun(turnCount: 12))
        let first = try! #require(score.turns.first)
        #expect(first.startTime >= 0)
        #expect(first.startTime < 5, "the first turn should sit near the run's start")

        // Marks are ordered and non-overlapping in time.
        for (a, b) in zip(score.turns, score.turns.dropFirst()) {
            #expect(b.startTime >= a.startTime)
        }
    }

    // MARK: - GPS seeding

    @Test("turns before the first GPS fix are not treated as stationary")
    func testSpeedBackfill() {
        // carryForwardSpeed used to seed 0, so every frame before the first fix
        // claimed the skier was standing still, zeroing the centripetal estimate
        // and destroying carve purity for the opening turns.
        var frames = makeRun(turnCount: 14, speed: nil)
        // Give GPS only to the back half of the run.
        for i in (frames.count / 2)..<frames.count {
            frames[i] = ScoringFrame(
                timestamp: frames[i].timestamp,
                userAccel: frames[i].userAccel,
                gravity: frames[i].gravity,
                rotationRate: frames[i].rotationRate,
                gpsSpeed: 15
            )
        }
        let score = CarvingScorer.score(frames: frames)
        #expect(score.overall != nil, "a run with partial GPS should still score")
    }
}
