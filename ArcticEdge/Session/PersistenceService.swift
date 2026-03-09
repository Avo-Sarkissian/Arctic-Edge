// PersistenceService.swift
// ArcticEdge
//
// @ModelActor actor providing batched, crash-safe writes from RingBuffer to SwiftData.
// Design invariants:
//   - autosaveEnabled is always false; every save is explicit via modelContext.save()
//   - flush() inserts all FrameRecord objects first, then calls save() ONCE (SESS-02)
//   - emergencyFlush() calls RingBuffer.drain() synchronously to avoid reentrancy loss
//   - Never inserts a single frame via individual save() calls

import SwiftData
import Foundation

@ModelActor
actor PersistenceService {

    // SESS-02: Batch insert 500 frames then save once.
    // modelContext.autosaveEnabled = false prevents any implicit saves during the loop.
    func flush(frames: [FilteredFrame]) throws {
        modelContext.autosaveEnabled = false
        for frame in frames {
            modelContext.insert(FrameRecord(from: frame))
        }
        try modelContext.save()
    }

    // SESS-04: Drain the ring buffer synchronously (no await), then flush.
    // RingBuffer.drain() is synchronous within its actor turn; calling it via
    // await is required because RingBuffer is an actor, but the drain() body
    // itself has no suspension points, so no frames can be appended during it.
    func emergencyFlush(ringBuffer: RingBuffer) async throws {
        let frames = await ringBuffer.drain()
        guard !frames.isEmpty else { return }
        try flush(frames: frames)
    }

    // Create a RunRecord at session start.
    func createRunRecord(runID: UUID, startTimestamp: Date) throws {
        modelContext.autosaveEnabled = false
        modelContext.insert(RunRecord(runID: runID, startTimestamp: startTimestamp))
        try modelContext.save()
    }

    // Stamp end timestamp on the matching RunRecord at session end.
    func finalizeRunRecord(runID: UUID, endTimestamp: Date) throws {
        modelContext.autosaveEnabled = false
        let descriptor = FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.runID == runID }
        )
        if let record = try modelContext.fetch(descriptor).first {
            record.endTimestamp = endTimestamp
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
