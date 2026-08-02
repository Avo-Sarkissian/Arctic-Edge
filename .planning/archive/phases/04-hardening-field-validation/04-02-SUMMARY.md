---
phase: 04-hardening-field-validation
plan: 02
subsystem: diagnostics, calibration
tags: [metrickit, battery-profiling, calibration-export, diagnostics]

provides:
  - MetricKitSubscriber: daily MXMetricPayload + MXDiagnosticPayload → JSONL in Documents/MetricKit/
  - CalibrationExporter: actor, exportRun(runID:) → JSON in Documents/Calibration/
  - ArcticEdgeApp retains MetricKitSubscriber for process lifetime

key-files:
  created:
    - ArcticEdge/Diagnostics/MetricKitSubscriber.swift
    - ArcticEdge/Diagnostics/CalibrationExporter.swift
  modified:
    - ArcticEdge/ArcticEdgeApp.swift (metricKitSubscriber stored property)

key-decisions:
  - "MetricKitSubscriber in ArcticEdgeApp struct (not AppModel): @Observable nonisolated init cannot hold stored properties with complex default-value expressions; App struct has no such constraint"
  - "nonisolated struct on CalibrationPayload/CalibrationFrame: SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor infers @MainActor on Encodable conformances of types in @MainActor context; nonisolated struct opts out so JSONEncoder.encode works from CalibrationExporter actor"
  - "CalibrationExporter takes concrete PersistenceService (not protocol): fetchFrameDataForRun returns [FrameSnapshot] (Sendable); the protocol only exposes fetchFrameRecords which returns non-Sendable [FrameRecord]"

requirements-completed: [HARD-01, HARD-03]

# Metrics
duration: ~20min
completed: 2026-03-14
---

# Phase 04 Plan 02: MetricKit + Calibration Export Summary

**Daily MetricKit payload logging to JSONL + CalibrationExporter actor for field-test run data export**

## Accomplishments

- `MetricKitSubscriber` — `NSObject + MXMetricManagerSubscriber`, nonisolated `didReceive` methods, appends each payload as a JSONL envelope to `Documents/MetricKit/metrics-YYYY-MM-DD.jsonl`
- Retained in `ArcticEdgeApp` struct (not AppModel) — App struct has no `@Observable` / `nonisolated init` constraints
- `CalibrationExporter` actor — `exportRun(runID:)` fetches `[FrameSnapshot]` via `PersistenceService.fetchFrameDataForRun`, encodes to JSON at `Documents/Calibration/run-<shortID>-<date>.json`
- Both types build with `SWIFT_STRICT_CONCURRENCY = complete`

## Key Concurrency Decisions

- `nonisolated struct CalibrationPayload/CalibrationFrame`: required by `InferIsolatedConformances` upcoming feature — without it, Encodable conformances are `@MainActor` and inaccessible from `CalibrationExporter`'s actor context
- `CalibrationExporter` uses concrete `PersistenceService` to access `fetchFrameDataForRun` (Sendable `[FrameSnapshot]`), matching the `PostRunViewModel` pattern

## Self-Check: PASSED

- Build SUCCEEDED, no new errors or warnings
- Commit: c5212ca
- Pushed to GitHub

---
*Phase: 04-hardening-field-validation*
*Completed: 2026-03-14*
