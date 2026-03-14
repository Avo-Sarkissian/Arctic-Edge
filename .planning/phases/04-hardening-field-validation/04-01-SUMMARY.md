---
phase: 04-hardening-field-validation
plan: 01
subsystem: power-saver, debug-overlay
tags: [battery, thermal, power-saver, debug-hud, motionmanager, gpsmanager]

# Dependency graph
requires:
  - phase: 03-live-telemetry-post-run-analysis
    plan: 06
    provides: AppModel full pipeline wiring

provides:
  - PowerSaverMode enum: .normal / .saving, nonisolated Sendable
  - AppModel.powerSaverMode: activates ≤30%, deactivates ≥35%
  - AppModel.nextPowerSaverMode: nonisolated static for testability
  - AppModel.thermalStateLabel, batteryPercent, currentSampleRateHz, gpsHorizontalAccuracyMeters
  - MotionManager.currentSampleRateHz, setPowerSaverMode (60Hz cap, thermal wins if lower)
  - GPSManager.setPowerSaverMode (≤1 update per 5s duty cycle)
  - ClassifierDebugHUD: THML, BATT, RATE, ACC rows + PWR SAVE indicator
  - PowerSaverTests: 6 tests green

affects:
  - Phase 4 plan 02 (MetricKit + calibration) — power saver infrastructure complete

# Tech tracking
tech-stack:
  added: [UIDevice.batteryLevel, UIDevice.batteryLevelDidChangeNotification, ProcessInfo.ThermalState]
  patterns:
    - "nonisolated static func for pure threshold logic — testable without instantiating @MainActor class"
    - "SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor requires nonisolated on enums used from nonisolated contexts"
    - "GPS duty cycling via lastBroadcastDate guard in broadcast() — no CoreLocation API change needed"
    - "Thermal + power saver composited in adjustSampleRate: min(thermalHz, 60) when saving"

key-files:
  modified:
    - ArcticEdge/ArcticEdgeApp.swift
    - ArcticEdge/Motion/MotionManager.swift
    - ArcticEdge/Location/GPSManager.swift
    - ArcticEdge/Debug/ClassifierDebugHUD.swift
  created:
    - ArcticEdgeTests/Hardening/PowerSaverTests.swift
    - .planning/phases/04-hardening-field-validation/04-01-PLAN.md

key-decisions:
  - "nonisolated on PowerSaverMode enum: SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor infers @MainActor on enum Equatable conformances, making them unusable in nonisolated test contexts; nonisolated keyword fixes this (matches ClassifierState pattern)"
  - "nextPowerSaverMode extracted as nonisolated static: avoids instantiating AppModel (needs ModelContainer) in unit tests"
  - "batteryObserver torn down in endDay() not deinit: battery monitoring is session-scoped, not app-scoped — disable on session end to avoid spurious mode switches when app is open but no session active"
  - "GPS duty cycling via timestamp guard in broadcast(): simpler than stop/restart CLLocationUpdate stream; CoreLocation continues feeding fixes, GPSManager just skips yielding them"
  - "HUD polling reads ProcessInfo.processInfo.thermalState directly (synchronous, thread-safe) — no await needed"

patterns-established:
  - "Thermal + battery compositing in sample rate: min(thermalHz, powerSaverCap) — thermal always wins"
  - "GPS duty cycle via lastBroadcastDate in actor-isolated broadcast() — no external API changes"

requirements-completed: [HARD-01, HARD-02, HARD-04]

# Metrics
duration: ~35min
completed: 2026-03-14
---

# Phase 04 Plan 01: Power Saver Mode + Enhanced Debug Overlay Summary

**Battery-threshold Power Saver mode (30%/35% hysteresis), reduced IMU and GPS load, enhanced ClassifierDebugHUD with system telemetry rows**

## Performance

- **Duration:** ~35 min
- **Completed:** 2026-03-14
- **Tasks:** 3
- **Files modified:** 4 modified, 1 created

## Accomplishments

- Added `PowerSaverMode` enum (`.normal`/`.saving`) — `nonisolated` to satisfy Swift 6 strict concurrency under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
- `AppModel.nextPowerSaverMode(current:batteryPercent:)` — pure nonisolated static threshold logic; activates ≤30%, deactivates ≥35%
- `setupBatteryMonitoring()` — registers `UIDevice.batteryLevelDidChangeNotification`, guards on `batteryLevel >= 0` (simulator returns -1)
- `MotionManager.setPowerSaverMode(_:)` — calls `adjustSampleRate(for:)` which now composites thermal + power saver: `min(thermalHz, 60)` when saving active
- `MotionManager.currentSampleRateHz` — actor-isolated `Int` property for HUD polling
- `GPSManager.setPowerSaverMode(_:)` — sets `powerSaverEnabled`; `broadcast()` skips yields when `< 5s` since `lastBroadcastDate`; resets throttle on disable
- Enhanced `startHUDPolling()` — reads `thermalState`, `currentSampleRateHz`, `gpsHorizontalAccuracy` per 100ms tick
- `ClassifierDebugHUD` — added THML/BATT/RATE/ACC rows + `PWR SAVE` yellow label when active; widened to 160px
- Battery observer torn down and monitoring disabled in `endDay()` (session-scoped, not app-scoped)
- `ProcessInfo.ThermalState.debugLabel` extension (private, in ArcticEdgeApp.swift)

## Task Commits

1. **Tasks 1–3: PowerSaver + MotionManager + GPSManager + HUD** — `5910c29` (feat)

## Files Created/Modified

- `ArcticEdge/ArcticEdgeApp.swift` — PowerSaverMode enum, 5 new AppModel properties, setupBatteryMonitoring, updatePowerSaverMode, nextPowerSaverMode static, extended startHUDPolling, endDay battery teardown, ThermalState.debugLabel
- `ArcticEdge/Motion/MotionManager.swift` — powerSaverEnabled, currentSampleRateHz, setPowerSaverMode, adjustSampleRate refactored to Int Hz with power saver cap
- `ArcticEdge/Location/GPSManager.swift` — powerSaverEnabled, lastBroadcastDate, powerSaverMinInterval=5s, setPowerSaverMode, broadcast() throttle guard
- `ArcticEdge/Debug/ClassifierDebugHUD.swift` — 4 new system rows, PWR SAVE indicator, frame widened 148→160
- `ArcticEdgeTests/Hardening/PowerSaverTests.swift` — 6 threshold tests, all green

## Test Results

- **PowerSaverTests**: 6/6 PASSED
- **MotionManagerTests**: 4/4 PASSED (thermal adjustment still correct)
- Build: SUCCEEDED with SWIFT_STRICT_CONCURRENCY = complete, no new errors

## Self-Check: PASSED

- Build SUCCEEDED
- PowerSaverTests 6/6 green
- MotionManagerTests 4/4 green
- Commit: 5910c29
- Pushed to GitHub

---
*Phase: 04-hardening-field-validation*
*Completed: 2026-03-14*
