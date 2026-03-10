// PersistenceService.swift
// ArcticEdge
//
// @ModelActor actor providing batched, crash-safe writes from RingBuffer to SwiftData.
// Design invariants:
//   - autosaveEnabled is always false; every save is explicit via modelContext.save()
//   - flushWithGPS() inserts all FrameRecord objects first, then calls save() ONCE (SESS-02)
//   - flush() and emergencyFlush() delegate to flushWithGPS for consistency
//   - emergencyFlush() calls RingBuffer.drain() synchronously to avoid reentrancy loss
//   - Never inserts a single frame via individual save() calls

import SwiftData
import Foundation

@ModelActor
actor PersistenceService {

    // Phase 3: GPS-aware batch insert. All frames in the batch receive the same GPS speed
    // snapshot taken at drain time. Called by AppModel.startPeriodicFlush (plan 03-06).
    func flushWithGPS(frames: [FilteredFrame], gpsSpeed: Double?) throws {
        modelContext.autosaveEnabled = false
        for frame in frames {
            let record = FrameRecord(from: frame)
            record.gpsSpeed = gpsSpeed
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    // SESS-02: Backward-compatible batch insert. Delegates to flushWithGPS with nil speed.
    func flush(frames: [FilteredFrame]) throws {
        try flushWithGPS(frames: frames, gpsSpeed: nil)
    }

    // SESS-04: Drain the ring buffer synchronously (no await), then flush.
    // RingBuffer.drain() is synchronous within its actor turn; calling it via
    // await is required because RingBuffer is an actor, but the drain() body
    // itself has no suspension points, so no frames can be appended during it.
    // Delegates to flushWithGPS with nil gpsSpeed — no fresh GPS at emergency time.
    func emergencyFlush(ringBuffer: RingBuffer) async throws {
        let frames = await ringBuffer.drain()
        guard !frames.isEmpty else { return }
        try flushWithGPS(frames: frames, gpsSpeed: nil)
    }

    // Create a RunRecord at session start.
    func createRunRecord(runID: UUID, startTimestamp: Date) throws {
        modelContext.autosaveEnabled = false
        modelContext.insert(RunRecord(runID: runID, startTimestamp: startTimestamp))
        try modelContext.save()
    }

    // Stamp end timestamp and optional analytics stats on the matching RunRecord at session end.
    // Stats are computed by PostRunViewModel at query time; pass nil if not yet available.
    func finalizeRunRecord(runID: UUID, endTimestamp: Date,
                           topSpeed: Double? = nil, avgSpeed: Double? = nil,
                           verticalDrop: Double? = nil, distanceMeters: Double? = nil,
                           resortName: String? = nil) throws {
        modelContext.autosaveEnabled = false
        let descriptor = FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.runID == runID }
        )
        if let record = try modelContext.fetch(descriptor).first {
            record.endTimestamp = endTimestamp
            record.topSpeed = topSpeed
            record.avgSpeed = avgSpeed
            record.verticalDrop = verticalDrop
            record.distanceMeters = distanceMeters
            record.resortName = resortName
            try modelContext.save()
        }
    }

    // Phase 3: Generic fetch for ViewModel queries.
    func fetchRunRecords(descriptor: FetchDescriptor<RunRecord>) throws -> [RunRecord] {
        modelContext.autosaveEnabled = false
        return try modelContext.fetch(descriptor)
    }

    func fetchFrameRecords(descriptor: FetchDescriptor<FrameRecord>) throws -> [FrameRecord] {
        modelContext.autosaveEnabled = false
        return try modelContext.fetch(descriptor)
    }

    // Phase 3: Sendable-safe ViewModel helpers.
    // @Model types (FrameRecord, RunRecord) are not Sendable across actor boundaries under
    // Swift 6 strict concurrency. These methods extract only the needed primitive values
    // within the @ModelActor context and return Sendable value types to @MainActor callers.

    // Returns frame data for a given runID, sorted by timestamp.
    func fetchFrameDataForRun(runID: UUID) throws -> [FrameSnapshot] {
        modelContext.autosaveEnabled = false
        let descriptor = FetchDescriptor<FrameRecord>(
            predicate: #Predicate { $0.runID == runID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return try modelContext.fetch(descriptor).map { FrameSnapshot(from: $0) }
    }

    // Returns run metadata for a given runID.
    func fetchRunSnapshot(runID: UUID) throws -> RunSnapshot? {
        modelContext.autosaveEnabled = false
        let descriptor = FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.runID == runID }
        )
        return try modelContext.fetch(descriptor).first.map { RunSnapshot(from: $0) }
    }

    // Returns session aggregates: all completed (non-orphaned) runs.
    func fetchCompletedRunSnapshots() throws -> [RunSnapshot] {
        modelContext.autosaveEnabled = false
        let descriptor = FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.endTimestamp != nil && $0.isOrphaned == false },
            sortBy: [SortDescriptor(\.startTimestamp)]
        )
        return try modelContext.fetch(descriptor).map { RunSnapshot(from: $0) }
    }

    // History pagination: returns completed, non-orphaned runs sorted by startTimestamp descending.
    // Returns RunSnapshot (Sendable) array — safe to cross @ModelActor -> @MainActor boundary.
    func fetchRunHistory(offset: Int, limit: Int) throws -> [RunSnapshot] {
        modelContext.autosaveEnabled = false
        var descriptor = FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.endTimestamp != nil && $0.isOrphaned == false },
            sortBy: [SortDescriptor(\.startTimestamp, order: .reverse)]
        )
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map { RunSnapshot(from: $0) }
    }

    // Geocode cache write: stores the resolved resort name on an existing RunRecord.
    func updateResortName(runID: UUID, resortName: String) throws {
        modelContext.autosaveEnabled = false
        let descriptor = FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.runID == runID }
        )
        if let record = try modelContext.fetch(descriptor).first {
            record.resortName = resortName
            try modelContext.save()
        }
    }

    // SESS-05 orphan recovery: mark any open RunRecord for this run as orphaned.
    func markOrphanedRunRecord(runID: UUID) throws {
        modelContext.autosaveEnabled = false
        let descriptor = FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.runID == runID }
        )
        if let record = try modelContext.fetch(descriptor).first {
            record.isOrphaned = true
            try modelContext.save()
        }
    }

    // SESS-05 orphan recovery: find all open (no endTimestamp, not already orphaned) RunRecords.
    func fetchOpenRunIDs() throws -> [UUID] {
        let descriptor = FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.endTimestamp == nil && $0.isOrphaned == false }
        )
        return try modelContext.fetch(descriptor).map { $0.runID }
    }
}
