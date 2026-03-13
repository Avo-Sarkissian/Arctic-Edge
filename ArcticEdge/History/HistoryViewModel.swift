// HistoryViewModel.swift
// ArcticEdge
//
// @Observable @MainActor view model for RunHistoryView.
// Paginates RunSnapshot via PersistenceService.fetchRunHistory(offset:limit:).
// Groups runs by calendar day for section headers.
// Geocodes resort name once per run (stored in RunRecord.resortName via PersistenceService).
//
// CLGeocoder rate limit defense:
//   - Check RunSnapshot.resortName before calling CLGeocoder.
//   - One shared CLGeocoder instance; sequential geocode calls (no concurrent).
//   - Persist result to RunRecord.resortName via PersistenceService.

import Foundation
import SwiftData
import CoreLocation

// MARK: - Value types

struct RunRow: Sendable, Identifiable {
    let id: UUID          // runID
    let runID: UUID
    let startTimestamp: Date
    let topSpeed: Double?
    let verticalDrop: Double?
    let duration: TimeInterval
    let resortName: String?
}

struct DayGroup: Identifiable {
    let id: Date          // day start (Calendar.current.startOfDay)
    let date: Date
    let resortName: String
    let runCount: Int
    let totalVertical: Double
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

    // Single shared geocoder — CLGeocoder is not thread-safe; keep on @MainActor.
    private let geocoder = CLGeocoder()

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
                resortName: snap.resortName
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
            let runs = grouped[day]!
            let totalVertical = runs.compactMap { $0.verticalDrop }.reduce(0, +)
            let resort = runs.first?.resortName ?? "Mountain Resort"
            return DayGroup(
                id: day,
                date: day,
                resortName: resort,
                runCount: runs.count,
                totalVertical: totalVertical,
                runs: runs
            )
        }
    }

    // MARK: - Geocoding

    // Geocode resort name for a run if not already cached in RunSnapshot.resortName.
    // Persists the result back to RunRecord.resortName via PersistenceService.
    // Safe to call from onAppear on individual rows — checks cache first.
    func geocodeIfNeeded(
        runRow: RunRow,
        coordinate: CLLocationCoordinate2D,
        persistenceService: any PersistenceServiceProtocol
    ) async {
        guard runRow.resortName == nil else { return }  // Already cached

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemark = try? await geocoder.reverseGeocode(location: location)
        let name = resortNameFrom(placemark: placemark)

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
                resortName: name
            )
            rebuildDayGroups()
        }
    }

    // MARK: - Resort name extraction

    // Resort name priority: name (non-nil, non-numeric) > locality > fallback.
    // Overload accepting (name: String?, locality: String?) for unit tests.
    func resortNameFrom(name: String?, locality: String?) -> String {
        if let n = name, !n.isEmpty, !n.first!.isNumber { return n }
        if let l = locality, !l.isEmpty { return l }
        return "Mountain Resort"
    }

    // CLPlacemark overload — thin wrapper over the testable (name:locality:) variant.
    func resortNameFrom(placemark: CLPlacemark?) -> String {
        resortNameFrom(name: placemark?.name, locality: placemark?.locality)
    }
}

// MARK: - CLGeocoder async extension

extension CLGeocoder {
    func reverseGeocode(location: CLLocation) async throws -> CLPlacemark? {
        try await withCheckedThrowingContinuation { continuation in
            reverseGeocodeLocation(location) { placemarks, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: placemarks?.first)
                }
            }
        }
    }
}
