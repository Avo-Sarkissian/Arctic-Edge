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

    // Phase 3: GPS-aware batch insert. All frames in the batch receive the same GPS
    // fix snapshot taken at drain time. Called by AppModel.startPeriodicFlush.
    // The fix's accuracy travels with it so downstream stats can reject bad samples.
    func flushWithGPS(frames: [FilteredFrame], fix: GPSFix?, altitude: Double? = nil) throws {
        modelContext.autosaveEnabled = false
        // One boot anchor for the whole batch so every frame's wall clock is
        // derived from the same estimate.
        let uptimeClock = UptimeClock()
        for frame in frames {
            let record = FrameRecord(from: frame)
            record.gpsSpeed = fix?.speed
            record.gpsHorizontalAccuracy = fix?.horizontalAccuracy
            record.gpsSpeedAccuracy = fix?.speedAccuracy
            record.relativeAltitude = altitude
            record.wallClock = uptimeClock.date(forUptime: frame.timestamp)
            modelContext.insert(record)
        }
        try modelContext.save()
    }

    // Convenience overload retained for callers that only have a speed scalar.
    func flushWithGPS(frames: [FilteredFrame], gpsSpeed: Double?) throws {
        let fix = gpsSpeed.map { GPSFix(speed: $0, horizontalAccuracy: nil, speedAccuracy: nil) }
        try flushWithGPS(frames: frames, fix: fix)
    }

    // SESS-02: Backward-compatible batch insert. Delegates to flushWithGPS with no fix.
    func flush(frames: [FilteredFrame]) throws {
        try flushWithGPS(frames: frames, fix: nil)
    }

    // Re-stamps frames captured in an uptime window onto a run. The skiing onset
    // window is persisted before the classifier confirms the run, so those frames
    // carry a throwaway id and would otherwise be missing from the run entirely.
    func retagFrames(fromUptime: TimeInterval, toUptime: TimeInterval, runID: UUID) throws {
        modelContext.autosaveEnabled = false
        let descriptor = FetchDescriptor<FrameRecord>(
            predicate: #Predicate { $0.timestamp >= fromUptime && $0.timestamp <= toUptime }
        )
        let records = try modelContext.fetch(descriptor)
        guard !records.isEmpty else { return }
        for record in records { record.runID = runID }
        try modelContext.save()
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
    // Passing nil for a stat LEAVES THE EXISTING VALUE ALONE. It previously
    // overwrote with nil, so a later stats pass could be silently erased by any
    // subsequent finalize, and every history row stayed blank.
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
            if let topSpeed { record.topSpeed = topSpeed }
            if let avgSpeed { record.avgSpeed = avgSpeed }
            if let verticalDrop { record.verticalDrop = verticalDrop }
            if let distanceMeters { record.distanceMeters = distanceMeters }
            if let resortName { record.resortName = resortName }
            try modelContext.save()
        }
    }

    // Writes the per-run analytics computed at finalization. These used to be
    // calculated in the post-run view model and never persisted at all, so every
    // history row rendered a dash and every day total summed to zero.
    func updateRunStats(
        runID: UUID,
        topSpeed: Double?,
        avgSpeed: Double?,
        verticalDrop: Double?,
        distanceMeters: Double?
    ) throws {
        modelContext.autosaveEnabled = false
        let descriptor = FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.runID == runID }
        )
        guard let record = try modelContext.fetch(descriptor).first else { return }
        record.topSpeed = topSpeed
        record.avgSpeed = avgSpeed
        record.verticalDrop = verticalDrop
        record.distanceMeters = distanceMeters
        try modelContext.save()
    }

    // Stores the coordinate a run started at so history can reverse geocode a
    // resort name later. Without it, geocoding had no input and every row read
    // "Mountain Resort" forever.
    func updateRunCoordinate(runID: UUID, latitude: Double, longitude: Double) throws {
        modelContext.autosaveEnabled = false
        let descriptor = FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.runID == runID }
        )
        guard let record = try modelContext.fetch(descriptor).first else { return }
        record.latitude = latitude
        record.longitude = longitude
        try modelContext.save()
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

    // Write the computed carving score (and its model version) onto an
    // existing RunRecord. Computed post-run by PostRunViewModel.
    func updateCarvingScore(runID: UUID, score: Double, version: String) throws {
        modelContext.autosaveEnabled = false
        let descriptor = FetchDescriptor<RunRecord>(
            predicate: #Predicate { $0.runID == runID }
        )
        if let record = try modelContext.fetch(descriptor).first {
            record.carvingScore = score
            record.carvingScoreVersion = version
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

    // MARK: - Retention

    /// Deletes raw frames older than the retention window, and every frame that
    /// belongs to no RunRecord regardless of age.
    ///
    /// Frames land at 100 Hz with no bound: roughly two million rows for a single
    /// six hour day, tens of millions across a season. Runs, their stats, and
    /// their carving scores are tiny and are always kept; only the raw IMU stream
    /// behind them expires. Frames captured between runs (on the lift) belong to
    /// no run and are never read by anything, so they go immediately.
    ///
    /// Returns the number of frames deleted.
    @discardableResult
    func pruneFrames(olderThan cutoff: Date, keepingRunIDs liveRunIDs: Set<UUID>) throws -> Int {
        modelContext.autosaveEnabled = false

        // Every runID that still has a RunRecord. Frames outside this set are orphans.
        let runDescriptor = FetchDescriptor<RunRecord>()
        var knownRunIDs = Set(try modelContext.fetch(runDescriptor).map { $0.runID })
        knownRunIDs.formUnion(liveRunIDs)

        let frameDescriptor = FetchDescriptor<FrameRecord>()
        let frames = try modelContext.fetch(frameDescriptor)

        var deleted = 0
        for frame in frames {
            let isOrphan = !knownRunIDs.contains(frame.runID)
            // A frame with no wall clock predates the field; fall back to keeping it
            // unless it is orphaned, so pre-migration data is not deleted by surprise.
            let isExpired = (frame.wallClock.map { $0 < cutoff }) ?? false
            guard isOrphan || isExpired else { continue }
            modelContext.delete(frame)
            deleted += 1
        }
        if deleted > 0 { try modelContext.save() }
        return deleted
    }

    /// Total FrameRecord count. Used by diagnostics and the storage readout.
    func frameCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<FrameRecord>())
    }

    /// Deletes every run and frame. Backs the user-facing "delete all data" action.
    func deleteAllData() throws {
        modelContext.autosaveEnabled = false
        try modelContext.delete(model: FrameRecord.self)
        try modelContext.delete(model: RunRecord.self)
        try modelContext.save()
    }
}
