// PowerSaverTests.swift
// ArcticEdgeTests
//
// Tests for AppModel.nextPowerSaverMode threshold logic.
// Uses the pure nonisolated static function to avoid instantiating a heavy AppModel.

import Testing
@testable import ArcticEdge

@Suite("Power Saver Mode")
struct PowerSaverTests {

    @Test("Activates at 30% battery from normal mode")
    func testActivatesAt30Percent() {
        let result = AppModel.nextPowerSaverMode(current: .normal, batteryPercent: 30)
        #expect(result == .saving)
    }

    @Test("Deactivates at 35% battery from saving mode")
    func testDeactivatesAt35Percent() {
        let result = AppModel.nextPowerSaverMode(current: .saving, batteryPercent: 35)
        #expect(result == .normal)
    }

    @Test("Stays saving at 32% — hysteresis prevents flapping")
    func testNoFlappingAt32Percent() {
        let result = AppModel.nextPowerSaverMode(current: .saving, batteryPercent: 32)
        #expect(result == .saving)
    }

    @Test("Does not activate at 31% — threshold is inclusive ≤30")
    func testDoesNotActivateAt31Percent() {
        let result = AppModel.nextPowerSaverMode(current: .normal, batteryPercent: 31)
        #expect(result == .normal)
    }

    @Test("Activates at 0% battery")
    func testActivatesAtZeroPercent() {
        let result = AppModel.nextPowerSaverMode(current: .normal, batteryPercent: 0)
        #expect(result == .saving)
    }

    @Test("Stays normal well above threshold")
    func testStaysNormalAt80Percent() {
        let result = AppModel.nextPowerSaverMode(current: .normal, batteryPercent: 80)
        #expect(result == .normal)
    }
}
