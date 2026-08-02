---
phase: 02-activity-detection-run-management
plan: 01
subsystem: activity-detection
tags: [swift, actors, core-location, core-motion, async-stream, tdd, sendable]

# Dependency graph
requires:
  - phase: 01-motion-engine-and-session-foundation
    provides: StreamBroadcaster pattern for UUID-keyed async continuations

provides:
  - GPSManager actor with CLLocationUpdate.liveUpdates(.otherNavigation) stream
  - ActivityManager actor bridging CMMotionActivityManager via ActivitySnapshot
  - GPSManagerProtocol and ActivityManagerProtocol for mock injection
  - MockGPSManager and MockActivityManager test doubles
  - 10 ActivityClassifier Wave 0 test stubs (all RED, all compilable)

affects:
  - 02-02-activity-classifier (consumes GPSManagerProtocol, ActivityManagerProtocol, MockGPSManager, MockActivityManager)

# Tech tracking
tech-stack:
  added: [CLLocationUpdate.liveUpdates, CLBackgroundActivitySession, CMMotionActivityManager, CMMotionActivityConfidence]
  patterns:
    - UUID-keyed AsyncStream continuation fan-out (established in StreamBroadcaster, extended here)
    - nonisolated makeStream() on actor protocol to avoid MainActor inference
    - Primitive extraction before async boundary crossing (CMDeviceMotion pattern extended to CMMotionActivity via ActivitySnapshot)
    - isActivityAvailable() guard for simulator-safe CMMotionActivityManager start

key-files:
  created:
    - ArcticEdge/Location/GPSManager.swift
    - ArcticEdge/Activity/ActivityManager.swift
    - ArcticEdgeTests/Helpers/MockGPSManager.swift
    - ArcticEdgeTests/Helpers/MockActivityManager.swift
    - ArcticEdgeTests/Location/GPSManagerTests.swift
    - ArcticEdgeTests/Activity/ActivityManagerTests.swift
    - ArcticEdgeTests/Activity/ActivityClassifierTests.swift
  modified: []

key-decisions:
  - "ActivitySnapshot Sendable struct replaces AsyncStream<CMMotionActivity> — CMMotionActivity is not Sendable (ObjC class); primitive extraction mirrors MotionManager/CMDeviceMotion pattern"
  - "CLLocationUpdate.liveUpdates(.otherNavigation) selected over .automotiveNavigation — avoids road-snapping on mountain terrain"
  - "CLBackgroundActivitySession stored as actor property not local variable — local assignment causes premature deallocation and silently kills GPS stream"
  - "nonisolated makeStream() on GPSManagerProtocol and ActivityManagerProtocol — prevents SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor inference on non-UI protocol conformers"

patterns-established:
  - "Actor protocol pattern: protocol MyProtocol: Actor { nonisolated func makeStream() -> AsyncStream<T>; func start() async; func stop() async }"
  - "Sendable extraction: extract all fields from non-Sendable ObjC objects before Task { await actor.receive(...) } bridge"
  - "Wave 0 stubs: compilable #expect(Bool(false)) placeholders that prove test discovery works before implementation"

requirements-completed: [DETC-01]

# Metrics
duration: 10min
completed: 2026-03-09
---

# Phase 2 Plan 01: Signal Source Actors Summary

**GPSManager and ActivityManager actors with injectable protocols and 10 Wave 0 ActivityClassifier test stubs — full simulator-safe test infrastructure for Phase 2 TDD**

## Performance

- **Duration:** 10 min
- **Started:** 2026-03-10T01:05:10Z
- **Completed:** 2026-03-10T01:15:00Z
- **Tasks:** 3
- **Files modified:** 7 created, 0 modified

## Accomplishments

- GPSManager actor streaming CLLocationUpdate.liveUpdates(.otherNavigation) as GPSReading values with UUID-keyed fan-out
- ActivityManager actor bridging CMMotionActivityManager callbacks into AsyncStream<ActivitySnapshot> with isActivityAvailable() simulator guard
- 6 GREEN tests (GPSManagerTests 3 + ActivityManagerTests 3) and 10 RED stubs (ActivityClassifierTests) all under SWIFT_STRICT_CONCURRENCY = complete

## Task Commits

Each task was committed atomically:

1. **Task 1: GPSManager actor and injectable GPS protocol** - `560a069` (feat)
2. **Task 2: ActivityManager actor and injectable activity protocol** - `a2fbb02` (feat)
3. **Task 3: Wave 0 ActivityClassifier test stubs** - `52a558a` (test)

