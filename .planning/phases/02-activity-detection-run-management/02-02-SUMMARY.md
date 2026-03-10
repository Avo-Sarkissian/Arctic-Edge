---
phase: 02-activity-detection-run-management
plan: 02
subsystem: activity-detection
tags: [swift, actor, state-machine, hysteresis, core-motion, tdd, sendable, strict-concurrency]

# Dependency graph
requires:
  - phase: 02-activity-detection-run-management
    plan: 01
    provides: GPSManagerProtocol, ActivityManagerProtocol, MockGPSManager, MockActivityManager, 10 RED ActivityClassifier stubs

provides:
  - ActivityClassifier actor: hysteresis state machine (idle/chairlift/skiing)
  - PersistenceServiceProtocol for mock injection without SwiftData
  - ClassifierState nonisolated enum (Sendable, Equatable)
  - TestClock actor for deterministic clock injection in strict-concurrency tests
  - 10 GREEN tests covering DETC-01, DETC-02, DETC-03

affects:
  - Any consumer of ActivityClassifier (AppModel, session management layer)
  - Phase 3+ UI layers that display current ClassifierState

# Tech tracking
tech-stack:
  added: []
  patterns:
    - Clock injection via @escaping @Sendable () -> Date for deterministic actor time in tests
    - TestClock actor with nonisolated(unsafe) var cache for synchronous reads from @Sendable closure
    - PersistenceServiceProtocol existential (any PersistenceServiceProtocol) for mock injection without @ModelActor
    - Buffered onset window: pendingFrames held during hysteresis window to recover accurate startTimestamp
    - Undetached Task inside actor for persistence calls that must not block processFrame

key-files:
  created:
    - ArcticEdge/Activity/ActivityClassifier.swift
  modified:
    - ArcticEdgeTests/Activity/ActivityClassifierTests.swift

key-decisions:
  - "PersistenceServiceProtocol protocol bridges @ModelActor PersistenceService with test MockPersistenceService — existential (any PersistenceServiceProtocol) stored as actor property avoids SwiftData ModelContainer requirement in unit tests"
  - "TestClock actor with nonisolated(unsafe) var cache: actor isolation prevents synchronous reads from @Sendable clock closure; unsafeCurrentDate is written only via actor-isolated advance() methods, which is safe because tests drive it serially"
  - "chairliftSignalActive() requires all three signals simultaneously — no partial credit — enforcing DETC-01 must_have 'Two of three is insufficient'"
  - "GPS blackout tolerance scoped to .chairlift state: speedInLiftRange waived only when state == .chairlift (not .skiing) to prevent chairlift-blackout from also suppressing skiing-end signal"
  - "hypot() preferred over manual squareRoot() for g-force magnitude — cleaner, same semantics, no numerical difference"

patterns-established:
  - "Protocol extension conformance: extension PersistenceService: PersistenceServiceProtocol {} — retroactive conformance for @ModelActor without modifying original file"
  - "Actor test helpers as internal methods: setState/setGPS/setActivity/setPersistence are internal (not private) so @testable imports can drive state without real hardware"
  - "Undetached Task for async persistence in sync actor method: let service = persistence; Task { try? await service?.createRunRecord(...) } — captures persistence value not actor self"

requirements-completed: [DETC-01, DETC-02, DETC-03]

# Metrics
duration: 11min
completed: 2026-03-10
---

# Phase 2 Plan 02: ActivityClassifier Summary

**ActivityClassifier actor with 3s/2s hysteresis onset/end windows, GPS blackout tolerance, and RunRecord lifecycle — 10/10 DETC tests GREEN under SWIFT_STRICT_CONCURRENCY = complete**

## Performance

- **Duration:** 11 min
- **Started:** 2026-03-10T01:18:04Z
- **Completed:** 2026-03-10T01:28:44Z
- **Tasks:** 3 (RED confirmation, GREEN implementation, REFACTOR)
- **Files modified:** 2 (1 created, 1 updated)

## Accomplishments

- ActivityClassifier actor implementing the full hysteresis state machine: skiingSignalActive() + chairliftSignalActive() predicates, 3s skiing onset window, 2s run-end window
- PersistenceServiceProtocol enabling MockPersistenceService test double without requiring a SwiftData ModelContainer
- TestClock actor with nonisolated(unsafe) cache for deterministic clock injection under strict concurrency — no Task.sleep required in any test

## Task Commits

1. **RED: Confirm 10 stubs are RED** — no commit needed (stubs from 02-01 already committed in 52a558a)
2. **GREEN: ActivityClassifier implementation** - `f50d3a7` (feat)
3. **REFACTOR: Clean up** - `9113d28` (refactor)

## Files Created/Modified

- `ArcticEdge/Activity/ActivityClassifier.swift` — ClassifierState enum, PersistenceServiceProtocol, ActivityClassifier actor, PersistenceService retroactive conformance
- `ArcticEdgeTests/Activity/ActivityClassifierTests.swift` — MockPersistenceService, TestClock, 10 GREEN tests replacing all #expect(Bool(false)) stubs

