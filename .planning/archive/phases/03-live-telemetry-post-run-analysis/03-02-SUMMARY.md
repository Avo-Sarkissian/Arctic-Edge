---
phase: 03-live-telemetry-post-run-analysis
plan: 02
subsystem: database
tags: [swiftdata, schema-migration, versioned-schema, persistence, gps]

# Dependency graph
requires:
  - phase: 01-motion-engine-and-session-foundation
    provides: PersistenceService @ModelActor, FrameRecord/RunRecord SwiftData models
  - phase: 02-activity-detection-run-management
    provides: ActivityClassifier, PersistenceServiceProtocol, GPS/Activity streams
provides:
  - RunRecord extended with topSpeed, avgSpeed, verticalDrop, distanceMeters, resortName (all Optional)
  - FrameRecord extended with gpsSpeed: Double? stamped at flush time
  - SchemaV2.swift with ArcticEdgeMigrationPlan (lightweight V1->V2)
  - PersistenceServiceProtocol extended with fetchRunRecords, fetchFrameRecords, updated finalizeRunRecord
  - PersistenceService.flushWithGPS(frames:gpsSpeed:) for GPS-aware batch inserts
affects: [03-03, 03-04, 03-05, 03-06]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Optional stored properties on @Model classes for lightweight SwiftData migration (no init parameter, no default)
    - VersionedSchema enum pair + SchemaMigrationPlan for forward-compatible schema evolution
    - flushWithGPS as canonical flush primitive; flush() and emergencyFlush() delegate to it
    - fetchRunRecords/fetchFrameRecords pass FetchDescriptor through to ModelContext for ViewModel-controlled queries

key-files:
  created:
    - ArcticEdge/Schema/SchemaV2.swift
  modified:
    - ArcticEdge/Schema/RunRecord.swift
    - ArcticEdge/Schema/FrameRecord.swift
    - ArcticEdge/Session/PersistenceService.swift
    - ArcticEdge/Activity/ActivityClassifier.swift
    - ArcticEdge/ArcticEdgeApp.swift
    - ArcticEdgeTests/Activity/ActivityClassifierTests.swift

key-decisions:
  - "nonisolated(unsafe) static var on SchemaV1/SchemaV2.versionIdentifier: Swift 6 strict concurrency rejects non-isolated global mutable state; nonisolated(unsafe) is correct here since these are effectively write-once enum namespace values"
  - "Optional RunRecord fields excluded from init() — SwiftData lightweight migration sets new columns to nil automatically; adding them to init would break the migration contract"
  - "flushWithGPS becomes canonical flush primitive; flush() and emergencyFlush() delegate to it — all frame inserts share one code path for GPS stamping"
  - "PersistenceServiceProtocol declares fetchRunRecords/fetchFrameRecords as async throws even though PersistenceService implements them as throws — synchronous throws satisfies async throws at conformance site, allowing MockPersistenceService to use async"
  - "finalizeRunRecord nil-passing for ActivityClassifier callers — stats are computed by PostRunViewModel at query time, not at run-boundary time; resortName geocodes in HistoryViewModel"

patterns-established:
  - "Canonical flush pattern: always call flushWithGPS; pass nil gpsSpeed when GPS state unavailable"
  - "Protocol fetch methods accept FetchDescriptor<T> so ViewModels own the predicate/sort/limit logic"
  - "All new @Model properties are Optional to guarantee lightweight migration compatibility"

requirements-completed: [ANLYS-02, ANLYS-03, HIST-01, HIST-02]

# Metrics
duration: 14min
completed: 2026-03-10
---

# Phase 03 Plan 02: Schema Migration & Persistence Layer Extension Summary

**SwiftData V1-to-V2 lightweight migration with 6 new Optional properties, ArcticEdgeMigrationPlan, flushWithGPS batch insert, and fetchRunRecords/fetchFrameRecords protocol extensions enabling all downstream Phase 3 ViewModels**

## Performance

- **Duration:** 14 min
- **Started:** 2026-03-10T20:03:27Z
- **Completed:** 2026-03-10T20:17:23Z
- **Tasks:** 2
- **Files modified:** 7 (6 modified, 1 created)

## Accomplishments

- Extended RunRecord with 5 Optional Phase 3 analytics properties (topSpeed, avgSpeed, verticalDrop, distanceMeters, resortName) using lightweight SwiftData migration
- Added gpsSpeed: Double? to FrameRecord for GPS-correlated frame data; stamped by flushWithGPS at batch drain time
- Created SchemaV2.swift with SchemaV1/SchemaV2 VersionedSchema pair and ArcticEdgeMigrationPlan; wired into ModelContainer in AppModel
- Extended PersistenceServiceProtocol and PersistenceService with fetchRunRecords, fetchFrameRecords, updated finalizeRunRecord signature, and flushWithGPS as the canonical flush primitive

## Task Commits

Each task was committed atomically:

1. **Task 1: Schema extension + VersionedSchema migration** - `31c04e1` (feat)
2. **Task 2: PersistenceService + PersistenceServiceProtocol extensions** - `a98692e` (feat, as Rule 3 fix within plan 03-01)

