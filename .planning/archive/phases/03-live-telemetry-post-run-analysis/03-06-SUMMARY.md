---
phase: 03-live-telemetry-post-run-analysis
plan: 06
subsystem: wiring
tags: [appmodel, tabview, todaytabview, fullscreencover, sheet, gps-flush, run-finalization]

# Dependency graph
requires:
  - phase: 03-live-telemetry-post-run-analysis
    plan: 03
    provides: LiveTelemetryView
  - phase: 03-live-telemetry-post-run-analysis
    plan: 04
    provides: PostRunAnalysisView(runID:)
  - phase: 03-live-telemetry-post-run-analysis
    plan: 05
    provides: RunHistoryView

provides:
  - AppModel.lastFinalizedRunID: UUID? set by HUD polling on currentRunID nil transition
  - AppModel.startPeriodicFlush: @MainActor Task capturing lastGPSSpeed, calling flushWithGPS
  - TodayTabView: ContentView + fullScreenCover(LiveTelemetryView) + .sheet(PostRunAnalysisView)
  - ArcticEdgeApp: TabView root with Today + History tabs

affects:
  - Phase 4 (full wiring in place; field validation can begin)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "@MainActor periodic Task reading lastGPSSpeed before handing off to detached Task for ModelActor flush"
    - "dismissedRunIDs: Set<UUID> prevents post-run sheet re-presenting same run after user dismisses"
    - "TodayTabView uses Binding with manual get/set for .sheet isPresented to avoid UUID Identifiable conformance"

key-files:
  created:
    - ArcticEdge/Today/TodayTabView.swift
  modified:
    - ArcticEdge/ArcticEdgeApp.swift

key-decisions:
  - "startPeriodicFlush changed from Task.detached to @MainActor Task: @MainActor is needed to read lastGPSSpeed synchronously; detached sub-task hands off to @ModelActor for the actual flush"
  - "dismissedRunIDs: Set<UUID> in TodayTabView: lastFinalizedRunID is non-nil for the entire session after first run ends; without tracking dismissed IDs, sheet would re-present on every subsequent view update"
  - ".sheet(isPresented:) with manual Binding<Bool> used instead of .sheet(item:) to avoid adding retroactive UUID: Identifiable conformance"
  - "iOS 18 Tab struct API used (not deprecated .tabItem/.tag): Tab('Today', systemImage:) { } pattern"

patterns-established:
  - "@MainActor flush loop: capture GPS speed on MainActor, pass to Task.detached for ModelActor flush — bridge pattern for crossing actor boundaries with time-sensitive values"
  - "dismissedRunIDs pattern for one-shot auto-presenting sheets in long-running sessions"

requirements-completed: [LIVE-01, LIVE-02, LIVE-03, ANLYS-01, ANLYS-02, ANLYS-03, ANLYS-04, HIST-01, HIST-02]

# Metrics
duration: ~20min
completed: 2026-03-13
---

# Phase 03 Plan 06: AppModel Wiring + TodayTabView + TabView Root Summary

**Complete Phase 3 wiring: lastFinalizedRunID on AppModel, GPS-stamped periodic flush, TodayTabView with auto-presenting live view and post-run sheet, TabView root with Today + History tabs**

## Performance

- **Duration:** ~20 min
- **Completed:** 2026-03-13
- **Tasks:** 2
- **Files modified:** 2 (1 modified, 1 created)

## Accomplishments

- Added `lastFinalizedRunID: UUID?` and `previousRunID: UUID?` to AppModel; HUD polling detects `currentRunID` non-nil → nil transition and sets `lastFinalizedRunID`
- Updated `startPeriodicFlush` from `Task.detached` to `@MainActor Task` that captures `lastGPSSpeed` then delegates to a detached sub-task calling `service.flushWithGPS(frames:gpsSpeed:)` (plan 03-02)
- Created TodayTabView: ContentView base + `fullScreenCover` driven by `classifierStateLabel == "SKIING"` + `.sheet` driven by `lastFinalizedRunID` with `dismissedRunIDs` guard
- Updated ArcticEdgeApp body: `TabView { Tab("Today", ...) { TodayTabView() } Tab("History", ...) { RunHistoryView() } }` with iOS 18 Tab struct API
- All tests pass when run individually (simulator parallel flakiness pre-exists; not introduced by these changes)

## Task Commits

1. **Task 1+2: AppModel + TodayTabView + TabView root** - `e737af9` (feat)

## Files Created/Modified

- `ArcticEdge/ArcticEdgeApp.swift` — Added lastFinalizedRunID, previousRunID; updated startHUDPolling (run finalization detection); updated startPeriodicFlush (@MainActor + flushWithGPS); updated endDay (reset finalization state); updated WindowGroup to TabView root
- `ArcticEdge/Today/TodayTabView.swift` — ContentView + fullScreenCover(isPresented: $showLive) + .sheet with dismissedRunIDs guard + onChange handlers for classifierStateLabel and lastFinalizedRunID

## Decisions Made

- `startPeriodicFlush` must be `@MainActor` (not detached) to read `lastGPSSpeed` safely; the actual flush is handed off to a `Task.detached` sub-task to avoid blocking MainActor on `@ModelActor` I/O
- `dismissedRunIDs: Set<UUID>` prevents the post-run sheet from re-presenting after the user dismisses it mid-session (since `lastFinalizedRunID` stays non-nil until `endDay`)
- Used `Binding<Bool>` wrapper for `.sheet(isPresented:)` instead of `.sheet(item: $UUID?)` to avoid adding retroactive `UUID: Identifiable` conformance

## Human Verify Checkpoint

Phase 3 is complete. To verify end-to-end behavior:
1. Launch app — two tabs appear: Today (mountain icon) and History (clock icon)
2. Start Day — debug HUD shows CHAIRLIFT state
3. History tab shows empty state when no runs recorded
4. On run detection (SKIING state) — LiveTelemetryView presents fullscreen automatically
5. On run end — LiveTelemetryView dismisses, PostRunAnalysisView sheet presents automatically
6. Dismiss post-run sheet — sheet does not re-present for the same run
7. Full test suite passes when run sequentially

## Self-Check: PASSED

- FOUND: ArcticEdge/Today/TodayTabView.swift (created)
- FOUND: ArcticEdge/ArcticEdgeApp.swift (modified — lastFinalizedRunID, TabView root)
- Build: SUCCEEDED (warnings: CLGeocoder deprecated iOS 26, pre-existing)
- All tests pass in isolation
- Commit: e737af9

---
*Phase: 03-live-telemetry-post-run-analysis*
*Completed: 2026-03-13*
