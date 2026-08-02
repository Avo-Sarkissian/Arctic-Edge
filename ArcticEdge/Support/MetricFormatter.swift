// MetricFormatter.swift
// ArcticEdge
//
// One place that turns measurements into display strings.
//
// Every metric is Optional at the source: nil means "not measured", and it must
// render as a dash rather than a zero. Views used to format non-optional values
// that defaulted to 0, so a run with no GPS advertised "0 km/h" and "0 m vert"
// as though those were readings. Centralising the conversion also means the
// unit system is honoured everywhere at once.

import Foundation

// MARK: - UnitSystem

nonisolated enum UnitSystem: String, Sendable, CaseIterable, Identifiable {
    case metric
    case imperial

    var id: String { rawValue }

    var label: String {
        switch self {
        case .metric:   return "Metric"
        case .imperial: return "Imperial"
        }
    }

    var speedSuffix: String { self == .metric ? "km/h" : "mph" }
    var distanceSuffix: String { self == .metric ? "km" : "mi" }
    var altitudeSuffix: String { self == .metric ? "m" : "ft" }
}

// MARK: - MetricFormatter

nonisolated enum MetricFormatter {

    /// Rendered when a value was not measured. Not a zero: they mean different things.
    static let placeholder = "—"

    // MARK: - Speed

    /// Speed in m/s to a display string.
    static func speed(_ metersPerSecond: Double?, units: UnitSystem = .metric) -> String {
        guard let value = metersPerSecond, value >= 0 else { return placeholder }
        let converted = units == .metric ? value * 3.6 : value * 2.236936
        return String(format: "%.0f", converted)
    }

    static func speedWithUnit(_ metersPerSecond: Double?, units: UnitSystem = .metric) -> String {
        guard let value = metersPerSecond, value >= 0 else { return placeholder }
        return "\(speed(value, units: units)) \(units.speedSuffix)"
    }

    // MARK: - Distance

    /// Distance in meters to a display string in km or miles.
    static func distance(_ meters: Double?, units: UnitSystem = .metric) -> String {
        guard let value = meters, value >= 0 else { return placeholder }
        let converted = units == .metric ? value / 1000 : value / 1609.344
        return String(format: "%.2f", converted)
    }

    static func distanceWithUnit(_ meters: Double?, units: UnitSystem = .metric) -> String {
        guard let value = meters, value >= 0 else { return placeholder }
        return "\(distance(value, units: units))\(units.distanceSuffix)"
    }

    // MARK: - Altitude

    /// Vertical drop in meters to a display string in meters or feet.
    static func altitude(_ meters: Double?, units: UnitSystem = .metric) -> String {
        guard let value = meters, value >= 0 else { return placeholder }
        let converted = units == .metric ? value : value * 3.280840
        return String(format: "%.0f", converted)
    }

    static func altitudeWithUnit(_ meters: Double?, units: UnitSystem = .metric) -> String {
        guard let value = meters, value >= 0 else { return placeholder }
        return "\(altitude(value, units: units))\(units.altitudeSuffix)"
    }

    // MARK: - Duration

    /// Duration as m:ss, or h:mm:ss past an hour. Zero is a real duration, so it
    /// formats normally; only a nil is a dash.
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds >= 0 else { return placeholder }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Score

    /// Carving score as a whole number, or a dash when the run did not meet the
    /// minimum data gate. Never renders a nil score as 0.
    static func score(_ value: Double?) -> String {
        guard let value else { return placeholder }
        return String(format: "%.0f", value.rounded())
    }
}
