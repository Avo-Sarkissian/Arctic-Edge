// CalibrationExporter.swift
// ArcticEdge
//
// Exports one run's sensor frames as a JSON file to:
//   <Documents>/Calibration/run-<shortID>-<date>.json
//
// Purpose: Field testers label exported JSON (marking skiing vs. chairlift segments)
// to produce ground-truth data for filter and classifier threshold calibration.
// Actual threshold updates are applied offline after a field test session.
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

        let payload = CalibrationPayload(
            runID: runID.uuidString,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            frameCount: snapshots.count,
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
}

// MARK: - Export payload types
// nonisolated: prevents SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor from inferring
// @MainActor on Encodable conformances, which would make JSONEncoder.encode() fail
// when called from CalibrationExporter's actor context.

private nonisolated struct CalibrationPayload: Encodable, Sendable {
    let runID: String
    let exportedAt: String
    let frameCount: Int
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
    let filteredAccelZ: Double
    let gpsSpeed: Double?

    nonisolated init(_ snapshot: FrameSnapshot) {
        self.timestamp = snapshot.timestamp
        self.pitch = snapshot.pitch
        self.roll = snapshot.roll
        self.yaw = snapshot.yaw
        self.userAccelX = snapshot.userAccelX
        self.userAccelY = snapshot.userAccelY
        self.userAccelZ = snapshot.userAccelZ
        self.filteredAccelZ = snapshot.filteredAccelZ
        self.gpsSpeed = snapshot.gpsSpeed
    }
}

// MARK: - Errors

enum CalibrationExportError: Error {
    case documentsDirectoryUnavailable
}
