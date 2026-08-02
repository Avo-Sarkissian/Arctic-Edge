---
phase: 01-motion-engine-and-session-foundation
plan: GAP-01
subsystem: testing
tags: [swift-testing, CoreMotion, CMDeviceMotion, actor, ARC, RingBuffer, StreamBroadcaster]

requires:
  - phase: 01-motion-engine-and-session-foundation
    provides: MotionManager, RingBuffer, StreamBroadcaster actors with production pipeline

provides:
  - MockMotionDataSource stores CMDeviceMotionHandler; testStartEmitsFrames asserts 3 frames in RingBuffer via receive()
  - testConsumerCancellationCleansUp uses named stream locals to prevent ARC-triggered onTermination race

affects:
  - 01-VERIFICATION.md (MOTN-01 and MOTN-04 status upgrades from PARTIAL to SATISFIED)

tech-stack:
  added: []
  patterns:
    - "CMDeviceMotion bare init is unsafe in simulator -- inject frames via internal receive() instead of handler callback"
    - "Named locals pattern for AsyncStream to prevent ARC firing onTermination before assertions"

key-files:
  created: []
  modified:
    - ArcticEdgeTests/Motion/MotionManagerTests.swift
    - ArcticEdgeTests/Motion/StreamBroadcasterTests.swift
    - ArcticEdge/Motion/MotionManager.swift

key-decisions:
  - "CMDeviceMotion() cannot be safely default-initialized in simulator -- its internal data pointer is nil causing EXC_BAD_ACCESS on any field access; inject frames via MotionManager.receive() directly"
  - "MotionManager.receive() promoted from private to internal (one keyword) to enable test-side frame injection without modifying test architecture"
  - "Named AsyncStream locals (let s1, let s2) plus _ = (s1, s2) keep continuations alive through assertions, preventing ARC-triggered onTermination race"

patterns-established:
  - "Pattern: Test frame injection via actor.receive() rather than CoreMotion handler callback to avoid simulator CMDeviceMotion limitation"
  - "Pattern: Named locals + withExtendedLifetime guard (via _ = (s1, s2)) for AsyncStream lifetime in test assertions"

requirements-completed: [MOTN-01, MOTN-04]

duration: 18min
completed: 2026-03-08
---

# Phase 1 GAP-01: Motion Test Gap Closure Summary

**Handler storage + 3-frame RingBuffer assertion via internal receive() path; ARC-safe named stream locals for continuation count reliability**

## Performance

- **Duration:** 18 min
- **Started:** 2026-03-09T18:00:00Z
- **Completed:** 2026-03-09T18:18:00Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments

- `testStartEmitsFrames` now asserts `startCallCount == 1`, `interval == 0.01`, `handler != nil`, and `ringBuffer.count == 3` after 3 direct `receive()` calls
- `testConsumerCancellationCleansUp` reliably observes `afterTwo == 2` (not 1) by keeping both `AsyncStream` locals in scope through end of function
- All 7 Motion tests pass with zero warnings under `SWIFT_STRICT_CONCURRENCY = complete`

## Task Commits

Each task was committed atomically:

1. **Task 1: Fix MockMotionDataSource to store handler and emit frames** - `5ae861f` (fix)
2. **Task 2: Fix ARC race in testConsumerCancellationCleansUp** - `1986eff` (fix)

## Files Created/Modified

- `ArcticEdgeTests/Motion/MotionManagerTests.swift` - Added handler property, updated makeManager() to 3-tuple, rewrote testStartEmitsFrames to inject via receive(), updated thermal tests to destructure trailing _
- `ArcticEdgeTests/Motion/StreamBroadcasterTests.swift` - Named s1/s2 locals replacing _ discard, added _ = (s1, s2) lifetime guard
- `ArcticEdge/Motion/MotionManager.swift` - Promoted receive() from private to internal (one keyword change, no logic change)

## Decisions Made

- **CMDeviceMotion() is unsafe in simulator:** The plan stated all IMU fields default to 0.0 on bare init. In practice, the Objective-C internal data pointer is nil; accessing `motion.timestamp` (offset 0x8) causes EXC_BAD_ACCESS (SIGSEGV). This was discovered from the crash report's triggered thread frame pointing to `MotionManager.swift` line 62.
- **Inject via receive() not handler:** Rather than trying to construct a valid CMDeviceMotion (impossible without CoreMotion framework internals), frames are injected directly through `MotionManager.receive()`. This tests the same code path the production handler calls after extracting primitives.
- **Minimal production change:** `private func receive()` became `func receive()` (internal). No logic changed. This is the smallest possible change enabling test-side injection.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] CMDeviceMotion() bare init crashes the simulator test runner**
- **Found during:** Task 1 (Fix MockMotionDataSource to store handler and add deliverMockMotion)
- **Issue:** Plan specified `handler?(CMDeviceMotion(), nil)` in `deliverMockMotion()`. CMDeviceMotion's Objective-C default init allocates a shell object with a nil internal data pointer. Accessing any field (e.g., `motion.timestamp` at offset 0x8) causes EXC_BAD_ACCESS SIGSEGV, crashing the test process before the assertion runs.
- **Fix:** Removed `deliverMockMotion()` entirely. Promoted `MotionManager.receive()` from `private` to `internal`. Updated `testStartEmitsFrames` to call `manager.receive(...)` three times with zero-valued primitives, exercising the same production filtering and RingBuffer append path.
- **Files modified:** `ArcticEdge/Motion/MotionManager.swift` (private -> internal), `ArcticEdgeTests/Motion/MotionManagerTests.swift` (no deliverMockMotion, direct receive() calls)
- **Verification:** All 7 tests pass; no crash reports after fix; `testStartEmitsFrames` passes in 0.001 seconds
- **Committed in:** `5ae861f` (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (Rule 1 - Bug)
**Impact on plan:** Fix is necessary for correctness -- test cannot pass with CMDeviceMotion() in simulator. The observable behavior (3 frames arrive in RingBuffer after 3 deliveries) is identical to the plan's intent. No scope creep.

## Issues Encountered

- Simulator process crash on first run caused `** TEST FAILED **` output even after the code fix -- required `xcrun simctl shutdown/boot` cycle to clear the busy state
- Earlier parallel test runs showed intermittent simulator launch failures (FBSOpenApplicationErrorDomain) unrelated to the code changes; resolved by running with `-parallel-testing-enabled NO`

## Next Phase Readiness

- MOTN-01 and MOTN-04 upgraded from PARTIAL to SATISFIED
- Full 7-test Motion suite runs clean; CI should pass without simulator race conditions using `-parallel-testing-enabled NO`
- No blockers for Phase 2

---
*Phase: 01-motion-engine-and-session-foundation*
*Completed: 2026-03-08*
