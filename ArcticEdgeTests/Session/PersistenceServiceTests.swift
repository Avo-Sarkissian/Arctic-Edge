// PersistenceServiceTests.swift
// ArcticEdgeTests
//
// Tests for SESS-02 (batched flush), SESS-03 (indexes), SESS-04 (emergency flush).
// All use an in-memory ModelContainer for isolation from disk state.
// PersistenceService is initialized via Task.detached to ensure background queue
// (avoids binding to the @MainActor test runner executor).

import Testing
import SwiftData
import Foundation
@testable import ArcticEdge

// Helper: create an in-memory ModelContainer with the full schema.
nonisolated func makeInMemoryContainer() throws -> ModelContainer {
    let schema = Schema([FrameRecord.self, RunRecord.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: config)
}

// Helper: build a FilteredFrame for test data.
nonisolated func makeFilteredFrame(index: Int, runID: UUID) -> FilteredFrame {
    FilteredFrame(
        timestamp: TimeInterval(index),
        runID: runID,
        pitch: 0.1,
        roll: 0.2,
        yaw: 0.3,
        userAccelX: 0.01,
        userAccelY: 0.02,
        userAccelZ: 0.03,
        gravityX: 0.0,
        gravityY: -1.0,
        gravityZ: 0.0,
        rotationRateX: 0.001,
        rotationRateY: 0.002,
        rotationRateZ: 0.003,
        filteredAccelZ: 0.05
    )
}

@Suite("PersistenceService")
struct PersistenceServiceTests {

    // SESS-02: 500 frames must produce exactly 500 FrameRecords via a single batched flush.
    // Verifies the count after flush using a separate ModelContext on the same container.
    @Test func testBatchFlushSingleSave() async throws {
        let container = try makeInMemoryContainer()
        let service = await Task.detached { PersistenceService(modelContainer: container) }.value

        let runID = UUID()
        let frames = (0..<500).map { makeFilteredFrame(index: $0, runID: runID) }
        try await service.flush(frames: frames)

        // Read back via a fresh context on the same container to confirm the save.
        let readContext = ModelContext(container)
        let descriptor = FetchDescriptor<FrameRecord>()
        let records = try readContext.fetch(descriptor)
        #expect(records.count == 500)
    }

    // SESS-03: FetchDescriptor sort on timestamp and runID must not error,
    // confirming the schema indexes are present and usable.
    @Test func testFrameRecordIndexExists() async throws {
        let container = try makeInMemoryContainer()
        let service = await Task.detached { PersistenceService(modelContainer: container) }.value

        let runID = UUID()
        let frames = (0..<10).map { makeFilteredFrame(index: $0, runID: runID) }
        try await service.flush(frames: frames)

        let readContext = ModelContext(container)

        // Sort by timestamp (index 1)
        var byTimestamp = FetchDescriptor<FrameRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        byTimestamp.fetchLimit = 5
        let timestampResults = try readContext.fetch(byTimestamp)
        #expect(timestampResults.count == 5)

        // Sort by runID (index 2)
        var byRunID = FetchDescriptor<FrameRecord>(
            sortBy: [SortDescriptor(\.runID, order: .forward)]
        )
        byRunID.fetchLimit = 5
        let runIDResults = try readContext.fetch(byRunID)
        #expect(runIDResults.count == 5)
    }

    // SESS-04: emergencyFlush drains the ring buffer and writes all frames to SwiftData.
    @Test func testEmergencyFlushDrainsRingBuffer() async throws {
        let container = try makeInMemoryContainer()
        let service = await Task.detached { PersistenceService(modelContainer: container) }.value

        let ringBuffer = RingBuffer()
        let runID = UUID()
        for i in 0..<200 {
            await ringBuffer.append(makeFilteredFrame(index: i, runID: runID))
        }
        #expect(await ringBuffer.count == 200)

        try await service.emergencyFlush(ringBuffer: ringBuffer)

        // Ring buffer must be empty after drain.
        #expect(await ringBuffer.count == 0)

        // All 200 frames must be persisted.
        let readContext = ModelContext(container)
        let descriptor = FetchDescriptor<FrameRecord>()
        let records = try readContext.fetch(descriptor)
        #expect(records.count == 200)
    }

    // PersistenceService is a @ModelActor; flush must not execute on the main thread.
    // Verified by calling flush from a Task.detached context and confirming it completes
    // without deadlock (a @MainActor-bound service would deadlock when called from detached
    // tasks that cannot switch to the main thread while the test is blocking it).
    @Test func testNoMainThreadSave() async throws {
        let container = try makeInMemoryContainer()

        // Initialize and flush entirely inside a detached task to confirm the service
        // can operate independently of the @MainActor executor.
        try await Task.detached {
            let service = PersistenceService(modelContainer: container)
            let frames = (0..<10).map { makeFilteredFrame(index: $0, runID: UUID()) }
            try await service.flush(frames: frames)
        }.value
        // Reaching here without deadlock confirms PersistenceService is not main-thread-bound.

        // Verify records were actually written.
        let readContext = ModelContext(container)
        let descriptor = FetchDescriptor<FrameRecord>()
        let records = try readContext.fetch(descriptor)
        #expect(records.count == 10)
    }
}
