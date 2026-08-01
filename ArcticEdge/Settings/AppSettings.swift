// AppSettings.swift
// ArcticEdge
//
// User preferences, persisted in UserDefaults.
//
// Kept deliberately small: a settings screen is where a product goes to avoid
// making decisions, so only choices the app genuinely cannot make on the user's
// behalf live here.

import Foundation
import SwiftUI

@Observable
@MainActor
final class AppSettings {

    private enum Key {
        static let unitSystem = "settings.unitSystem"
        static let hasCompletedOnboarding = "settings.hasCompletedOnboarding"
    }

    private let defaults: UserDefaults

    var unitSystem: UnitSystem {
        didSet { defaults.set(unitSystem.rawValue, forKey: Key.unitSystem) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Default to the region's own convention rather than forcing metric.
        let stored = defaults.string(forKey: Key.unitSystem)
        self.unitSystem = stored.flatMap(UnitSystem.init(rawValue:)) ?? AppSettings.regionDefault()
        // UI tests that exercise the tabs launch past the primer.
        let skipOnboarding = ProcessInfo.processInfo.arguments.contains("-UITestSkipOnboarding")
        self.hasCompletedOnboarding = skipOnboarding || defaults.bool(forKey: Key.hasCompletedOnboarding)
    }

    /// Metric everywhere except the few regions that measure distance in miles.
    nonisolated static func regionDefault(locale: Locale = .current) -> UnitSystem {
        locale.measurementSystem == .metric ? .metric : .imperial
    }
}
