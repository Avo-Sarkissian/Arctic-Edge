// AltimeterManager.swift
// ArcticEdge
//
// Barometric relative altitude via CMAltimeter.
//
// Why this exists: vertical drop was previously integrated as
// speed * sin(device attitude pitch) * dt. For a pocket-worn phone, attitude
// pitch tracks thigh angle, not slope, so that number was an integral of leg
// swing rather than descent. The barometer is slope-independent,
// orientation-independent, resolves roughly 0.1 m, works under tree cover and
// in canyons where GPS altitude is unusable, and costs almost no power.
//
// CMAltimeter reports altitude relative to the moment updates started, so only
// deltas are meaningful. That is exactly what vertical drop needs.

import CoreMotion
import Foundation

// MARK: - AltitudeSample

nonisolated struct AltitudeSample: Sendable, Equatable {
    let relativeAltitude: Double  // meters, relative to session start
    let timestamp: Date
}

// MARK: - AltimeterManager

actor AltimeterManager {
    private let altimeter = CMAltimeter()
    private var isRunning = false

    /// Most recent relative altitude, stamped onto frames at flush time the same
    /// way GPS speed is. nil until the first barometer sample arrives.
    private(set) var latestAltitude: Double?

    /// True when the device has a barometer and permission to use it.
    nonisolated static var isAvailable: Bool {
        CMAltimeter.isRelativeAltitudeAvailable()
    }

    private(set) var lastError: String?

    func start() {
        guard !isRunning, Self.isAvailable else { return }
        isRunning = true
        latestAltitude = nil
        lastError = nil
        // OperationQueue() is fine here: samples arrive at roughly 1 Hz and each
        // one only overwrites a scalar, so delivery order carries no filter state.
        altimeter.startRelativeAltitudeUpdates(to: OperationQueue()) { [weak self] data, error in
            if let error {
                let message = error.localizedDescription
                Task { await self?.record(error: message) }
                return
            }
            guard let data else { return }
            let meters = data.relativeAltitude.doubleValue
            Task { await self?.record(altitude: meters) }
        }
    }

    func stop() {
        guard isRunning else { return }
        altimeter.stopRelativeAltitudeUpdates()
        isRunning = false
        latestAltitude = nil
    }

    private func record(altitude: Double) {
        latestAltitude = altitude
    }

    private func record(error: String) {
        lastError = error
    }
}
