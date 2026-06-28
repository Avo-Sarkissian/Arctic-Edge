// CarvingScoreModel.swift
// ArcticEdge
//
// Versioned, frozen configuration for the carving score: pillar weights,
// per sub metric normalization anchors, and data gates. Freezing this and
// stamping its version on every computed score keeps runs comparable over
// a season. Anchors are PROVISIONAL (literature informed) until recalibrated
// from real runs via the CalibrationExporter. See docs/CARVING-SCORE.md.

import Foundation

/// Maps a raw sub metric value onto 0...1 by linear interpolation between
/// a `bad` and a `good` anchor, clamped. Direction is encoded by which
/// anchor is larger, so the same struct handles "higher is better" and
/// "lower is better" metrics.
nonisolated struct ScoreAnchor: Sendable {
    let bad: Double
    let good: Double

    func normalize(_ raw: Double) -> Double {
        guard good != bad else { return 0.5 }
        let t = (raw - bad) / (good - bad)
        return min(max(t, 0), 1)
    }
}

/// Stable identifiers for each sub metric (also used as anchor keys).
nonisolated enum SubMetricID: String, Sendable, CaseIterable {
    case edgeTransitionSmoothness   // SPARC on angular speed
    case linkageSmoothness          // LDLJ-A on horizontal accel
    case chatter                    // HF RMS on vertical accel (lower better)
    case cadenceRegularity          // CoV of turn durations (lower better)
    case symmetry                   // left vs right balance (higher better)
    case carvePurity                // a_h vs v*yawRate agreement (higher better)
    case turnShapeConsistency       // CoV of per turn radius (lower better)

    var label: String {
        switch self {
        case .edgeTransitionSmoothness: return "Edge Smoothness"
        case .linkageSmoothness: return "Linkage Smoothness"
        case .chatter: return "Quietness"
        case .cadenceRegularity: return "Rhythm"
        case .symmetry: return "Symmetry"
        case .carvePurity: return "Carve Purity"
        case .turnShapeConsistency: return "Turn Shape"
        }
    }
}

nonisolated struct CarvingScoreModel: Sendable {
    let version: String

    // Across pillar weights (geometric mean limits compensability).
    let weightControl: Double
    let weightRhythm: Double
    let weightIntensity: Double

    // Data gates.
    let minTurns: Int
    let minDurationSeconds: Double
    let minGPSCoverage: Double      // below this, carving intensity pillar drops out

    // Analysis grid and filtering.
    let analysisSampleRate: Double
    let chatterCutoffHz: Double     // high pass knee for chatter energy

    let anchors: [SubMetricID: ScoreAnchor]

    /// Provisional v1 model. Anchors are hand set from the research ranges
    /// and MUST be recalibrated from labeled real runs before the absolute
    /// scale is treated as authoritative (the UI labels it provisional).
    static let v1 = CarvingScoreModel(
        version: "1.0.0-provisional",
        weightControl: 0.45,
        weightRhythm: 0.30,
        weightIntensity: 0.25,
        minTurns: 8,
        minDurationSeconds: 4.0,
        minGPSCoverage: 0.3,
        analysisSampleRate: 50.0,
        chatterCutoffHz: 5.0,
        anchors: [
            // SPARC is negative; less negative (closer to 0) is smoother.
            .edgeTransitionSmoothness: ScoreAnchor(bad: -9.0, good: -1.5),
            // LDLJ-A is negative; less negative is smoother.
            .linkageSmoothness: ScoreAnchor(bad: -22.0, good: -4.0),
            // Chatter RMS (g): high is bad, near zero is good.
            .chatter: ScoreAnchor(bad: 0.35, good: 0.01),
            // Cadence CoV: high variability is bad, metronomic is good.
            .cadenceRegularity: ScoreAnchor(bad: 0.6, good: 0.05),
            // Symmetry index 0...1: 1 is perfectly balanced.
            .symmetry: ScoreAnchor(bad: 0.4, good: 1.0),
            // Carve purity (mean per turn correlation): 1 is a clean carve.
            .carvePurity: ScoreAnchor(bad: 0.2, good: 0.95),
            // Turn shape CoV: high variability is bad, consistent is good.
            .turnShapeConsistency: ScoreAnchor(bad: 0.7, good: 0.1)
        ]
    )

    func anchor(_ id: SubMetricID) -> ScoreAnchor {
        anchors[id] ?? ScoreAnchor(bad: 0, good: 1)
    }
}
