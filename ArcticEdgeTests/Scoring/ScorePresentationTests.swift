// ScorePresentationTests.swift
// ArcticEdgeTests/Scoring
//
// The presentation layer's honesty rules, pinned as tests. These are the claims
// the app makes to a skier, so a regression here is a credibility bug rather
// than a cosmetic one.

import Testing
import Foundation
@testable import ArcticEdge

@Suite("Score presentation")
struct ScorePresentationTests {

    // MARK: - Formatting

    @Test("an unmeasured value renders as a dash, never as zero")
    func testNilRendersAsDash() {
        #expect(MetricFormatter.score(nil) == MetricFormatter.placeholder)
        #expect(MetricFormatter.speed(nil) == MetricFormatter.placeholder)
        #expect(MetricFormatter.altitude(nil) == MetricFormatter.placeholder)
        #expect(MetricFormatter.distance(nil) == MetricFormatter.placeholder)
        #expect(MetricFormatter.duration(nil) == MetricFormatter.placeholder)
    }

    @Test("a measured zero still renders as zero")
    func testZeroIsNotADash() {
        // Zero and unknown are different claims. A run that genuinely measured
        // 0 m of vertical should say so.
        #expect(MetricFormatter.altitude(0) == "0")
        #expect(MetricFormatter.duration(0) == "0:00")
    }

    @Test("unit conversion is applied")
    func testUnitConversion() {
        // 10 m/s is 36 km/h and about 22 mph.
        #expect(MetricFormatter.speed(10, units: .metric) == "36")
        #expect(MetricFormatter.speed(10, units: .imperial) == "22")
        // 1000 m is 1.00 km and about 0.62 mi.
        #expect(MetricFormatter.distance(1000, units: .metric) == "1.00")
        #expect(MetricFormatter.distance(1000, units: .imperial) == "0.62")
        // 100 m is about 328 ft.
        #expect(MetricFormatter.altitude(100, units: .imperial) == "328")
    }

    @Test("durations past an hour include the hour")
    func testLongDuration() {
        #expect(MetricFormatter.duration(3661) == "1:01:01")
        #expect(MetricFormatter.duration(125) == "2:05")
    }

    // MARK: - Bands

    @Test("score bands follow the documented provisional thresholds")
    func testBandThresholds() {
        #expect(ScoreBand(score: 0) == .developing)
        #expect(ScoreBand(score: 39.9) == .developing)
        #expect(ScoreBand(score: 40) == .solid)
        #expect(ScoreBand(score: 59.9) == .solid)
        #expect(ScoreBand(score: 60) == .strong)
        #expect(ScoreBand(score: 79.9) == .strong)
        #expect(ScoreBand(score: 80) == .expert)
        #expect(ScoreBand(score: 100) == .expert)
    }

    // MARK: - Provisional labelling

    @Test("a provisional model version is detected so the UI can tag it")
    func testProvisionalDetection() {
        let quality = DataQuality(turnCount: 0, durationSeconds: 0,
                                  medianSampleRate: 0, gpsCoverage: 0, sufficientData: false)
        let provisional = CarvingScore.insufficient(version: "v1-provisional", quality: quality)
        let calibrated = CarvingScore.insufficient(version: "v2", quality: quality)

        #expect(provisional.isProvisional, "the shipped model must be tagged provisional")
        #expect(!calibrated.isProvisional)
    }

    @Test("the shipped model is still provisional")
    func testShippedModelIsProvisional() {
        // Guards the honesty rule directly: the absolute score stays labelled
        // provisional until the anchors are recalibrated from real runs.
        #expect(CarvingScoreModel.v1.version.hasSuffix("-provisional"))
    }

    // MARK: - Insufficient data

    @Test("an unscorable run carries nil, not zero, everywhere")
    func testInsufficientCarriesNil() {
        let quality = DataQuality(turnCount: 3, durationSeconds: 9,
                                  medianSampleRate: 100, gpsCoverage: 0, sufficientData: false)
        let score = CarvingScore.insufficient(version: "v1-provisional", quality: quality)

        #expect(score.overall == nil)
        #expect(score.pillars.controlSmoothness == nil)
        #expect(score.pillars.rhythmSymmetry == nil)
        #expect(score.pillars.carvingIntensity == nil)
        #expect(score.turns.isEmpty)
        #expect(!score.dataQuality.sufficientData)
    }

    // MARK: - Day summary

    @Test("day summary averages only today's scored runs")
    func testDaySummaryFiltersToToday() {
        let calendar = Calendar.current
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!

        let summary = DaySummary.build(
            from: [
                makeRun(start: now, score: 80, vertical: 300),
                makeRun(start: now, score: 60, vertical: 200),
                makeRun(start: yesterday, score: 10, vertical: 999)
            ],
            calendar: calendar,
            now: now
        )

        #expect(summary.runCount == 2, "yesterday's run must not count toward today")
        #expect(summary.averageScore == 70)
        #expect(summary.totalVertical == 500)
    }

    @Test("a day with no scored runs reports nil, not zero")
    func testDaySummaryWithoutScores() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let summary = DaySummary.build(
            from: [makeRun(start: now, score: nil, vertical: nil)],
            now: now
        )

        #expect(summary.runCount == 1)
        #expect(summary.averageScore == nil, "an unscored day is unknown, not zero")
        #expect(summary.totalVertical == nil)
    }

    @Test("an empty day summarises to nothing")
    func testEmptyDaySummary() {
        let summary = DaySummary.build(from: [], now: Date())
        #expect(summary.runCount == 0)
        #expect(summary.averageScore == nil)
        #expect(summary.totalVertical == nil)
    }

    private func makeRun(start: Date, score: Double?, vertical: Double?) -> RunSnapshot {
        let record = RunRecord(runID: UUID(), startTimestamp: start)
        record.endTimestamp = start.addingTimeInterval(120)
        record.carvingScore = score
        record.verticalDrop = vertical
        return RunSnapshot(from: record)
    }
}
