// CalibrationExporter.swift
// ArcticEdge
//
// Exports one run's sensor frames as a JSON file to:
//   <Documents>/Calibration/run-<shortID>-<date>.json
//
// Purpose: field testers label exported JSON (marking skiing vs chairlift
// segments, and rating the run) to produce the ground truth that recalibrates the
// carving score anchors and the classifier thresholds. Until that happens the
// score's absolute scale stays labelled provisional.
//
// Reachable from Settings. The exporter previously had no caller anywhere in the
// app, so the calibration plan had no way to get data off the device.
//
// Takes a concrete PersistenceService (not the protocol) to access
// fetchFrameDataForRun() which returns Sendable [FrameSnapshot] — same pattern
// as PostRunViewModel.loadData(persistenceService:ringBuffer:).

import Foundation
import SwiftData

actor CalibrationExporter {

    private let persistence: PersistenceService

    init(persistence: PersistenceService) {
        self.persistence = persistence
    }

    /// Exports all FrameSnapshots for `runID` to a JSON file in Documents/Calibration/.
    /// Returns the written file URL on success.
    func exportRun(runID: UUID) async throws -> URL {
        let snapshots = try await persistence.fetchFrameDataForRun(runID: runID)
        guard !snapshots.isEmpty else { throw CalibrationExportError.noFramesForRun }

        // The run's own metadata travels with the frames: recalibrating anchors
        // means comparing a labelled human rating against what the model produced,
        // which needs the model version that produced it.
        let run = try? await persistence.fetchRunSnapshot(runID: runID)
        let payload = CalibrationPayload(
            runID: runID.uuidString,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            frameCount: snapshots.count,
            startTimestamp: run?.startTimestamp.timeIntervalSince1970,
            endTimestamp: run?.endTimestamp?.timeIntervalSince1970,
            carvingScore: run?.carvingScore,
            carvingScoreVersion: run?.carvingScoreVersion,
            topSpeed: run?.topSpeed,
            verticalDrop: run?.verticalDrop,
            resortName: run?.resortName,
            frames: snapshots.map(CalibrationFrame.init)
        )
        let data = try JSONEncoder().encode(payload)

        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw CalibrationExportError.documentsDirectoryUnavailable
        }
        let dir = docs.appendingPathComponent("Calibration", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let datePart = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let shortID = String(runID.uuidString.prefix(8))
        let url = dir.appendingPathComponent("run-\(shortID)-\(datePart).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Exports every completed run in one file set and returns the written URLs.
    /// A season of labelled runs is what actually moves the anchors; exporting
    /// one run at a time does not.
    func exportAllRuns() async throws -> [URL] {
        let runs = try await persistence.fetchCompletedRunSnapshots()
        var urls: [URL] = []
        for run in runs {
            // A run with no frames left (pruned by retention) is skipped rather
            // than failing the whole export.
            if let url = try? await exportRun(runID: run.runID) {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { throw CalibrationExportError.noFramesForRun }
        return urls
    }
}

// MARK: - Export payload types
// nonisolated: prevents SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor from inferring
// @MainActor on Encodable conformances, which would make JSONEncoder.encode() fail
// when called from CalibrationExporter's actor context.

private nonisolated struct CalibrationPayload: Encodable, Sendable {
    let runID: String
    let exportedAt: String
    let frameCount: Int
    let startTimestamp: Double?
    let endTimestamp: Double?
    let carvingScore: Double?
    let carvingScoreVersion: String?
    let topSpeed: Double?
    let verticalDrop: Double?
    let resortName: String?
    let frames: [CalibrationFrame]
}

private nonisolated struct CalibrationFrame: Encodable, Sendable {
    let timestamp: Double
    let pitch: Double
    let roll: Double
    let yaw: Double
    let userAccelX: Double
    let userAccelY: Double
    let userAccelZ: Double
    // Gravity and gyro are required to recalibrate the carving score
    // anchors from labeled real runs (the engine projects on gravity and
    // uses yaw rate about vertical).
    let gravityX: Double
    let gravityY: Double
    let gravityZ: Double
    let rotationRateX: Double
    let rotationRateY: Double
    let rotationRateZ: Double
    // Gravity-referenced channels: what the engine actually consumes.
    let filteredVerticalAccel: Double?
    let horizontalAccelMagnitude: Double?
    let gpsSpeed: Double?
    let gpsHorizontalAccuracy: Double?
    let gpsSpeedAccuracy: Double?
    let relativeAltitude: Double?

    nonisolated init(_ snapshot: FrameSnapshot) {
        self.timestamp = snapshot.timestamp
        self.pitch = snapshot.pitch
        self.roll = snapshot.roll
        self.yaw = snapshot.yaw
        self.userAccelX = snapshot.userAccelX
        self.userAccelY = snapshot.userAccelY
        self.userAccelZ = snapshot.userAccelZ
        self.gravityX = snapshot.gravityX
        self.gravityY = snapshot.gravityY
        self.gravityZ = snapshot.gravityZ
        self.rotationRateX = snapshot.rotationRateX
        self.rotationRateY = snapshot.rotationRateY
        self.rotationRateZ = snapshot.rotationRateZ
        self.filteredVerticalAccel = snapshot.filteredVerticalAccel
        self.horizontalAccelMagnitude = snapshot.horizontalAccelMagnitude
        self.gpsSpeed = snapshot.gpsSpeed
        self.gpsHorizontalAccuracy = snapshot.gpsHorizontalAccuracy
        self.gpsSpeedAccuracy = snapshot.gpsSpeedAccuracy
        self.relativeAltitude = snapshot.relativeAltitude
    }
}

// MARK: - Errors

enum CalibrationExportError: Error, LocalizedError {
    case documentsDirectoryUnavailable
    case noFramesForRun

    var errorDescription: String? {
        switch self {
        case .documentsDirectoryUnavailable:
            return "Could not reach the app's documents folder."
        case .noFramesForRun:
            return "No raw data left to export. Frames older than the retention window are removed."
        }
    }
}
