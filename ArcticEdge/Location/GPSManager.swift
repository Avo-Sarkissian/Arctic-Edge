// GPSManager.swift
// ArcticEdge
//
// Actor wrapping CLLocationUpdate.liveUpdates(.otherNavigation) into an AsyncStream
// of GPSReading values. Multiple consumers are supported via UUID-keyed continuations.
//
// Design notes:
// - .otherNavigation avoids road-snapping that would corrupt mountain terrain coordinates.
// - backgroundSession is a stored property: local assignment causes premature deallocation,
//   which silently kills the GPS update stream (see Phase 2 RESEARCH.md pitfall 2).
// - Raw speed/accuracy values are preserved as-is; negative sentinels mean "unavailable".
//   Filtering is the consumer's responsibility, not GPS's.
// - CLLocationUpdate carries diagnostic flags (authorizationDenied, accuracyLimited,
//   locationUnavailable). Those are surfaced as GPSHealth so the app can tell the
//   skier why speed and distance are missing instead of silently showing nothing.
// - The live-updates stream can end mid-run (authorization change, session teardown).
//   It is restarted with bounded backoff while the day is still active.

import CoreLocation
import Foundation

// MARK: - GPSReading

/// Immutable value capturing one GPS fix from CLLocation.
/// speed == -1, speedAccuracy < 0, or horizontalAccuracy < 0 mean "unavailable".
nonisolated struct GPSReading: Sendable {
    let speed: Double               // m/s; -1 if unavailable
    let horizontalAccuracy: Double  // meters; <0 if unavailable
    let timestamp: Date
    let speedAccuracy: Double       // m/s; <0 if unavailable
    let latitude: Double
    let longitude: Double

    init(
        speed: Double,
        horizontalAccuracy: Double,
        timestamp: Date,
        speedAccuracy: Double = -1,
        latitude: Double = 0,
        longitude: Double = 0
    ) {
        self.speed = speed
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
        self.speedAccuracy = speedAccuracy
        self.latitude = latitude
        self.longitude = longitude
    }

    /// True when this fix is good enough to derive speed and distance from.
    /// Thresholds are deliberately loose: mountain terrain and tree cover
    /// routinely push horizontal accuracy past what a city fix would give.
    var isTrustworthyForSpeed: Bool {
        speed >= 0
            && horizontalAccuracy >= 0 && horizontalAccuracy <= 25
            && (speedAccuracy < 0 || speedAccuracy <= 3)
    }

    var hasCoordinate: Bool { latitude != 0 || longitude != 0 }
}

// MARK: - GPSHealth

/// Why GPS is or is not producing usable fixes. Surfaced to the UI so a
/// missing speed reading is explained rather than silently blank.
nonisolated enum GPSHealth: Sendable, Equatable {
    case idle                 // not started
    case awaitingFix          // running, no location yet
    case receiving            // healthy fixes arriving
    case reducedAccuracy      // authorized but approximate location only
    case denied               // authorization refused for this app or device-wide
    case unavailable          // temporarily no fix (tunnel, deep tree cover)

    var message: String? {
        switch self {
        case .idle, .receiving: return nil
        case .awaitingFix:      return "Acquiring GPS…"
        case .reducedAccuracy:  return "Precise Location is off: speed and distance are estimates."
        case .denied:           return "Location access denied: speed, distance, and vertical are unavailable."
        case .unavailable:      return "No GPS signal."
        }
    }
}

// MARK: - Protocol

/// Protocol enabling ActivityClassifier to accept a MockGPSManager in tests.
/// nonisolated members prevent SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor from inferring
/// @MainActor isolation on conforming types (same pattern as MotionDataSource).
protocol GPSManagerProtocol: Actor {
    func makeStream() -> AsyncStream<GPSReading>
    func start() async
    func stop() async
}

// MARK: - GPSManager

actor GPSManager: GPSManagerProtocol {
    // backgroundSession MUST be a stored property: releasing it kills the GPS stream.
    private var backgroundSession: CLBackgroundActivitySession?
    private var streamTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<GPSReading>.Continuation] = [:]
    private var powerSaverEnabled: Bool = false
    private var lastBroadcastDate: Date = .distantPast
    private let powerSaverMinInterval: TimeInterval = 5.0

    private(set) var health: GPSHealth = .idle
    private var isRunning: Bool = false

    // Bounded restart backoff for a stream that ends while the day is active.
    private let restartDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(15)]

    // MARK: - GPSManagerProtocol

    func makeStream() -> AsyncStream<GPSReading> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<GPSReading>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id: id) }
        }
        return stream
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        health = .awaitingFix
        // Retain the session; releasing it terminates the background task.
        // This only grants background execution because the target declares
        // the `location` UIBackgroundMode.
        backgroundSession = CLBackgroundActivitySession()
        streamTask = Task { [weak self] in
            await self?.runUpdateLoop()
        }
    }

    func stop() async {
        isRunning = false
        streamTask?.cancel()
        streamTask = nil
        backgroundSession = nil
        health = .idle
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations = [:]
    }

    func setPowerSaverMode(_ enabled: Bool) {
        powerSaverEnabled = enabled
        if !enabled { lastBroadcastDate = .distantPast }
    }

    // MARK: - Update loop

    // Consumes liveUpdates, and restarts it with bounded backoff if the sequence
    // ends while the day is still active. A stream that ends silently used to
    // kill every speed-derived metric for the rest of the session.
    private func runUpdateLoop() async {
        var attempt = 0
        while isRunning && !Task.isCancelled {
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    if Task.isCancelled { return }
                    attempt = 0  // a delivered update means the session is healthy
                    apply(update: update)
                }
            } catch {
                // Fall through to the backoff below and try again.
            }
            guard isRunning && !Task.isCancelled else { return }
            // Authorization refusal is terminal: retrying cannot fix it.
            if health == .denied { return }
            let delay = restartDelays[min(attempt, restartDelays.count - 1)]
            attempt += 1
            try? await Task.sleep(for: delay)
        }
    }

    private func apply(update: CLLocationUpdate) {
        if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
            health = .denied
            return
        }
        if update.accuracyLimited {
            health = .reducedAccuracy
        }
        guard let location = update.location else {
            if update.locationUnavailable { health = .unavailable }
            return
        }
        if health != .reducedAccuracy { health = .receiving }
        let reading = GPSReading(
            speed: location.speed,
            horizontalAccuracy: location.horizontalAccuracy,
            timestamp: location.timestamp,
            speedAccuracy: location.speedAccuracy,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        )
        broadcast(reading)
    }

    // MARK: - Private

    private func broadcast(_ reading: GPSReading) {
        if powerSaverEnabled {
            let now = reading.timestamp
            guard now.timeIntervalSince(lastBroadcastDate) >= powerSaverMinInterval else { return }
            lastBroadcastDate = now
        }
        for continuation in continuations.values {
            continuation.yield(reading)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
