// CarvingScore.swift
// ArcticEdge
//
// Output types for the carving score. `overall` is nil when the run has
// too little data to score honestly (better than a misleading number).
// See docs/CARVING-SCORE.md.

import Foundation

/// Per pillar scores, each 0...100 or nil when the pillar could not be
/// computed (for example carving intensity needs GPS).
nonisolated struct PillarScores: Sendable, Equatable {
    let controlSmoothness: Double?
    let rhythmSymmetry: Double?
    let carvingIntensity: Double?
}

/// A single normalized sub metric, exposed for drill down UI.
nonisolated struct SubMetricValue: Sendable, Equatable {
    let id: String
    let label: String
    let normalized: Double   // 0...100
    let raw: Double
}

/// What the score is based on, so the UI can be honest about confidence.
nonisolated struct DataQuality: Sendable, Equatable {
    let turnCount: Int
    let durationSeconds: Double
    let medianSampleRate: Double
    let gpsCoverage: Double   // 0...1 fraction of frames with GPS speed
    let sufficientData: Bool
}

nonisolated struct CarvingScore: Sendable, Equatable {
    let overall: Double?              // 0...100, nil if insufficient data
    let pillars: PillarScores
    let subMetrics: [SubMetricValue]
    let turnCount: Int
    let dataQuality: DataQuality
    let modelVersion: String

    /// The score for a run that could not be evaluated.
    static func insufficient(version: String, quality: DataQuality) -> CarvingScore {
        CarvingScore(
            overall: nil,
            pillars: PillarScores(controlSmoothness: nil, rhythmSymmetry: nil, carvingIntensity: nil),
            subMetrics: [],
            turnCount: quality.turnCount,
            dataQuality: quality,
            modelVersion: version
        )
    }
}