## Files Created/Modified

- `ArcticEdge/Schema/SchemaV2.swift` — SchemaV1, SchemaV2 VersionedSchema enums + ArcticEdgeMigrationPlan (lightweight V1->V2)
- `ArcticEdge/Schema/RunRecord.swift` — Added topSpeed, avgSpeed, verticalDrop, distanceMeters, resortName (all Optional)
- `ArcticEdge/Schema/FrameRecord.swift` — Added gpsSpeed: Double?
- `ArcticEdge/Session/PersistenceService.swift` — Added flushWithGPS, fetchRunRecords, fetchFrameRecords; updated finalizeRunRecord; flush/emergencyFlush delegate to flushWithGPS
- `ArcticEdge/Activity/ActivityClassifier.swift` — Updated PersistenceServiceProtocol with new methods; updated all finalizeRunRecord call sites to pass nil for optional stats; added import SwiftData
- `ArcticEdge/ArcticEdgeApp.swift` — ModelContainer wired with migrationPlan: ArcticEdgeMigrationPlan.self
- `ArcticEdgeTests/Activity/ActivityClassifierTests.swift` — Updated ClassifierMockPersistenceService to match new protocol signature

## Decisions Made

- `nonisolated(unsafe) static var` on VersionedSchema versionIdentifier properties: Swift 6 strict concurrency rejects global mutable state in nonisolated contexts; these are effectively write-once enum namespace values
- Optional RunRecord analytics fields excluded from init() parameter list: SwiftData lightweight migration sets new columns to nil at row expansion time; init inclusion would break the migration contract
- flushWithGPS as canonical primitive with flush() and emergencyFlush() delegating to it: ensures all frame inserts share one GPS-stamping code path

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] `static var versionIdentifier` strict concurrency violation**
- **Found during:** Task 1 (SchemaV2.swift creation)
- **Issue:** `static var versionIdentifier = Schema.Version(...)` on VersionedSchema enums is nonisolated global mutable state — build failed with "not concurrency-safe" error under SWIFT_STRICT_CONCURRENCY=complete
- **Fix:** Changed to `nonisolated(unsafe) static var` on both SchemaV1 and SchemaV2; these are write-once constants in practice
- **Files modified:** ArcticEdge/Schema/SchemaV2.swift
- **Verification:** Build succeeded after fix
- **Committed in:** 31c04e1

**2. [Rule 3 - Blocking] Task 2 changes committed by plan 03-01 as Rule 3 fix**
- **Found during:** Plan 03-01 ran concurrently; its PostRunViewModel stub needed the updated PersistenceServiceProtocol to compile
- **Issue:** PersistenceService.swift, ActivityClassifier.swift, and ActivityClassifierTests.swift changes from Task 2 were uncommitted when plan 03-01 started; 03-01 couldn't build without them
- **Fix:** Plan 03-01 applied a Rule 3 fix picking up all uncommitted Task 2 changes and committing them as part of `a98692e` with full attribution in commit message
- **Files modified:** ArcticEdge/Activity/ActivityClassifier.swift, ArcticEdge/Session/PersistenceService.swift, ArcticEdgeTests/Activity/ActivityClassifierTests.swift
- **Verification:** All Phase 1+2 tests pass; build succeeds
- **Committed in:** a98692e

---

**Total deviations:** 2 auto-fixed (1 build error, 1 cross-plan Rule 3 coordination)
**Impact on plan:** Both necessary. No scope creep. Task 2 content is fully committed and correct.

## Issues Encountered

- Swift 6 strict concurrency check rejects `static var` on VersionedSchema implementations — `nonisolated(unsafe)` is the correct pattern; SwiftData documentation examples use `static var` which generates warnings/errors under SWIFT_STRICT_CONCURRENCY=complete
- Plan 03-01 ran concurrently and committed Task 2 changes first; final state is identical to plan spec

## Next Phase Readiness

- Schema migration infrastructure complete; all downstream Phase 3 ViewModels (03-03 LiveViewModel, 03-04 PostRunViewModel, 03-05 HistoryViewModel) can now query RunRecord and FrameRecord with the new fields
- plan 03-06 (AppModel GPS flush) can call `flushWithGPS(frames:gpsSpeed:)` directly without modifying PersistenceService again
- All Phase 1 + 2 tests continue to pass; no regressions

---
*Phase: 03-live-telemetry-post-run-analysis*
*Completed: 2026-03-10*

## Self-Check: PASSED

- ArcticEdge/Schema/SchemaV2.swift: FOUND
- ArcticEdge/Schema/RunRecord.swift: FOUND
- ArcticEdge/Schema/FrameRecord.swift: FOUND
- ArcticEdge/Session/PersistenceService.swift: FOUND
- .planning/phases/03-live-telemetry-post-run-analysis/03-02-SUMMARY.md: FOUND
- commit 31c04e1 (Task 1 schema): FOUND
- commit a98692e (Task 2 persistence): FOUND
