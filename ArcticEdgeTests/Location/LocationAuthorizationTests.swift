// LocationAuthorizationTests.swift
// ArcticEdgeTests
//
// Covers the pure authorization state mapping and the GPS fix trust gate.
// Both are decision points that silently disable metrics when wrong, so they
// are tested without a live CLLocationManager.

import CoreLocation
import Foundation
import Testing
@testable import ArcticEdge

@Suite("LocationAuthorization")
struct LocationAuthorizationTests {

    // MARK: - Status mapping

    @Test func notDeterminedMapsToNotDetermined() {
        let state = LocationAuthorization.mapState(status: .notDetermined, accuracy: .fullAccuracy)
        #expect(state == .notDetermined)
        #expect(!state.isBlocked, "an undecided prompt is not a refusal")
    }

    @Test func deniedAndRestrictedBlockLocation() {
        #expect(LocationAuthorization.mapState(status: .denied, accuracy: .fullAccuracy) == .denied)
        #expect(LocationAuthorization.mapState(status: .restricted, accuracy: .fullAccuracy) == .restricted)
        #expect(LocationAccessState.denied.isBlocked)
        #expect(LocationAccessState.restricted.isBlocked)
    }

    @Test func whenInUseWithFullAccuracyIsTheHealthyState() {
        let state = LocationAuthorization.mapState(status: .authorizedWhenInUse, accuracy: .fullAccuracy)
        #expect(state == .authorizedFull)
        #expect(state.providesPreciseSpeed)
        #expect(state.degradedReason == nil, "the healthy state must not warn")
    }

    @Test func reducedAccuracyIsAuthorizedButNotTrusted() {
        // Approximate location still delivers updates, but speed and distance
        // derived from them are not trustworthy and the UI must say so.
        let state = LocationAuthorization.mapState(status: .authorizedWhenInUse, accuracy: .reducedAccuracy)
        #expect(state == .authorizedReduced)
        #expect(!state.providesPreciseSpeed)
        #expect(!state.isBlocked, "reduced accuracy still yields fixes")
        #expect(state.degradedReason != nil)
    }

    @Test func alwaysAuthorizationIsTreatedAsFull() {
        #expect(LocationAuthorization.mapState(status: .authorizedAlways, accuracy: .fullAccuracy) == .authorizedFull)
    }

    // MARK: - GPS fix trust gate

    @Test func goodFixIsTrusted() {
        let reading = GPSReading(speed: 12.0, horizontalAccuracy: 8.0, timestamp: .now, speedAccuracy: 1.0)
        #expect(reading.isTrustworthyForSpeed)
    }

    @Test func negativeSpeedIsRejected() {
        let reading = GPSReading(speed: -1, horizontalAccuracy: 5.0, timestamp: .now, speedAccuracy: 1.0)
        #expect(!reading.isTrustworthyForSpeed, "-1 is Core Location's unavailable sentinel")
    }

    @Test func poorHorizontalAccuracyIsRejected() {
        // A 90 m fix in trees is exactly the case that used to inflate top speed.
        let reading = GPSReading(speed: 25.0, horizontalAccuracy: 90.0, timestamp: .now, speedAccuracy: 1.0)
        #expect(!reading.isTrustworthyForSpeed)
    }

    @Test func poorSpeedAccuracyIsRejected() {
        let reading = GPSReading(speed: 25.0, horizontalAccuracy: 5.0, timestamp: .now, speedAccuracy: 12.0)
        #expect(!reading.isTrustworthyForSpeed)
    }

    @Test func missingSpeedAccuracyDoesNotDisqualifyAnOtherwiseGoodFix() {
        // speedAccuracy < 0 means "not reported", not "bad". Older fixes and some
        // hardware omit it; rejecting those would discard usable data.
        let reading = GPSReading(speed: 15.0, horizontalAccuracy: 6.0, timestamp: .now, speedAccuracy: -1)
        #expect(reading.isTrustworthyForSpeed)
    }

    @Test func coordinatePresenceIsDetected() {
        let withCoord = GPSReading(speed: 5, horizontalAccuracy: 5, timestamp: .now,
                                   latitude: 46.53, longitude: 7.96)
        let withoutCoord = GPSReading(speed: 5, horizontalAccuracy: 5, timestamp: .now)
        #expect(withCoord.hasCoordinate)
        #expect(!withoutCoord.hasCoordinate)
    }

    // MARK: - GPS health messaging

    @Test func healthyStatesStaySilent() {
        #expect(GPSHealth.idle.message == nil)
        #expect(GPSHealth.receiving.message == nil)
    }

    @Test func degradedStatesExplainThemselves() {
        #expect(GPSHealth.denied.message != nil)
        #expect(GPSHealth.reducedAccuracy.message != nil)
        #expect(GPSHealth.unavailable.message != nil)
    }
}
