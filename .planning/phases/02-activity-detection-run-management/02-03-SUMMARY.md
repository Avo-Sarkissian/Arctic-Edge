---
phase: 02-activity-detection-run-management
plan: 03
subsystem: ui
tags: [swiftui, observable, actor, classifierdebughud, arctic-dark, day-session]

# Dependency graph
requires:
  - phase: 02-activity-detection-run-management/02-01
    provides: GPSManager and ActivityManager actors with makeStream()
  - phase: 02-activity-detection-run-management/02-02
    provides: ActivityClassifier hysteresis state machine with startDay/endDay

provides:
  - AppModel wired with gpsManager, activityManager, activityClassifier
  - startDay() and endDay() verbs replacing startSession/endSession
  - 10Hz HUD polling bridging actor state to @Observable main-actor properties
  - Arctic Dark ContentView with Start Day / End Day controls
  - ClassifierDebugHUD (#if DEBUG only) showing live classifier state

affects:
  - 03-data-export
  - 04-ui-polish

# Tech tracking
tech-stack:
  added: []
  patterns:
    - HUD polling via Task { @MainActor [weak self] } at 10Hz to bridge actor -> @Observable
    - #if DEBUG compilation guard for debug-only SwiftUI views
    - .allowsHitTesting(false) on HUD overlay to avoid touch interception

key-files:
  created:
    - ArcticEdge/Debug/ClassifierDebugHUD.swift
  modified:
    - ArcticEdge/ArcticEdgeApp.swift
    - ArcticEdge/ContentView.swift
    - ArcticEdge/Activity/ActivityClassifier.swift

key-decisions:
  - "HUD polling (Task + while loop at 100ms) chosen over callback/Combine: actor state readable via await without protocol changes"
  - "classifierStateLabel, latestActivityLabel, hysteresisProgress added to ActivityClassifier as actor-isolated computed properties"
  - "activityClassifier.startDay() called with await — plan incorrectly showed synchronous call; actor isolation requires await"

patterns-established:
  - "Actor-to-@Observable bridge: Task { @MainActor [weak self] } polling loop, cancellable via stored Task handle"
  - "Debug-only SwiftUI views: wrap entire file in #if DEBUG, overlay with .allowsHitTesting(false)"
  - "Arctic Dark palette: Color(red: 0.07, green: 0.08, blue: 0.10) background, .regularMaterial card, .ultraThinMaterial HUD"

requirements-completed: [DETC-01, DETC-02, DETC-03]

# Metrics
duration: 30min
completed: 2026-03-09
---

# Phase 02 Plan 03: Integration and UI Layer Summary

**ActivityClassifier, GPSManager, and ActivityManager wired into AppModel with startDay/endDay; Arctic Dark Start Day/End Day UI with #if DEBUG live classifier HUD.**

## Performance

- **Duration:** ~30 min
- **Started:** 2026-03-09T21:30:00Z
- **Completed:** 2026-03-09T22:00:00Z
- **Tasks:** 2 of 3 complete (Task 3 is checkpoint:human-verify — awaiting user approval)
- **Files modified:** 4

## Accomplishments
- AppModel now holds gpsManager, activityManager, activityClassifier as stored actors
- startDay() arms all capture in correct order: HKWorkoutSession -> GPS -> Activity -> Classifier -> IMU pipeline
- endDay() finalizes open RunRecord and stops all managers cleanly
- 10Hz HUD polling bridges ActivityClassifier actor state to @Observable main-actor properties
- ContentView replaced with Arctic Dark session controls (near-black background, frosted glass status card, tracked wordmark)
- ClassifierDebugHUD created under ArcticEdge/Debug/, wrapped in #if DEBUG, does not intercept taps

## Task Commits

Each task was committed atomically:

1. **Task 1: AppModel refactor — add GPS/Activity/Classifier actors and startDay/endDay** - `e604126` (feat)
2. **Task 2: ContentView and ClassifierDebugHUD** - `3d8ae5d` (feat)
3. **Task 3: checkpoint:human-verify** — awaiting human approval

## Files Created/Modified
- `ArcticEdge/ArcticEdgeApp.swift` - Added gpsManager, activityManager, activityClassifier; startDay/endDay; HUD polling; AppModelError enum
- `ArcticEdge/ContentView.swift` - Replaced placeholder with Arctic Dark Start Day/End Day UI
- `ArcticEdge/Debug/ClassifierDebugHUD.swift` - New #if DEBUG HUD showing state, GPS, variance, activity, hysteresis progress
- `ArcticEdge/Activity/ActivityClassifier.swift` - Added classifierStateLabel, latestActivityLabel, hysteresisProgress computed properties

## Decisions Made

- **HUD polling pattern:** Used a `Task { @MainActor [weak self] }` while loop running at 100ms intervals to read actor-isolated ActivityClassifier state and update @Observable AppModel properties. This avoids Combine, avoids adding a protocol, and is cancellable via the stored `hudPollingTask` handle.
- **Actor isolation fix (Rule 1):** `activityClassifier.startDay()` is actor-isolated — the plan showed a synchronous call without `await`. Fixed to `await activityClassifier.startDay(...)` which is required for cross-actor method calls in Swift strict concurrency.
- **HUD computed properties on ActivityClassifier:** Added `classifierStateLabel`, `latestActivityLabel`, and `hysteresisProgress` directly on `ActivityClassifier` (actor-isolated computed properties) rather than on AppModel. This keeps the string conversion logic with the type that owns the data.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed missing `await` on actor-isolated `startDay()` call**
- **Found during:** Task 1 (AppModel refactor), at build verification
- **Issue:** The plan showed `activityClassifier.startDay(...)` without `await`, but `startDay()` is an actor-isolated method — calling it without `await` from outside the actor is a Swift strict concurrency error
- **Fix:** Changed to `await activityClassifier.startDay(...)`
- **Files modified:** ArcticEdge/ArcticEdgeApp.swift
- **Verification:** Build succeeded after fix (BUILD SUCCEEDED confirmed)
- **Committed in:** e604126 (Task 1 commit)

**2. [Rule 2 - Missing Critical] Added HUD computed properties to ActivityClassifier**
- **Found during:** Task 1, when writing startHUDPolling() — plan referenced `classifier.classifierStateLabel`, `classifier.latestActivityLabel`, `classifier.hysteresisProgress` but these didn't exist on ActivityClassifier
- **Issue:** ActivityClassifier had `state: ClassifierState`, `latestActivity: ActivitySnapshot?`, and `gForceVariance: Double` but no string-conversion or hysteresis progress properties for the HUD polling loop
- **Fix:** Added `classifierStateLabel: String`, `latestActivityLabel: String`, and `hysteresisProgress: Double` as actor-isolated computed properties on ActivityClassifier
- **Files modified:** ArcticEdge/Activity/ActivityClassifier.swift
- **Verification:** Build succeeded; properties correctly compute from existing mutable state
- **Committed in:** e604126 (Task 1 commit)

---

**Total deviations:** 2 auto-fixed (1 bug fix, 1 missing critical functionality)
**Impact on plan:** Both auto-fixes were necessary for correctness — the missing `await` was a compile error, and the HUD properties were required for the polling loop to function.

## Issues Encountered
- Xcode 26 beta simulators do not include iPhone 16 Pro — used iPhone 17 Pro simulator (id=14A2F3D0) as equivalent target. Both debug and release builds succeed.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 2 pipeline is fully wired and user-visible
- Awaiting human-verify checkpoint approval (Task 3) to confirm UI renders correctly in simulator
- Once approved, requirements DETC-01, DETC-02, DETC-03 are fully satisfied
- Phase 3 (data export) can proceed once checkpoint is approved

---
*Phase: 02-activity-detection-run-management*
*Completed: 2026-03-09*