## Decisions Made

- **PersistenceServiceProtocol existential:** PersistenceService is `@ModelActor` and cannot be constructed without a ModelContainer. Rather than forcing tests to bootstrap SwiftData, a minimal `PersistenceServiceProtocol: Actor` with `createRunRecord` and `finalizeRunRecord` lets MockPersistenceService conform and be injected via `any PersistenceServiceProtocol`.
- **TestClock pattern:** Swift 6 strict concurrency rejects capturing a mutable `var tick: Date` in a `@Sendable` closure. TestClock actor owns the time value; `nonisolated(unsafe) var unsafeCurrentDate` is the synchronous cache synchronized by actor-isolated `syncCache()`. Tests call `await clock.advance(to:)` then `await clock.syncCache()` before each frame injection.
- **GPS blackout scoped to chairlift state:** `chairliftSignalActive()` waives the speed-in-lift-range gate only when `state == .chairlift`. If the classifier is in `.skiing` and GPS drops, the GPS gate is NOT waived for the run-end check — this prevents a GPS drop from accidentally keeping the system in skiing state during an actual chairlift ride.
- **hypot() for g-force magnitude:** Replaced manual `(x*x + y*y + z*z).squareRoot()` with `hypot(x, hypot(y, z))` during refactor — same semantics, no numerical change, more idiomatic.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] ClassifierState Equatable conformance required nonisolated**
- **Found during:** GREEN build (first compilation attempt)
- **Issue:** `ClassifierState` enum without `nonisolated` was inferred to have MainActor isolation under SWIFT_DEFAULT_ACTOR_ISOLATION, causing "main actor-isolated conformance of 'ClassifierState' to 'Equatable' cannot be used in actor-isolated context" at 3 callsites
- **Fix:** Added `nonisolated` to the enum declaration
- **Files modified:** ArcticEdge/Activity/ActivityClassifier.swift
- **Verification:** Build passed after change, all tests GREEN
- **Committed in:** f50d3a7 (GREEN commit)

**2. [Rule 1 - Bug] TestClock capture pattern required actor + nonisolated(unsafe)**
- **Found during:** Build-for-testing phase (before first test run)
- **Issue:** Plan specified `var tick = Date(...)` captured by `@Sendable` clock closure — Swift 6 rejects this with "reference to captured var 'tick' in concurrently-executing code" (9 errors, one per test)
- **Fix:** Created TestClock actor with `nonisolated(unsafe) var unsafeCurrentDate` that tests advance via `await clock.advance(to:)` + `await clock.syncCache()` before each frame injection
- **Files modified:** ArcticEdgeTests/Activity/ActivityClassifierTests.swift
- **Verification:** Build succeeded with 0 errors; all 10 tests GREEN
- **Committed in:** f50d3a7 (GREEN commit)

**3. [Rule 1 - Bug] Missing import CoreMotion after refactor**
- **Found during:** REFACTOR build
- **Issue:** Refactoring removed `import CoreMotion` from ActivityClassifier.swift, causing CMMotionActivityConfidence.low to be unavailable (2 errors)
- **Fix:** Re-added `import CoreMotion`
- **Files modified:** ArcticEdge/Activity/ActivityClassifier.swift
- **Verification:** Build passed, all 10 tests still GREEN
- **Committed in:** 9113d28 (REFACTOR commit)

---

**Total deviations:** 3 auto-fixed (Rule 1 — all bugs triggered by strict concurrency or import hygiene)
**Impact on plan:** All three were mechanical Swift 6 compliance issues. No logic changes. No scope creep.

## Issues Encountered

- Simulator destination `name=iPhone 16 Pro` from the plan template does not match the Xcode 16.x-installed simulators (project targets iOS 26.2). Used `id=14A2F3D0-9173-4109-9F68-BB08BD559069` (iPhone 17 Pro, iOS 26.2) — same workaround as 02-01.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- ActivityClassifier is fully implemented and all DETC-01/02/03 requirements are satisfied
- PersistenceServiceProtocol is established; any future persistence mock only needs to conform to two methods
- TestClock pattern is established for any future actor that needs injectable time
- Concern carried forward: CMMotionActivity.automotive chairlift heuristic is untested on real hardware — on-mountain calibration still required before treating as settled (tracked in STATE.md)

## Self-Check: PASSED

- FOUND: ArcticEdge/Activity/ActivityClassifier.swift
- FOUND: ArcticEdgeTests/Activity/ActivityClassifierTests.swift
- FOUND: .planning/phases/02-activity-detection-run-management/02-02-SUMMARY.md
- FOUND commit f50d3a7: feat(02-02): implement ActivityClassifier hysteresis state machine
- FOUND commit 9113d28: refactor(02-02): clean up ActivityClassifier
- 10/10 ActivityClassifierTests GREEN verified
- Zero compiler warnings under SWIFT_STRICT_CONCURRENCY = complete

---
*Phase: 02-activity-detection-run-management*
*Completed: 2026-03-10*
