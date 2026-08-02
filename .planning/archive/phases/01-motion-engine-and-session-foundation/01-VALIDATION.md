---
phase: 1
slug: motion-engine-and-session-foundation
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-08
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Swift Testing (`import Testing`) |
| **Config file** | None — detected automatically by Xcode 26 |
| **Quick run command** | `xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:ArcticEdgeTests` |
| **Full suite command** | `xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` |
| **Estimated runtime** | ~30 seconds (unit tests only; HealthKit tests are manual on device) |

**Note:** HealthKit and CMMotionManager do not function in Simulator. Tests for WorkoutSessionManager integration (SESS-01) must be verified manually on a physical iPhone 16 Pro. All other components are fully testable in Simulator.

---

## Sampling Rate

- **After every task commit:** Run the specific test file for the component just built
- **After every plan wave:** Run full `xcodebuild test` suite (all automated tests)
- **Before `/gsd:verify-work`:** Full suite must be green + manual HKWorkoutSession background test on physical iPhone 16 Pro
- **Max feedback latency:** ~30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| FilteredFrame struct | 01-01 | 1 | MOTN-01 | unit | `-only-testing:ArcticEdgeTests/MotionManagerTests` | Wave 0 | pending |
| BiquadHighPassFilter | 01-01 | 1 | MOTN-02 | unit | `-only-testing:ArcticEdgeTests/BiquadFilterTests` | Wave 0 | pending |
| RingBuffer actor | 01-01 | 1 | MOTN-03 | unit | `-only-testing:ArcticEdgeTests/RingBufferTests` | Wave 0 | pending |
| MotionManager actor | 01-01 | 1 | MOTN-01, MOTN-05 | unit | `-only-testing:ArcticEdgeTests/MotionManagerTests` | Wave 0 | pending |
| StreamBroadcaster actor | 01-01 | 1 | MOTN-04 | unit | `-only-testing:ArcticEdgeTests/StreamBroadcasterTests` | Wave 0 | pending |
| Thermal throttling | 01-01 | 1 | MOTN-05 | unit | `-only-testing:ArcticEdgeTests/MotionManagerTests` | Wave 0 | pending |
| WorkoutSessionManager | 01-02 | 2 | SESS-01, SESS-05 | manual + unit | manual on device; `-only-testing:ArcticEdgeTests/WorkoutSessionManagerTests` | Wave 0 | pending |
| PersistenceService | 01-02 | 2 | SESS-02, SESS-03, SESS-04 | unit | `-only-testing:ArcticEdgeTests/PersistenceServiceTests` | Wave 0 | pending |
| SwiftData schema | 01-02 | 2 | SESS-03 | unit | `-only-testing:ArcticEdgeTests/PersistenceServiceTests` | Wave 0 | pending |
| Emergency flush | 01-02 | 2 | SESS-04 | unit | `-only-testing:ArcticEdgeTests/PersistenceServiceTests` | Wave 0 | pending |
| Orphan recovery | 01-02 | 2 | SESS-05 | unit | `-only-testing:ArcticEdgeTests/WorkoutSessionManagerTests` | Wave 0 | pending |

*Status: pending / green / red / flaky*

---

## Wave 0 Requirements

- [ ] `SWIFT_STRICT_CONCURRENCY = complete` set in `project.pbxproj` before any actor code is written
- [ ] `ArcticEdgeTests/Motion/BiquadFilterTests.swift` — stubs for MOTN-02; synthetic 100Hz sine at 0.3Hz (reject) and 5Hz (pass)
- [ ] `ArcticEdgeTests/Motion/RingBufferTests.swift` — stubs for MOTN-03; concurrent append+drain actor stress test
- [ ] `ArcticEdgeTests/Motion/MotionManagerTests.swift` — stubs for MOTN-01, MOTN-05; CMMotionManager protocol wrapper for mocking
- [ ] `ArcticEdgeTests/Motion/StreamBroadcasterTests.swift` — stubs for MOTN-04; verifies two AsyncStream consumers receive same frames
- [ ] `ArcticEdgeTests/Session/PersistenceServiceTests.swift` — stubs for SESS-02, SESS-03, SESS-04; in-memory ModelContainer setup
- [ ] `ArcticEdgeTests/Session/WorkoutSessionManagerTests.swift` — stubs for SESS-05; UserDefaults sentinel lifecycle

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| HKWorkoutSession reaches .running state | SESS-01 | HealthKit unavailable in Simulator | Launch on physical iPhone 16 Pro, start a workout session, confirm state reaches .running in Xcode debugger |
| Sensor capture active with screen locked | SESS-01 | Requires physical device + screen lock | Start session, lock screen for 60 seconds, unlock, verify FrameRecords were written to SwiftData during that period |

---

## Validation Sign-Off

- [ ] All tasks have automated verify or Wave 0 dependencies listed above
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
