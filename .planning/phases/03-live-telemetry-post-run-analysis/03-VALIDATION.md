---
phase: 3
slug: live-telemetry-post-run-analysis
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-10
---

# Phase 3 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Swift Testing (`import Testing`) — already in use for all project tests |
| **Config file** | None — Xcode discovers tests automatically |
| **Quick run command** | `xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:ArcticEdgeTests/LiveViewModelTests 2>&1 \| grep -E "(Test|FAIL|PASS)"` |
| **Full suite command** | `xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 \| grep -E "(Test|FAIL|PASS)"` |
| **Estimated runtime** | ~45 seconds (simulator boot + test execution) |

---

## Sampling Rate

- **After every task commit:** Run tests for the ViewModel modified in that task
- **After every plan wave:** Run full suite — must be green
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** ~45 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 03-01-W0 | 01 | 0 | LIVE-01, LIVE-02, LIVE-03 | unit stubs | `-only-testing:ArcticEdgeTests/LiveViewModelTests` | ❌ W0 | ⬜ pending |
| 03-01-01 | 01 | 1 | LIVE-01 | unit | `testWaveformSnapshotBuilds` | ❌ W0 | ⬜ pending |
| 03-01-02 | 01 | 1 | LIVE-02 | unit | `testMetricValuesUpdate` | ❌ W0 | ⬜ pending |
| 03-01-03 | 01 | 1 | LIVE-03 | unit | `testSnapshotDoesNotExceedWindowSize` | ❌ W0 | ⬜ pending |
| 03-01-M1 | 01 | manual | LIVE-03 | manual | 120fps visual check on device | N/A | ⬜ pending |
| 03-02-W0 | 02 | 0 | ANLYS-01..04, HIST-01, HIST-02 | unit stubs | `-only-testing:ArcticEdgeTests/PostRunViewModelTests` `-only-testing:ArcticEdgeTests/HistoryViewModelTests` | ❌ W0 | ⬜ pending |
| 03-02-01 | 02 | 1 | ANLYS-01 | unit | `testFrameRecordLoading` | ❌ W0 | ⬜ pending |
| 03-02-02 | 02 | 1 | ANLYS-02 | unit | `testStatsComputation` | ❌ W0 | ⬜ pending |
| 03-02-03 | 02 | 1 | ANLYS-03 | unit | `testSessionAggregates` | ❌ W0 | ⬜ pending |
| 03-02-04 | 02 | 1 | ANLYS-04 | unit | `testScrubberFrameLookup` | ❌ W0 | ⬜ pending |
| 03-02-05 | 02 | 2 | HIST-01 | unit | `testPaginationOffsetAdvances` | ❌ W0 | ⬜ pending |
| 03-02-06 | 02 | 2 | HIST-02 | unit | `testResortNameFallback` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `ArcticEdgeTests/Live/LiveViewModelTests.swift` — stubs for LIVE-01, LIVE-02, LIVE-03
- [ ] `ArcticEdgeTests/PostRun/PostRunViewModelTests.swift` — stubs for ANLYS-01, ANLYS-02, ANLYS-03, ANLYS-04
- [ ] `ArcticEdgeTests/History/HistoryViewModelTests.swift` — stubs for HIST-01, HIST-02
- [ ] `ArcticEdgeTests/Helpers/MockPersistenceService.swift` — extend with `fetchRunRecords` and `fetchFrameRecords` methods

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Waveform scrolls at 120fps with no frame drops during 100Hz ingestion | LIVE-03 | Frame rate fluidity requires on-device ProMotion display — not measurable in simulator unit tests | Run on iPhone 16 Pro: start a day, stream live data, observe waveform in Instruments (Core Animation FPS) — confirm steady 120fps |
| Post-run auto-sheet appears within 2 seconds of run end | ANLYS-01 | Timing depends on classifier transition and flush latency — no simulator equivalent | On device (or with mock classifier): trigger run end, confirm sheet appears promptly |
| Resort name from reverse geocode matches actual mountain | HIST-02 | CLGeocoder behavior at real mountain coordinates untested — requires GPS at actual ski resort | Test with coordinates from known resorts (e.g., Whistler, Vail) — confirm `CLPlacemark.name` returns resort name before `locality` fallback |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 45s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
