// MockPersistenceService.swift
// ArcticEdgeTests/Helpers
//
// Shared test double for PersistenceServiceProtocol.
// Used by PostRunViewModelTests and HistoryViewModelTests in Phase 3.
//
// This is DISTINCT from the local MockPersistenceService in ActivityClassifierTests.swift,
// which only exercises ActivityClassifier's createRunRecord/finalizeRunRecord path.
// This shared version exposes injectable state (storedRunRecords, storedFrameRecords)
// so ViewModel tests can prepopulate fetch results.

import SwiftData
import Foundation
@testable import ArcticEdge

actor MockPersistenceService: PersistenceServiceProtocol {

    // MARK: - Injectable state for ViewModel tests

    /// Run records returned by fetchRunRecords regardless of descriptor predicate.
    /// Prepopulate via injectRunRecords(_:) before calling the ViewModel under test.
    private(set) var storedRunRecords: [RunRecord] = []

    /// Frame records returned by fetchFrameRecords regardless of descriptor predicate.
    /// Prepopulate via injectFrameRecords(_:) before calling the ViewModel under test.
    private(set) var storedFrameRecords: [FrameRecord] = []

    /// Call records for assertion in tests.
    private(set) var createCalls: [(runID: UUID, startTimestamp: Date)] = []
    private(set) var finalizeCalls: [(runID: UUID, endTimestamp: Date)] = []

    // MARK: - Injectable helpers

    func injectRunRecords(_ records: [RunRecord]) {
        storedRunRecords = records
    }

    func injectFrameRecords(_ records: [FrameRecord]) {
        storedFrameRecords = records
    }

    // MARK: - PersistenceServiceProtocol — existing requirements

    func createRunRecord(runID: UUID, startTimestamp: Date) throws {
        createCalls.append((runID: runID, startTimestamp: startTimestamp))
    }

    func finalizeRunRecord(
        runID: UUID, endTimestamp: Date,
        topSpeed: Double?, avgSpeed: Double?,
        verticalDrop: Double?, distanceMeters: Double?,
        resortName: String?
    ) throws {
        finalizeCalls.append((runID: runID, endTimestamp: endTimestamp))
    }

    // MARK: - PersistenceServiceProtocol — Phase 3 fetch methods
    // Protocol requirement added in plan 03-02.
    // Returns injected records; descriptor predicate/sort is intentionally ignored in tests.

    func fetchRunRecords(descriptor: FetchDescriptor<RunRecord>) async throws -> [RunRecord] {
        storedRunRecords
    }

    func fetchFrameRecords(descriptor: FetchDescriptor<FrameRecord>) async throws -> [FrameRecord] {
        storedFrameRecords
    }

    // MARK: - Phase 3 additional stub
    // emergencyFlush is referenced by plan 03-02 but not yet on the protocol.
    // Kept here for forward compatibility with plan 03-06.
    // Protocol requirement added in plan 03-06.
    func emergencyFlush(ringBuffer: RingBuffer) async throws {}
}
