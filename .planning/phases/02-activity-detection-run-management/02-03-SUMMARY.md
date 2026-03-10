---
phase: 02-activity-detection-run-management
plan: 03
subsystem: ui
tags: [swiftui, observable, actor, classifierdebughud, arctic-dark, day-session, healthkit, entitlements]

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
  - Arctic Dark ContentView: gradient background, topo texture, animated wordmark, frosted status pill, prominent CTA, stats row
  - ClassifierDebugHUD (#if DEBUG only) showing live classifier state with dark thinMaterial background
  - HealthKit entitlement wired in project (com.apple.developer.healthkit + background-delivery)

affects:
  - 03-data-export
  - 04-ui-polish

# Tech tracking
tech-stack:
  added: []
  patterns:
    - HUD polling via Task { @MainActor [weak self] } at 10Hz to bridge actor -> @Observable
    - "#if DEBUG compilation guard for debug-only SwiftUI views"
    - .allowsHitTesting(false) on HUD overlay to avoid touch interception
    - Canvas-drawn topographic texture — no image assets, pure SwiftUI path math
    - Wordmark breathing animation: withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) keyed on isDayActive
    - Frosted capsule status pill with ultraThinMaterial + Capsule clip + strokeBorder overlay
    - Two-variant button: LinearGradient fill (Start) vs outlined ultraThinMaterial (End)

key-files:
  created:
    - ArcticEdge/Debug/ClassifierDebugHUD.swift
    - ArcticEdge/ArcticEdge.entitlements
  modified:
    - ArcticEdge/ArcticEdgeApp.swift
    - ArcticEdge/ContentView.swift
    - ArcticEdge/Activity/ActivityClassifier.swift
    - ArcticEdge.xcodeproj/project.pbxproj

key-decisions:
  - "HUD polling (Task + while loop at 100ms) chosen over callback/Combine: actor state readable via await without protocol changes"
  - "classifierStateLabel, latestActivityLabel, hysteresisProgress added to ActivityClassifier as actor-isolated computed properties"
  - "activityClassifier.startDay() called with await — plan incorrectly showed synchronous call; actor isolation requires await"
  - "Canvas-drawn topo lines replace any image-based texture — zero asset dependencies, fully generative"
  - "Start/End Day button is two distinct layouts (not conditional tint) to support gradient fill vs outlined style semantics"
  - "CODE_SIGN_ENTITLEMENTS added directly to pbxproj Debug + Release build configs — file placed inside ArcticEdge/ for PBXFileSystemSynchronizedRootGroup auto-pickup"

patterns-established:
  - "Actor-to-@Observable bridge: Task { @MainActor [weak self] } polling loop, cancellable via stored Task handle"
  - "Debug-only SwiftUI views: wrap entire file in #if DEBUG, overlay with .allowsHitTesting(false)"
  - "Arctic Dark palette: full-bleed LinearGradient (#0D1117 -> #060F17), .ultraThinMaterial capsules, .thinMaterial debug panel"
  - "Wordmark animation: syncWordmarkAnimation() keyed on @Observable property change via .onChange modifier"

requirements-completed: [DETC-01, DETC-02, DETC-03]

# Metrics
duration: ~65min (30min original + 35min checkpoint resolution)
completed: 2026-03-09
---

# Phase 02 Plan 03: Integration and UI Layer Summary

**ActivityClassifier, GPSManager, and ActivityManager wired into AppModel with startDay/endDay; full Arctic Dark ContentView redesign with animated wordmark, frosted status pill, Canvas topo texture; HealthKit entitlement wired.**

## Performance

- **Duration:** ~65 min total (two execution sessions)
- **Session 1:** 2026-03-09T00:10 — 2026-03-09T01:49Z (Tasks 1–2 + checkpoint)
- **Session 2:** 2026-03-09T21:45 — 2026-03-09T22:05Z (checkpoint resolution: entitlement fix + UI redesign)
- **Tasks:** 3 of 3 complete (checkpoint resolved with two fixes)
- **Files modified:** 6

## Accomplishments

- AppModel holds gpsManager, activityManager, activityClassifier as stored actors
- startDay() arms capture in SESS-01 order: HKWorkoutSession -> GPS -> Activity -> Classifier -> IMU pipeline
- endDay() finalizes open RunRecord, stops all managers, emergency-flushes ring buffer
- 10Hz HUD polling bridges ActivityClassifier actor state to @Observable main-actor properties via cancellable Task
- ContentView fully redesigned with Arctic Dark aesthetic:
  - Full-bleed LinearGradient background (deep slate -> near-black)
  - Canvas-drawn topographic contour lines (12 sinusoidal curves, 3.5% opacity)
  - ARCTICEDGE wordmark: SF Pro Black 28pt, 15% tracking, pulsing glow when day is active
  - Frosted ultraThinMaterial status capsule with colored indicator dot
  - START DAY: blue gradient fill with shadow; END DAY: outlined red tint
  - Stats row (frosted cards) slides in when day is active
- ClassifierDebugHUD redesigned: dark thinMaterial background, state-keyed accent dot, custom progress bar, monospace digits
- HealthKit entitlement added: `com.apple.developer.healthkit` + background-delivery in ArcticEdge.entitlements
- entitlements file wired into pbxproj Debug + Release configs with usage description keys

