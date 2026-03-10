// HistoryViewModelTests.swift
// ArcticEdgeTests/History
//
// TDD RED phase for HistoryViewModel — Wave 0 stubs.
// These tests define the contract for plan 03-05 (HistoryViewModel implementation).
//
// Requirements covered:
//   HIST-01: Pagination — fetchNextPage() advances FetchDescriptor fetchOffset by pageSize
//   HIST-02: Resort name fallback — CLPlacemark.name → .locality → "Mountain Resort"

import Testing
import Foundation
@testable import ArcticEdge

@Suite("HistoryViewModel")
struct HistoryViewModelTests {

    @Test("pagination offset advances by pageSize after fetchNextPage")
    func testPaginationOffsetAdvances() async throws {
        // STUB: will fail until HistoryViewModel exists (plan 03-05)
        // Behavior: After calling fetchNextPage() once on HistoryViewModel,
        // assert the next FetchDescriptor fetchOffset == pageSize (e.g., 50)
        Issue.record("HistoryViewModel does not exist yet — implement in plan 03-05")
        #expect(Bool(false))
    }

    @Test("resort name falls back through name → locality → Mountain Resort")
    func testResortNameFallback() async throws {
        // STUB: will fail until HistoryViewModel exists (plan 03-05)
        // Behavior: When CLPlacemark.name is nil, assert resort name falls back to
        // CLPlacemark.locality; when both nil, falls back to "Mountain Resort"
        Issue.record("HistoryViewModel does not exist yet — implement in plan 03-05")
        #expect(Bool(false))
    }
}
