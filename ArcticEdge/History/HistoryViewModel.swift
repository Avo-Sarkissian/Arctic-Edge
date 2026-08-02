// HistoryViewModel.swift
// ArcticEdge
//
// @Observable @MainActor view model for RunHistoryView.
// Paginates RunSnapshot via PersistenceService.fetchRunHistory(offset:limit:).
// Groups runs by calendar day for section headers.
// Geocodes resort name once per run (stored in RunRecord.resortName via PersistenceService).
//
// Reverse geocoding uses MapKit's MKReverseGeocodingRequest (CLGeocoder is
// deprecated as of iOS 26). Rate limit defense:
//   - Skip runs that already have a cached resortName.
//   - Skip runs with no stored coordinate: there is nothing to resolve.
//   - One request at a time, and the result is persisted so it never repeats.

import Foundation
import SwiftData
import CoreLocation
import MapKit

// MARK: - Value types

nonisolated struct RunRow: Sendable, Identifiable {
    let id: UUID          // runID
    let runID: UUID
    let startTimestamp: Date
    let topSpeed: Double?
    let verticalDrop: Double?
    let duration: TimeInterval
    let resortName: String?
    let carvingScore: Double?
    let latitude: Double?
    let longitude: Double?
}

nonisolated struct DayGroup: Identifiable {
    let id: Date          // day start (Calendar.current.startOfDay)
    let date: Date
    let resortName: String
    let runCount: Int
    /// nil when no run that day measured vertical, so the header shows a dash
    /// rather than claiming a zero-metre day.
    let totalVertical: Double?
    /// Mean carving score across the day's scored runs. nil when none scored.
    let averageScore: Double?
    let runs: [RunRow]
}

// MARK: - HistoryViewModel

@Observable
@MainActor
final class HistoryViewModel {

    private(set) var dayGroups: [DayGroup] = []
    private(set) var isLoading: Bool = false
    private(set) var hasMore: Bool = true

    let pageSize: Int
    private(set) var loadedCount: Int = 0
    private var allRows: [RunRow] = []

    // Runs already attempted this session, so a scrolling list does not fire
    // repeat requests for a location that resolved to nothing.
    private var geocodeAttempted: Set<UUID> = []

    init(pageSize: Int = 50) {
        self.pageSize = pageSize
    }

    // MARK: - Pagination

    func fetchNextPage(persistenceService: any PersistenceServiceProtocol) async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }

        let currentOffset = loadedCount
        // Look-ahead: fetch pageSize + 1 items to detect end-of-data without an extra round-trip.
        let fetched = (try? await persistenceService.fetchRunHistory(offset: currentOffset, limit: pageSize + 1)) ?? []
        hasMore = fetched.count > pageSize
        // Display at most pageSize items.
        let snapshots = Array(fetched.prefix(pageSize))

        let newRows: [RunRow] = snapshots.map { snap in
            let duration: TimeInterval
            if let end = snap.endTimestamp {
                duration = end.timeIntervalSince(snap.startTimestamp)
            } else {
                duration = 0
            }
            return RunRow(
                id: snap.runID,
                runID: snap.runID,
                startTimestamp: snap.startTimestamp,
                topSpeed: snap.topSpeed,
                verticalDrop: snap.verticalDrop,
                duration: duration,
                resortName: snap.resortName,
                carvingScore: snap.carvingScore,
                latitude: snap.latitude,
                longitude: snap.longitude
            )
        }

        loadedCount += newRows.count
        allRows.append(contentsOf: newRows)
        rebuildDayGroups()
    }

    // MARK: - Day grouping

    private func rebuildDayGroups() {
        let calendar = Calendar.current
        var grouped: [Date: [RunRow]] = [:]
        for row in allRows {
            let dayStart = calendar.startOfDay(for: row.startTimestamp)
            grouped[dayStart, default: []].append(row)
        }
        dayGroups = grouped.keys.sorted(by: >).map { day in
            let runs = grouped[day]!.sorted { $0.startTimestamp < $1.startTimestamp }
            let verticals = runs.compactMap { $0.verticalDrop }
            let scores = runs.compactMap { $0.carvingScore }
            // The first resolved name wins; runs before geocoding completes fall
            // back to a neutral label rather than inventing a resort.
            let resort = runs.compactMap { $0.resortName }.first ?? "Unnamed mountain"
            return DayGroup(
                id: day,
                date: day,
                resortName: resort,
                runCount: runs.count,
                totalVertical: verticals.isEmpty ? nil : verticals.reduce(0, +),
                averageScore: scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count),
                runs: runs
            )
        }
    }

    // MARK: - Geocoding

    // Resolves a resort name for a run from the coordinate captured while it was
    // recorded. Persists the result so it is looked up at most once per run.
    //
    // This is what makes HIST-02 real. The method previously required a caller to
    // supply a coordinate, no caller existed, and no coordinate was ever stored,
    // so every history row read the same placeholder forever.
    func geocodeIfNeeded(
        runRow: RunRow,
        persistenceService: any PersistenceServiceProtocol
    ) async {
        guard runRow.resortName == nil else { return }          // already cached
        guard !geocodeAttempted.contains(runRow.runID) else { return }
        guard let latitude = runRow.latitude, let longitude = runRow.longitude else { return }
        geocodeAttempted.insert(runRow.runID)

        let location = CLLocation(latitude: latitude, longitude: longitude)
        let name = await reverseGeocode(location: location)
        guard let name else { return }

        try? await persistenceService.updateResortName(runID: runRow.runID, resortName: name)

        // Update the in-memory allRows and rebuild groups to reflect the cached name.
        if let idx = allRows.firstIndex(where: { $0.runID == runRow.runID }) {
            let old = allRows[idx]
            allRows[idx] = RunRow(
                id: old.id,
                runID: old.runID,
                startTimestamp: old.startTimestamp,
                topSpeed: old.topSpeed,
                verticalDrop: old.verticalDrop,
                duration: old.duration,
                resortName: name,
                carvingScore: old.carvingScore,
                latitude: old.latitude,
                longitude: old.longitude
            )
            rebuildDayGroups()
        }
    }

    // MARK: - Resort name extraction

    /// MapKit reverse geocode. Returns nil when nothing resolves, so the caller
    /// leaves the name unset and can retry on a later launch.
    private func reverseGeocode(location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        guard let items = try? await request.mapItems, let item = items.first else { return nil }
        return resortNameFrom(name: item.name, locality: item.address?.shortAddress)
    }

    // Resort name priority: name (non-nil, non-numeric) > locality > fallback.
    // Overload accepting (name: String?, locality: String?) for unit tests.
    func resortNameFrom(name: String?, locality: String?) -> String {
        if let n = name, !n.isEmpty, !n.first!.isNumber { return n }
        if let l = locality, !l.isEmpty { return l }
        return "Unnamed mountain"
    }
}