## Task Commits

1. **Task 1: AppModel refactor** - `e604126` (feat)
2. **Task 2: ContentView and ClassifierDebugHUD** - `3d8ae5d` (feat)
3. **Fix 1: HealthKit entitlement** - `f4af55d` (fix) — checkpoint resolution
4. **Fix 2: Arctic Dark UI redesign** - `df9f413` (feat) — checkpoint resolution

## Files Created/Modified

- `ArcticEdge/ArcticEdgeApp.swift` — gpsManager, activityManager, activityClassifier; startDay/endDay; HUD polling; AppModelError
- `ArcticEdge/ContentView.swift` — full Arctic Dark redesign with gradient, topo texture, animated wordmark, frosted pill, CTA button, stats row
- `ArcticEdge/Debug/ClassifierDebugHUD.swift` — #if DEBUG HUD with dark thinMaterial, monospace diagnostics, custom progress bar
- `ArcticEdge/Activity/ActivityClassifier.swift` — classifierStateLabel, latestActivityLabel, hysteresisProgress computed properties
- `ArcticEdge/ArcticEdge.entitlements` — HealthKit entitlement file (NEW)
- `ArcticEdge.xcodeproj/project.pbxproj` — CODE_SIGN_ENTITLEMENTS + HealthKit usage description keys in Debug + Release

## Decisions Made

- **HUD polling pattern:** `Task { @MainActor [weak self] }` while loop at 100ms. Cancellable via `hudPollingTask`. No Combine, no protocol changes.
- **Actor isolation fix:** `activityClassifier.startDay()` requires `await` — plan showed synchronous call. Fixed at Task 1 build verification.
- **HUD computed properties:** `classifierStateLabel`, `latestActivityLabel`, `hysteresisProgress` placed on ActivityClassifier (owns the data). Not duplicated onto AppModel.
- **Canvas topo texture:** Zero image assets. 12 sinusoidal paths drawn per render, negligible CPU at screen framerate.
- **Button semantics:** Two distinct label layouts for Start/End Day (not a single view with conditional tint) — gradient fill vs outlined is a structural difference, not just a color tweak.
- **Entitlement path:** `ArcticEdge/ArcticEdge.entitlements` inside the PBXFileSystemSynchronizedRootGroup directory — Xcode picks it up automatically; pbxproj only needs the build setting reference.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed missing `await` on actor-isolated `startDay()` call**
- **Found during:** Task 1 build verification
- **Issue:** Plan showed synchronous call; Swift strict concurrency requires `await` for cross-actor method calls
- **Fix:** `await activityClassifier.startDay(...)`
- **Files:** ArcticEdge/ArcticEdgeApp.swift
- **Commit:** e604126

**2. [Rule 2 - Missing Critical] Added HUD computed properties to ActivityClassifier**
- **Found during:** Task 1, writing `startHUDPolling()`
- **Issue:** `classifier.classifierStateLabel`, `classifier.latestActivityLabel`, `classifier.hysteresisProgress` referenced in polling loop but did not exist
- **Fix:** Added as actor-isolated computed properties on ActivityClassifier
- **Files:** ArcticEdge/Activity/ActivityClassifier.swift
- **Commit:** e604126

**3. [Rule 1 - Bug] HealthKit entitlement missing from project (checkpoint resolution)**
- **Found during:** User testing — "missing com.apple.developer.healthkit entitlement"
- **Issue:** HKWorkoutSession.start() silently requires the entitlement; missing it causes a runtime authorization failure on device
- **Fix:** Created ArcticEdge.entitlements with healthkit + background-delivery; wired CODE_SIGN_ENTITLEMENTS in pbxproj Debug + Release; added NSHealthShareUsageDescription + NSHealthUpdateUsageDescription Info.plist keys
- **Files:** ArcticEdge/ArcticEdge.entitlements (new), ArcticEdge.xcodeproj/project.pbxproj
- **Commit:** f4af55d

**4. [Rule 1 - UX] UI insufficient — full Arctic Dark redesign (checkpoint resolution)**
- **Found during:** User testing — "looks very basic, should be very sleek and modern"
- **Issue:** Original ContentView used flat color background, plain status card, solid-color button — insufficient Arctic Dark execution
- **Fix:** Full redesign: LinearGradient background, Canvas topo texture, animated wordmark glow, frosted capsule status pill, gradient CTA button with shadow, animated stats row, dark monospace HUD
- **Files:** ArcticEdge/ContentView.swift, ArcticEdge/Debug/ClassifierDebugHUD.swift
- **Commit:** df9f413

---

**Total deviations:** 4 auto-fixed (2 bugs, 1 missing critical, 1 UX insufficiency)

## Next Phase Readiness

- Phase 2 pipeline fully wired and user-verified
- Requirements DETC-01, DETC-02, DETC-03 satisfied
- HealthKit entitlement in place — WorkoutSession will request authorization correctly on device
- Phase 3 (data export) can proceed

---
*Phase: 02-activity-detection-run-management*
*Completed: 2026-03-09*
