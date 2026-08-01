// UptimeClockTests.swift
// ArcticEdgeTests/Motion
//
// Guards the bug that put every run start date in January 1970: treating a
// CMDeviceMotion uptime stamp as seconds since the Unix epoch.

import Testing
import Foundation
@testable import ArcticEdge

@Suite("UptimeClock")
struct UptimeClockTests {

    @Test("uptime converts to a date near now, not to 1970")
    func testUptimeIsNotEpoch() {
        // A device up for 13 hours. Read as an epoch this is 1970-01-01 46800s.
        let uptime: TimeInterval = 13 * 3600
        let now = Date(timeIntervalSince1970: 1_780_000_000)  // a plausible present
        let clock = UptimeClock(now: now, systemUptime: uptime)

        let converted = clock.date(forUptime: uptime)

        #expect(abs(converted.timeIntervalSince(now)) < 0.001,
                "the newest frame's uptime should map to roughly now")
        let naive = Date(timeIntervalSince1970: uptime)
        #expect(converted.timeIntervalSince(naive) > 1_700_000_000,
                "the correct conversion must be decades away from the epoch reading")
    }

    @Test("earlier uptimes map proportionally into the past")
    func testEarlierUptimeMapsBackwards() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let clock = UptimeClock(now: now, systemUptime: 10_000)

        let tenSecondsAgo = clock.date(forUptime: 9_990)
        #expect(abs(tenSecondsAgo.timeIntervalSince(now) + 10) < 0.001)
    }

    @Test("conversion round-trips")
    func testRoundTrip() {
        let clock = UptimeClock(now: Date(timeIntervalSince1970: 1_780_000_000), systemUptime: 5_000)
        let uptime: TimeInterval = 4_321
        let roundTripped = clock.uptime(forDate: clock.date(forUptime: uptime))
        #expect(abs(roundTripped - uptime) < 0.001)
    }

    @Test("run start and end land in the same clock domain")
    func testRunDurationIsPlausible() {
        // The regression this file exists for: a run start built from uptime and
        // an end built from Date() produced a ~56 year duration.
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let clock = UptimeClock(now: now, systemUptime: 20_000)

        let start = clock.date(forUptime: 19_880)   // 120 s before now
        let end = now
        let duration = end.timeIntervalSince(start)

        #expect(abs(duration - 120) < 0.001, "expected a 2 minute run, got \(duration) s")
    }
}
