// LocationAuthorization.swift
// ArcticEdge
//
// Explicit Core Location authorization request and status tracking.
//
// Why this exists: GPSManager drives CLLocationUpdate.liveUpdates, and
// CLBackgroundActivitySession only grants background execution once the app
// already holds when-in-use authorization. Nothing in the app used to request
// it, so on a fresh install the prompt never appeared and every GPS derived
// metric (speed, distance, the carving intensity pillar) silently produced
// nothing. This type owns the prompt and the resulting state.
//
// When-in-use is deliberate: combined with the `location` background mode and
// CLBackgroundActivitySession it is sufficient for all day capture, and it is
// the least invasive authorization that does the job. Always authorization is
// not requested.
//
// Reduced (approximate) accuracy is tracked separately: the app still runs,
// but speed and distance are not trustworthy and the UI must say so.

import CoreLocation
import Foundation

// MARK: - LocationAccessState

nonisolated enum LocationAccessState: Sendable, Equatable {
    case notDetermined
    case denied            // user declined
    case restricted        // policy or parental controls: user cannot grant
    case authorizedFull    // when-in-use or always, full accuracy
    case authorizedReduced // authorized but approximate location only

    /// True when Core Location can deliver speed and distance we would trust.
    var providesPreciseSpeed: Bool { self == .authorizedFull }

    /// True when no location data will arrive at all.
    var isBlocked: Bool { self == .denied || self == .restricted }

    /// Short user facing description of the degraded modes. nil when all is well.
    var degradedReason: String? {
        switch self {
        case .authorizedFull:  return nil
        case .notDetermined:   return "Location access not yet granted."
        case .denied:          return "Location access denied. Speed, distance, and vertical are unavailable."
        case .restricted:      return "Location access is restricted on this device. Speed, distance, and vertical are unavailable."
        case .authorizedReduced: return "Precise Location is off. Speed and distance are estimates only."
        }
    }
}

// MARK: - Delegate bridge

// CLLocationManagerDelegate callbacks are bridged through a separate NSObject
// so the observable type below does not have to inherit from NSObject.
// @unchecked Sendable: all mutable state is guarded by `lock`, mirroring the
// WorkoutSessionDelegate pattern used for HKWorkoutSession.
private final class AuthorizationDelegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var handler: (@Sendable (CLAuthorizationStatus, CLAccuracyAuthorization) -> Void)?

    nonisolated override init() { super.init() }

    nonisolated func setHandler(_ handler: @escaping @Sendable (CLAuthorizationStatus, CLAccuracyAuthorization) -> Void) {
        lock.withLock { self.handler = handler }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let accuracy = manager.accuracyAuthorization
        let h = lock.withLock { self.handler }
        h?(status, accuracy)
    }
}

// MARK: - LocationAuthorization

@Observable
@MainActor
final class LocationAuthorization {

    private(set) var state: LocationAccessState = .notDetermined

    // CLLocationManager needs a run loop, so it is created on first use from the
    // main actor rather than in init. AppModel's init is nonisolated (SwiftUI may
    // evaluate it outside a main-actor context), and forcing isolation there with
    // assumeIsolated would trap rather than degrade.
    private var manager: CLLocationManager?
    private let delegate = AuthorizationDelegate()

    // Continuations parked while the system prompt is on screen.
    private var pendingRequests: [CheckedContinuation<LocationAccessState, Never>] = []

    nonisolated init() {}

    /// Creates the underlying manager and reads the current status. Idempotent.
    /// Call once during app setup, before anything reads `state`.
    @discardableResult
    func activate() -> LocationAccessState {
        if let manager {
            apply(status: manager.authorizationStatus, accuracy: manager.accuracyAuthorization)
            return state
        }
        let manager = CLLocationManager()
        manager.delegate = delegate
        delegate.setHandler { [weak self] status, accuracy in
            Task { @MainActor [weak self] in
                self?.apply(status: status, accuracy: accuracy)
            }
        }
        self.manager = manager
        apply(status: manager.authorizationStatus, accuracy: manager.accuracyAuthorization)
        return state
    }

    /// Presents the system prompt when the status is still undetermined and
    /// waits for the user's answer. Returns immediately with the current state
    /// once authorization has already been decided.
    @discardableResult
    func requestIfNeeded() async -> LocationAccessState {
        let manager = self.manager ?? { activate(); return self.manager! }()
        guard state == .notDetermined else { return state }
        return await withCheckedContinuation { (continuation: CheckedContinuation<LocationAccessState, Never>) in
            pendingRequests.append(continuation)
            manager.requestWhenInUseAuthorization()
        }
    }

    // MARK: - Private

    private func apply(status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization) {
        let newState = Self.mapState(status: status, accuracy: accuracy)
        state = newState
        // Only resume waiters once the user has actually answered.
        guard newState != .notDetermined, !pendingRequests.isEmpty else { return }
        let waiting = pendingRequests
        pendingRequests = []
        for continuation in waiting { continuation.resume(returning: newState) }
    }

    /// Pure mapping, extracted so the state table is unit testable without
    /// a live CLLocationManager.
    nonisolated static func mapState(
        status: CLAuthorizationStatus,
        accuracy: CLAccuracyAuthorization
    ) -> LocationAccessState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .authorizedWhenInUse, .authorizedAlways:
            return accuracy == .fullAccuracy ? .authorizedFull : .authorizedReduced
        @unknown default:
            return .notDetermined
        }
    }
}
