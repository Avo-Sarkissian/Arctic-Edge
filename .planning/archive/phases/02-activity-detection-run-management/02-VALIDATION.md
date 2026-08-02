---
phase: 2
slug: activity-detection-run-management
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-09
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Swift Testing (`import Testing`) |
| **Config file** | None (Xcode scheme-based) |
| **Quick run command** | `xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:ArcticEdgeTests/ActivityClassifierTests 2>&1 \| grep -E "Test\|error\|passed\|failed"` |
| **Full suite command** | `xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 \| grep -E "Test Suite\|passed\|failed"` |
| **Estimated runtime** | ~10 seconds (quick), ~60 seconds (full) |

---

## Sampling Rate

- **After every task commit:** Run ActivityClassifierTests only (`quick run command`)
- **After every plan wave:** Run full suite (`full suite command`)
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 10 seconds (quick), 60 seconds (full)

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 02-01-01 | 01 | 0 | DETC-01, DETC-02, DETC-03 | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests` | ❌ Wave 0 | ⬜ pending |
| 02-01-02 | 01 | 1 | DETC-01 | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testSkiingClassification` | ❌ Wave 0 | ⬜ pending |
| 02-01-03 | 01 | 1 | DETC-01 | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testChairliftRequiresAllThreeSignals` | ❌ Wave 0 | ⬜ pending |
| 02-01-04 | 01 | 1 | DETC-01 | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testTwoOfThreeInsufficientForChairlift` | ❌ Wave 0 | ⬜ pending |
| 02-01-05 | 01 | 1 | DETC-01 | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testGPSBlackoutSustainsChairlift` | ❌ Wave 0 | ⬜ pending |
| 02-01-06 | 01 | 1 | DETC-02 | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testShortSignalDoesNotTransition` | ❌ Wave 0 | ⬜ pending |
| 02-01-07 | 01 | 1 | DETC-02 | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testFullHysteresisWindowTriggersTransition` | ❌ Wave 0 | ⬜ pending |
| 02-01-08 | 01 | 1 | DETC-02 | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testBriefStopDoesNotEndRun` | ❌ Wave 0 | ⬜ pending |
| 02-01-09 | 01 | 1 | DETC-03 | integration | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testConfirmedSkiingCreatesRunRecord` | ❌ Wave 0 | ⬜ pending |
| 02-01-10 | 01 | 1 | DETC-03 | integration | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testTransitionFinalizesRunRecord` | ❌ Wave 0 | ⬜ pending |
| 02-01-11 | 01 | 1 | DETC-03 | integration | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testEndDayFinalizesOpenRun` | ❌ Wave 0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `ArcticEdgeTests/Activity/ActivityClassifierTests.swift` — stubs for DETC-01, DETC-02, DETC-03 (pure logic tests with mock GPS + activity injection)
- [ ] `ArcticEdgeTests/Activity/ActivityManagerTests.swift` — covers CMMotionActivityManager mock bridge
- [ ] `ArcticEdgeTests/Location/GPSManagerTests.swift` — covers GPSReading model, speed validation logic
- [ ] `ArcticEdgeTests/Helpers/MockGPSManager.swift` — injectable protocol for ActivityClassifier tests
- [ ] `ArcticEdgeTests/Helpers/MockActivityManager.swift` — injectable protocol for ActivityClassifier tests

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| CMMotionActivity.automotive fires on real chairlift | DETC-01 | CMMotionActivityManager returns nothing on simulator | On-mountain Phase 4: ride chairlift, observe debug HUD shows CHAIRLIFT state with all 3 signals lit |
| Speed thresholds calibrated for real terrain | DETC-01, DETC-02 | Simulator speed injection uses hardcoded values; real GPS on terrain may differ | Phase 4 on-mountain: monitor debug HUD, verify transitions at expected speed boundaries |
| Debug HUD shows all three signal contributions | DETC-01 | UI/visual verification | Tap start day, begin moving — HUD must show GPS speed, g-force variance, CMMotionActivity as live values |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s (quick), < 60s (full)
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
