// UptimeClock.swift
// ArcticEdge
//
// Converts CMDeviceMotion timestamps into wall-clock dates.
//
// CMDeviceMotion.timestamp is seconds since the device booted, NOT seconds since
// 1970. Treating it as a Unix epoch produced run start dates in January 1970
// while run end dates came from Date(), so every run reported a duration of
// roughly 56 years and history sorted by uptime instead of by date.
//
// The two domains are bridged through the boot instant:
//     bootDate = now - systemUptime
//     wallClock(forUptime:) = bootDate + uptime
//
// Callers converting a batch should construct one instance and reuse it, so
// every frame in the batch is anchored to the same boot estimate.

import Foundation

nonisolated struct UptimeClock: Sendable {
    /// The instant the device booted, as estimated when this value was created.
    let bootDate: Date

    /// Captures the current boot estimate. Cheap: two clock reads.
    init(now: Date = Date(), systemUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.bootDate = now.addingTimeInterval(-systemUptime)
    }

    /// Wall-clock date for a monotonic uptime timestamp.
    func date(forUptime uptime: TimeInterval) -> Date {
        bootDate.addingTimeInterval(uptime)
    }

    /// Monotonic uptime for a wall-clock date. Inverse of `date(forUptime:)`.
    func uptime(forDate date: Date) -> TimeInterval {
        date.timeIntervalSince(bootDate)
    }
}