## Files Created/Modified

- `ArcticEdge/Location/GPSManager.swift` — GPSReading struct, GPSManagerProtocol, GPSManager actor
- `ArcticEdge/Activity/ActivityManager.swift` — ActivitySnapshot struct, ActivityManagerProtocol, ActivityManager actor
- `ArcticEdgeTests/Helpers/MockGPSManager.swift` — MockGPSManager actor for classifier test injection
- `ArcticEdgeTests/Helpers/MockActivityManager.swift` — MockActivityManager actor for classifier test injection
- `ArcticEdgeTests/Location/GPSManagerTests.swift` — 3 tests: invalid speed, invalid accuracy, mock injection
- `ArcticEdgeTests/Activity/ActivityManagerTests.swift` — 3 tests: simulator no-op, stream lifecycle, mock injection
- `ArcticEdgeTests/Activity/ActivityClassifierTests.swift` — 10 RED stubs covering DETC-01/02/03

## Decisions Made

- **ActivitySnapshot over AsyncStream<CMMotionActivity>:** CMMotionActivity is an ObjC class and not Sendable. Streaming it directly triggers strict concurrency errors. ActivitySnapshot extracts all boolean properties (stationary, walking, running, automotive, cycling, unknown, confidence) into a Sendable value type — same pattern as FilteredFrame/CMDeviceMotion in Phase 1.
- **.otherNavigation for CLLocationUpdate:** Chosen over .automotiveNavigation to prevent road-snapping algorithms from corrupting GPS readings on ski mountain terrain.
- **Stored CLBackgroundActivitySession:** Must be an actor stored property — local variable assignment causes the session to be released immediately, silently terminating the GPS update stream.
- **nonisolated makeStream():** Protocol members marked nonisolated to avoid SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor contaminating non-UI actor conformers (precedent from MotionDataSource).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] AsyncStream<CMMotionActivity> replaced with AsyncStream<ActivitySnapshot>**
- **Found during:** Task 2 (ActivityManager actor)
- **Issue:** CMMotionActivity is an ObjC class without Sendable conformance. Swift 6 strict concurrency rejects passing it across concurrency boundaries. The plan specified AsyncStream<CMMotionActivity> without accounting for this restriction.
- **Fix:** Created ActivitySnapshot Sendable struct that extracts all CMMotionActivity boolean properties on the callback thread before bridging to actor isolation. MockActivityManager.inject() accepts ActivitySnapshot directly. Tests updated accordingly.
- **Files modified:** ArcticEdge/Activity/ActivityManager.swift, ArcticEdgeTests/Helpers/MockActivityManager.swift, ArcticEdgeTests/Activity/ActivityManagerTests.swift
- **Verification:** xcodebuild test passes 3/3 ActivityManagerTests, zero compiler errors
- **Committed in:** a2fbb02 (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 — bug: non-Sendable type in async stream)
**Impact on plan:** Necessary for Swift 6 strict concurrency compliance. ActivityClassifier in plan 02-02 will use ActivitySnapshot instead of CMMotionActivity — no API surface loss (classifier only reads boolean flags which are all preserved in ActivitySnapshot).

## Issues Encountered

- Simulator destination discovery required: the project targets iOS 26.2 but available destination is "iPhone 17 Pro Simulator (iOS 26.2, id=14A2F3D0)" — `name=iPhone 16 Pro` from plan is incorrect for this Xcode version. Used simulator ID directly.

## User Setup Required

None — no external service configuration required.

## Next Phase Readiness

- All contracts for ActivityClassifier (plan 02-02) are in place: GPSManagerProtocol, ActivityManagerProtocol, MockGPSManager, MockActivityManager
- 10 Wave 0 test stubs are RED and discoverable — plan 02-02 can execute TDD GREEN immediately
- Both actors compile cleanly under SWIFT_STRICT_CONCURRENCY = complete
- Concern: ActivityClassifier in 02-02 will consume ActivitySnapshot.automotive for chairlift detection — the CMMotionActivity.automotive flag is a logical heuristic (not Apple-documented for chairlifts); on-mountain calibration still required (tracked in STATE.md)

## Self-Check: PASSED

All 7 created files confirmed present on disk. All 3 task commits (560a069, a2fbb02, 52a558a) confirmed in git log. Build succeeded with zero errors. 6 GREEN tests + 10 RED stubs verified.

---
*Phase: 02-activity-detection-run-management*
*Completed: 2026-03-09*
