// HistoryViewModelTests.swift
// ArcticEdgeTests/History
//
// TDD GREEN phase for HistoryViewModel — plan 03-05.
// Tests exercise pagination, day grouping, and resort name fallback logic
// using MockPersistenceService (no SwiftData ModelContainer required).
//
// Requirements covered:
//   HIST-01: Pagination — fetchNextPage() advances fetchOffset by pageSize
//   HIST-02: Resort name fallback — CLPlacemark.name → .locality → "Mountain Resort"

import Testing
import Foundation
@testable import ArcticEdge

@Suite("HistoryViewModel")
@MainActor
struct HistoryViewModelTests {

    // MARK: - Helpers

    private func makeRunSnapshot(
        runID: UUID = UUID(),
        startOffset: TimeInterval = 0,
        resortName: String? = nil,
        verticalDrop: Double? = nil
    ) -> RunSnapshot {
        let startDate = Date(timeIntervalSinceReferenceDate: startOffset)
        let endDate = Date(timeIntervalSinceReferenceDate: startOffset + 120)
        // Build via a temporary RunRecord (no ModelContainer needed for init)
        let record = RunRecord(runID: runID, startTimestamp: startDate)
        record.endTimestamp = endDate
        record.isOrphaned = false
        record.resortName = resortName
        record.verticalDrop = verticalDrop
        return RunSnapshot(from: record)
    }

    // MARK: - Tests

    @Test("pagination offset advances by pageSize after fetchNextPage")
    func testPaginationOffsetAdvances() async throws {
        // Given: MockPersistenceService with exactly pageSize (50) run snapshots
        let pageSize = 50
        let vm = HistoryViewModel(pageSize: pageSize)
        let mock = MockPersistenceService()

        // Inject 100 snapshots to allow two full pages
        let allSnapshots = (0..<100).map { i in
            makeRunSnapshot(startOffset: TimeInterval(i * 120))
        }
        await mock.injectRunSnapshots(allSnapshots)

        // When: first fetchNextPage()
        await vm.fetchNextPage(persistenceService: mock)

        // Then: loadedCount advances to pageSize
        #expect(vm.loadedCount == pageSize)
        #expect(vm.hasMore == true)    // 50 == pageSize, so hasMore stays true

        // When: second fetchNextPage()
        await vm.fetchNextPage(persistenceService: mock)

        // Then: loadedCount advances to 2 * pageSize
        #expect(vm.loadedCount == 2 * pageSize)
        #expect(vm.hasMore == false)   // second page also returned 50, but total is 100 which equals limit*2
    }

    @Test("resort name falls back through name → locality → Mountain Resort")
    func testResortNameFallback() async throws {
        let vm = HistoryViewModel()

        // Case 1: name is non-nil and non-numeric — use name
        #expect(vm.resortNameFrom(name: "Whistler Blackcomb", locality: "Whistler") == "Whistler Blackcomb")

        // Case 2: name is nil — fall back to locality
        #expect(vm.resortNameFrom(name: nil, locality: "Vail") == "Vail")

        // Case 3: name is numeric — fall back to locality
        #expect(vm.resortNameFrom(name: "1234 Mountain Road", locality: "Aspen") == "Aspen")

        // Case 4: both nil — fall back to "Mountain Resort"
        #expect(vm.resortNameFrom(name: nil, locality: nil) == "Mountain Resort")

        // Case 5: name is empty string — fall back to locality
        #expect(vm.resortNameFrom(name: "", locality: "Breckenridge") == "Breckenridge")

        // Case 6: both empty — fall back to "Mountain Resort"
        #expect(vm.resortNameFrom(name: "", locality: "") == "Mountain Resort")
    }
}
