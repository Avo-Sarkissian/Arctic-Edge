---
phase: 01-motion-engine-and-session-foundation
verified: 2026-03-08T00:00:00Z
status: gaps_found
score: 8/10 truths verified
re_verification: false
gaps:
  - truth: "CMDeviceMotion is read at 100Hz and emitted as FilteredFrame without any Sendable violations at build time"
    status: partial
    reason: "The 100Hz interval and Sendable-safe primitive extraction bridge are correctly implemented. However, testStartEmitsFrames does not verify that frames actually flow through the pipeline end-to-end: MockMotionDataSource discards the CMDeviceMotionHandler without storing it, so no test drives 3 mock callbacks and asserts 3 FilteredFrames arrive. The PLAN truth 'mock MotionDataSource delivers 3 motion callbacks; assert 3 FilteredFrame values on stream' is not realized in the test."
    artifacts:
      - path: "ArcticEdgeTests/Motion/MotionManagerTests.swift"
        issue: "MockMotionDataSource.startDeviceMotionUpdates increments startCallCount but does not store the handler closure. testStartEmitsFrames asserts startCallCount == 1 and interval == 0.01 only; it does not verify frame emission."
    missing:
      - "Store handler in MockMotionDataSource: nonisolated(unsafe) var handler: CMDeviceMotionHandler?"
      - "Add deliverMockMotion() method that invokes the stored handler with a constructed CMDeviceMotion equivalent or a test shim"
      - "Update testStartEmitsFrames to call deliverMockMotion 3 times and assert RingBuffer (or StreamBroadcaster consumer) receives 3 frames"
  - truth: "StreamBroadcaster delivers identical frames to two independent AsyncStream consumers without calling CMMotionManager start more than once"
    status: partial
    reason: "testTwoConsumersReceiveSameFrames and testSingleMotionManagerStart both pass correctly. However testConsumerCancellationCleansUp contains a known bug: both makeStream() calls use the discard pattern (_ = await broadcaster2.makeStream()), which causes ARC to immediately release each AsyncStream, triggering onTermination and removing each continuation before the count assertion runs. The test asserts afterTwo == 2 but in practice observes afterTwo == 1. This is documented in deferred-items.md but has not been fixed."
    artifacts:
      - path: "ArcticEdgeTests/Motion/StreamBroadcasterTests.swift"
        issue: "Lines 89-90: _ = await broadcaster2.makeStream() discards stream immediately. ARC deallocation triggers onTermination removing the continuation. afterTwo assertion is unreliable and expected to fail."
    missing:
      - "Change lines 89-90 to: let s1 = await broadcaster2.makeStream() / let s2 = await broadcaster2.makeStream()"
      - "Keep s1 and s2 in scope until after the afterTwo == 2 assertion"
      - "Remove the _ = discard pattern that is the root cause of the flakiness"
human_verification:
  - test: "HKWorkoutSession background capture (SESS-01 phase gate)"
    expected: "App logs '.running' state on a physical iPhone 16 Pro. After locking the screen for 60 seconds, Xcode console or Instruments confirms FrameRecords were written during the locked period."
    why_human: "HKWorkoutSession does not function in iOS Simulator. Requires physical iPhone 16 Pro with HealthKit entitlement and a real workout session."
  - test: "Filter carve-pressure isolation in real ski conditions (MOTN-02 calibration)"
    expected: "Filtered acceleration-Z signal preserves carving vibrations (>2Hz) and suppresses body sway (<0.5Hz) on real ski data. Filter cutoff at 1.0Hz achieves approximately 21dB rejection at 0.3Hz — adequate for development but requiring real-data calibration to confirm 40dB goal is not needed."
    why_human: "Cannot verify signal quality on real IMU data from a ski without a physical device and mountain session."
  - test: "Orphan recovery on unclean exit (SESS-05 manual)"
    expected: "Force-quit app without ending session. Relaunch: console logs 'orphaned session detected' and UserDefaults sentinel is cleared."
    why_human: "Force-quit lifecycle cannot be reliably simulated in automated tests; requires manual verification on device."
  - test: "Emergency flush on screen lock (SESS-04 manual)"
    expected: "Lock phone mid-session. Unlock and verify FrameRecords were written during the locked period via SwiftData query or Xcode Instruments."
    why_human: "UIApplication.didEnterBackgroundNotification behavior and background execution time require on-device verification."
---

# Phase 1: Motion Engine and Session Foundation — Verification Report

**Phase Goal:** The full sensor pipeline runs correctly under strict concurrency, with no data loss and no main-thread interference
**Verified:** 2026-03-08
**Status:** gaps_found
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths

The five success criteria from ROADMAP.md are mapped first, then the plan-specific truths are assessed.

**ROADMAP Success Criteria:**

| # | Success Criterion | Status | Evidence |
|---|-------------------|--------|----------|
| SC-1 | App reads CMDeviceMotion at 100Hz; stream reaches downstream consumers without Sendable violations at build time | PARTIAL | 100Hz interval set, Sendable bridge present, builds clean. But no test drives mock frames through the pipeline end-to-end. |
| SC-2 | High-pass filter isolates carve-pressure signal from body sway with no frame drops in ring buffer during sustained 100Hz ingestion | VERIFIED (automated partial) | BiquadHighPassFilter tested: 5Hz passes (>90%), 0.3Hz attenuated (~9%, ~21dB). No frame-drop test at sustained 100Hz; requires human verification on device. |
| SC-3 | Sensor frames persisted in batches to SwiftData with no main-thread blocking | VERIFIED | PersistenceService is @ModelActor; testBatchFlushSingleSave (500 frames, 500 FrameRecords), testNoMainThreadSave (detached task, no deadlock). Single modelContext.save() per batch confirmed. |
| SC-4 | Sensor capture remains active when screen locks | HUMAN NEEDED | HKWorkoutSession + background execution require physical iPhone 16 Pro. WorkoutSessionManager implemented; mock sentinel tests pass. |
| SC-5 | App detects and recovers orphaned HKWorkoutSession on relaunch | VERIFIED (automated) | testOrphanDetectedOnRelaunch and testCleanLaunchNoOrphan pass. recoverOrphanedSession() clears sentinel. ArcticEdgeApp checks sentinel in setupPipelineAsync(). |

**Plan 01-01 Truths (must_haves):**

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| T1 | CMDeviceMotion read at 100Hz, emitted as FilteredFrame, no Sendable violations | PARTIAL | Interval set to 1/100.0. Primitive extraction bridge via Task{await self.receive()} present. But testStartEmitsFrames does not verify end-to-end frame emission — handler not stored in mock. |
| T2 | High-pass biquad passes 5Hz sinusoid, attenuates 0.3Hz by at least 40dB | PARTIAL | 5Hz passes at >90% RMS. 0.3Hz attenuated to ~9% (~21dB). Plan truth of 40dB is unachievable with a single 2nd-order section at fc=1.0Hz. Test threshold relaxed to <15% (>16dB). REQUIREMENTS.md says "reject <0.5Hz" without specifying dB — requirement text is met. |
| T3 | RingBuffer drain() atomically returns all buffered frames with no samples lost | VERIFIED | drain() body is fully synchronous (no await). All 4 RingBufferTests pass: drain returns all, drain empties, capacity drops oldest, concurrent stress never exceeds capacity. |
| T4 | StreamBroadcaster delivers identical frames to two consumers without calling start more than once | PARTIAL | testTwoConsumersReceiveSameFrames and testSingleMotionManagerStart pass. testConsumerCancellationCleansUp has a known bug (discard pattern causes ARC-triggered onTermination before count assertion). |
| T5 | Thermal state change adjusts interval to 50Hz (serious) or 25Hz (critical) | VERIFIED | adjustSampleRate() switches on ProcessInfo.ThermalState. All three thermal interval tests pass: nominal=0.01, serious=0.02, critical=0.04. Notification observer wired in observeThermalState(). |

**Plan 01-02 Truths (must_haves):**

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| T6 | HKWorkoutSession reaches .running before CMMotionManager.startDeviceMotionUpdates is called | VERIFIED | startSession() in ArcticEdgeApp: (1) workoutSessionManager.start() awaited first, (2) broadcaster.start(runID:) called after. WorkoutSessionManager.start() sets sentinel, then awaits session.start(on:). Ordering enforced by sequential await chain. |
| T7 | PersistenceService flushes 500 FilteredFrames in single modelContext.save() | VERIFIED | flush() sets autosaveEnabled=false, inserts all FrameRecords in loop, then calls single try modelContext.save(). testBatchFlushSingleSave confirms 500 frames -> 500 FrameRecords. |
| T8 | FrameRecord SwiftData schema has #Index on timestamp, runID, and composite (runID, timestamp) | VERIFIED | Line 13 of FrameRecord.swift: #Index<FrameRecord>([\.timestamp], [\.runID], [\.runID, \.timestamp]). testFrameRecordIndexExists confirms FetchDescriptor sort on both columns succeeds. |
| T9 | applicationDidEnterBackground triggers emergency flush that drains ring buffer | VERIFIED | UIApplication.didEnterBackgroundNotification and willTerminateNotification both wired in setupLifecycleObservers(). Each fires Task.detached { try? await service.emergencyFlush(ringBuffer: rb) }. testEmergencyFlushDrainsRingBuffer passes: 200 frames drained, ringBuffer.count == 0, 200 FrameRecords in SwiftData. |
| T10 | UserDefaults sentinel set on start, cleared on end, detected on relaunch after crash | VERIFIED | WorkoutSessionManager.start() sets sentinel BEFORE awaiting .running. end() calls removeObject(). recoverOrphanedSession() clears sentinel. All 4 WorkoutSessionManagerTests pass. ArcticEdgeApp reads sentinel in setupPipelineAsync(). |

**Overall Score: 8/10 truths verified** (T1 and T4 are partial due to test coverage gaps; T2 is verified with documented threshold deviation)

---

## Required Artifacts

### Plan 01-01 Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `ArcticEdge/Motion/FilteredFrame.swift` | Sendable value type with 15 IMU fields | VERIFIED | 15 let properties, nonisolated struct, explicit Sendable. All fields match plan spec. |
| `ArcticEdge/Motion/BiquadHighPassFilter.swift` | vDSP.Biquad HPF wrapper, Audio EQ Cookbook coefficients | VERIFIED | vDSP.Biquad initialized with 5-coefficient array [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]. kFilterCutoffHz = 1.0 module-level constant. nonisolated(unsafe) on filter property. |
| `ArcticEdge/Motion/RingBuffer.swift` | Actor, capacity 1000, O(1) append, synchronous drain | VERIFIED | actor RingBuffer. capacity = 1000. drain() body: let chunk = buffer; buffer = []; return chunk — no await inside. |
| `ArcticEdge/Motion/MotionManager.swift` | Actor owning CMMotionManager, thermal throttling, AsyncStream emission | VERIFIED | actor MotionManager. MotionDataSource protocol. adjustSampleRate(for:). Task{await self.receive()} bridge. Optional broadcaster ref. |
| `ArcticEdge/Motion/StreamBroadcaster.swift` | Actor fanning out FilteredFrame to multiple AsyncStream consumers | VERIFIED | actor StreamBroadcaster. [UUID: AsyncStream<FilteredFrame>.Continuation]. broadcast() yields to all. start() is idempotent via isStarted flag. |
| `ArcticEdgeTests/Motion/BiquadFilterTests.swift` | Real assertions, no stubs | VERIFIED | 3 tests. No Bool(false) stubs. testHighFrequencyPasses, testLowFrequencyRejects, testInitDoesNotCrash all have real assertions. |
| `ArcticEdgeTests/Motion/RingBufferTests.swift` | Real assertions, no stubs | VERIFIED | 4 tests with real assertions. No stubs. |
| `ArcticEdgeTests/Motion/MotionManagerTests.swift` | Real assertions covering MOTN-01 and MOTN-05 | PARTIAL | 4 tests. No stubs. But testStartEmitsFrames only asserts startCallCount==1 and interval==0.01 — does not verify frame emission end-to-end. MockMotionDataSource does not store the handler. |
| `ArcticEdgeTests/Motion/StreamBroadcasterTests.swift` | Real assertions covering MOTN-04 | PARTIAL | 3 tests. testTwoConsumersReceiveSameFrames and testSingleMotionManagerStart have real assertions. testConsumerCancellationCleansUp uses discard pattern causing ARC race — known to produce afterTwo==1 instead of 2. |

### Plan 01-02 Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `ArcticEdge/Schema/FrameRecord.swift` | @Model with #Index on timestamp, runID, composite | VERIFIED | #Index<FrameRecord>([\.timestamp], [\.runID], [\.runID, \.timestamp]). 15 var fields. init(from: FilteredFrame) copies all fields. |
| `ArcticEdge/Schema/RunRecord.swift` | @Model with #Index on runID and startTimestamp, isOrphaned flag | VERIFIED | #Index<RunRecord>([\.runID], [\.startTimestamp]). isOrphaned: Bool present. endTimestamp: Date? present. |
| `ArcticEdge/Session/PersistenceService.swift` | @ModelActor, batched flush, autosaveEnabled=false | VERIFIED | @ModelActor actor. flush() sets autosaveEnabled=false, batch inserts, single save(). emergencyFlush() awaits ringBuffer.drain() then flush(). |
| `ArcticEdge/Session/WorkoutSessionManager.swift` | HKWorkoutSession lifecycle, WorkoutSessionProtocol injection, sentinel | VERIFIED | actor WorkoutSessionManager. WorkoutSessionProtocol. HKWorkoutSessionWrapper. NSLock bridge. Sentinel set before awaiting .running. |
| `ArcticEdge/ArcticEdgeApp.swift` | ModelContainer setup, lifecycle observers, orphan recovery on launch | VERIFIED | AppModel @Observable. ModelContainer with FrameRecord+RunRecord schema. emergencyFlush wired to didEnterBackground and willTerminate. Sentinel checked in setupPipelineAsync(). |
| `ArcticEdgeTests/Session/PersistenceServiceTests.swift` | Tests for SESS-02, SESS-03, SESS-04, in-memory container | VERIFIED | 4 tests. makeInMemoryContainer(). testBatchFlushSingleSave, testFrameRecordIndexExists, testEmergencyFlushDrainsRingBuffer, testNoMainThreadSave. No stubs. |
| `ArcticEdgeTests/Session/WorkoutSessionManagerTests.swift` | Tests for SESS-05 sentinel lifecycle | VERIFIED | 4 tests. MockWorkoutSession. testSentinelSetOnStart, testSentinelClearedOnEnd, testOrphanDetectedOnRelaunch, testCleanLaunchNoOrphan. No stubs. |

---

## Key Link Verification

### Plan 01-01 Key Links

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| CoreMotion callback (OperationQueue thread) | MotionManager actor | Task { await self.receive(...) } after extracting primitives | WIRED | MotionManager.swift line 76-93: all primitives extracted, Task{await self.receive(...)} called. receive() is actor-isolated. |
| MotionManager actor | StreamBroadcaster actor | await broadcaster?.broadcast(frame) after filtering | WIRED | MotionManager.swift line 134: await broadcaster?.broadcast(frame) called inside actor-isolated receive(). |
| StreamBroadcaster.makeStream() | consumer AsyncStream | continuation.yield(frame) stored per UUID | WIRED | StreamBroadcaster.swift line 51: continuation.yield(frame) called for all continuations.values in broadcast(). onTermination removes via Task{await self.removeContinuation(id:)}. |
| ProcessInfo.thermalStateDidChangeNotification | motionManager.deviceMotionUpdateInterval | Task { await self?.adjustSampleRate(for:) } | WIRED | MotionManager.swift lines 139-145: NotificationCenter observer captures state from ProcessInfo, bridges via Task{await self?.adjustSampleRate(for: state)}. |

### Plan 01-02 Key Links

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| ArcticEdgeApp.swift (startup) | WorkoutSessionManager.recoverOrphanedSession() | UserDefaults sentinel check bool(forKey: sessionInProgress) | WIRED | ArcticEdgeApp.swift lines 87-90: setupPipelineAsync() reads UserDefaults.standard.bool(forKey: kSessionSentinelKey); if true, calls await workoutSessionManager.recoverOrphanedSession(). |
| WorkoutSessionManager.start() | UserDefaults.standard.set(true, forKey: sessionInProgress) | Called immediately before awaiting .running | WIRED | WorkoutSessionManager.swift line 130: UserDefaults.standard.set(true, forKey: kSessionSentinelKey) called at top of start(), before any await. |
| UIApplication.didEnterBackgroundNotification | PersistenceService.emergencyFlush(ringBuffer:) | Task.detached { try? await service.emergencyFlush(ringBuffer: rb) } | WIRED | ArcticEdgeApp.swift lines 101-110: NotificationCenter observer for didEnterBackgroundNotification fires Task.detached emergencyFlush. willTerminateNotification also wired identically (lines 112-120). |
| PersistenceService.flush(frames:) | modelContext.save() | batch insert loop then single save call; autosaveEnabled = false | WIRED | PersistenceService.swift lines 19-25: autosaveEnabled=false, for loop inserts, single try modelContext.save(). Confirmed by testBatchFlushSingleSave. |

---

## Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|---------|
| MOTN-01 | 01-01 | 100Hz CMDeviceMotion via MotionManager actor using Swift 7 AsyncStream | PARTIAL | 100Hz interval set. Sendable bridge implemented. No end-to-end test drives mock frames through pipeline. testStartEmitsFrames does not verify frame arrival. |
| MOTN-02 | 01-01 | High-pass biquad filter: preserve >2Hz, reject <0.5Hz | SATISFIED | BiquadHighPassFilter implemented with vDSP.Biquad. 5Hz passes at >90% RMS. 0.3Hz rejected to ~9% (~21dB). REQUIREMENTS.md text "reject <0.5Hz" is met; 40dB plan spec was unphysical for single 2nd-order section. |
| MOTN-03 | 01-01 | Ring buffer: 1000 samples, synchronous transactional drain | SATISFIED | actor RingBuffer, capacity=1000, drain() has no await in body. All 4 RingBufferTests green. |
| MOTN-04 | 01-01 | StreamBroadcaster fans out to LiveViewModel and ActivityClassifier without double-starting CMMotionManager | PARTIAL | Fan-out architecture correct. testTwoConsumersReceiveSameFrames and testSingleMotionManagerStart pass. testConsumerCancellationCleansUp is broken by discard pattern. |
| MOTN-05 | 01-01 | Thermal throttling: 100Hz -> 50Hz -> 25Hz at thermal state critical | SATISFIED | adjustSampleRate() switches on ThermalState. All 3 thermal interval tests pass. Notification observer registered in observeThermalState(). |
| SESS-01 | 01-02 | HKWorkoutSession provides background CPU budget; sensor capture active when screen locks | SATISFIED (automated partial) | WorkoutSessionManager.start() awaited before broadcaster.start() in startSession(). startSession() ordering enforced. Actual background execution requires human verification on physical device. |
| SESS-02 | 01-02 | SwiftData persists frames in batches; never per-frame; flush every 200-500 samples | SATISFIED | flush() is batch-only. Periodic flush task checks count >= 200 before draining. testBatchFlushSingleSave: 500 frames -> single save -> 500 FrameRecords. |
| SESS-03 | 01-02 | FrameRecord schema with #Index on timestamp and runID | SATISFIED | #Index<FrameRecord>([\.timestamp], [\.runID], [\.runID, \.timestamp]) present. testFrameRecordIndexExists confirms FetchDescriptor sorts without error. |
| SESS-04 | 01-02 | Emergency flush on applicationDidEnterBackground and applicationWillTerminate | SATISFIED | Both notifications wired in setupLifecycleObservers(). testEmergencyFlushDrainsRingBuffer: 200 frames -> drain -> 0 in buffer -> 200 FrameRecords persisted. |
| SESS-05 | 01-02 | Orphan detection and recovery on launch via UserDefaults sentinel | SATISFIED | Sentinel set before .running, cleared on clean end, detected in setupPipelineAsync(), recovered via recoverOrphanedSession(). All 4 WorkoutSessionManagerTests pass. |

**All 10 requirements have been addressed. MOTN-01 and MOTN-04 are PARTIAL due to incomplete test coverage, not missing implementation.**

---

## Build Settings Verification

| Setting | Required | Actual | Status |
|---------|----------|--------|--------|
| SWIFT_STRICT_CONCURRENCY | complete (all configs) | complete (6 occurrences in project.pbxproj) | VERIFIED |
| SWIFT_VERSION | 6.0 (all configs) | 6.0 (6 occurrences in project.pbxproj) | VERIFIED |
| SWIFT_DEFAULT_ACTOR_ISOLATION | (observed) | MainActor (2 occurrences — main target only) | INFO — present, handled throughout with nonisolated annotations |

---

## Anti-Patterns Found

| File | Pattern | Severity | Impact |
|------|---------|----------|--------|
| `ArcticEdgeTests/Motion/MotionManagerTests.swift` | MockMotionDataSource discards CMDeviceMotionHandler — startDeviceMotionUpdates increments count but never stores handler | Warning | testStartEmitsFrames cannot verify that frames flow through the pipeline. MOTN-01 test coverage is incomplete. |
| `ArcticEdgeTests/Motion/StreamBroadcasterTests.swift` lines 89-90 | `_ = await broadcaster2.makeStream()` — discard pattern causes ARC-triggered onTermination before count assertion | Blocker (test correctness) | testConsumerCancellationCleansUp produces afterTwo==1 instead of 2; the assertion is expected to fail. Documented in deferred-items.md. |
| `ArcticEdgeTests/Motion/BiquadFilterTests.swift` line 62 | Plan truth specified 40dB rejection at 0.3Hz; threshold relaxed to <15% (~21dB) | Info | Threshold relaxation is physically correct for 2nd-order HPF at fc=1.0Hz. REQUIREMENTS.md requirement text ("reject <0.5Hz") is met. Needs calibration pass with real ski data. |

---

## Human Verification Required

### 1. HKWorkoutSession Background CPU Budget (SESS-01 Phase Gate)

**Test:** On a physical iPhone 16 Pro with HealthKit entitlement, start a session from the app, lock the screen for 60 seconds, then unlock and inspect FrameRecords in SwiftData.
**Expected:** Console logs ".running" state on session start. FrameRecords are present in SwiftData from the screen-locked period, confirming the HKWorkoutSession background execution mode is active.
**Why human:** HKWorkoutSession does not function in iOS Simulator; requires physical device and HealthKit entitlement.

### 2. Filter Signal Quality on Real Ski IMU Data (MOTN-02 Calibration)

**Test:** Collect raw IMU data from a real ski run. Run the data through BiquadHighPassFilter at fc=1.0Hz and inspect the filtered signal for carving vibration preservation vs. body-sway rejection.
**Expected:** Frequencies above 2Hz (carving dynamics) are preserved. Frequencies below 0.5Hz (posture drift) are meaningfully attenuated. Confirm whether 40dB rejection at 0.3Hz is actually required or whether ~21dB is adequate.
**Why human:** Real ski IMU data is required; synthetic sine tests cannot capture multi-frequency real-world signal characteristics.

### 3. Orphan Recovery on Force-Quit (SESS-05 Manual)

**Test:** Start a session, then force-quit the app from the app switcher without ending the session. Relaunch the app.
**Expected:** Console logs "[WorkoutSessionManager] Orphaned session detected. Sentinel cleared." UserDefaults sentinel is false after relaunch.
**Why human:** Force-quit cannot be reliably simulated in automated tests.

### 4. Emergency Flush on Screen Lock (SESS-04 Manual)

**Test:** Start a session, lock the phone screen for 30 seconds, unlock, and query SwiftData for FrameRecords.
**Expected:** FrameRecords are present from the locked period, confirming the didEnterBackgroundNotification emergency flush executed and background execution time was sufficient.
**Why human:** UIApplication.didEnterBackgroundNotification and iOS background execution time limits require on-device verification.

---

## Gaps Summary

Two test coverage gaps prevent full automation confidence:

**Gap 1 (MOTN-01 partial): MockMotionDataSource does not deliver frames.** The implementation of MotionManager's CoreMotion bridge is correct — primitive extraction, Task{await self.receive()}, RingBuffer append, and broadcaster fan-out are all wired. However, no automated test drives mock frames through this path. The MockMotionDataSource stores `startCallCount` but discards the CMDeviceMotionHandler. Adding a `handler` property and a `deliverMockMotion()` method would allow testStartEmitsFrames to assert that 3 mock callbacks produce 3 FilteredFrames in the RingBuffer or on a StreamBroadcaster consumer stream.

**Gap 2 (MOTN-04 partial): testConsumerCancellationCleansUp uses discard pattern causing ARC race.** The StreamBroadcaster fan-out and single-start logic are correct and tested. The cancellation cleanup test is broken by `_ = await broadcaster2.makeStream()` — discarding the returned AsyncStream immediately triggers onTermination via ARC, removing the continuation before the count assertion. This is a 2-line fix: store streams in named locals. This test is expected to produce `afterTwo == 1` rather than `2`.

Both gaps are test-coverage issues, not implementation issues. The underlying production code is correct. However, the phase goal states "the full sensor pipeline runs correctly" — without an automated test that delivers frames end-to-end and counts them at the output, this correctness claim rests on code review alone for the critical CoreMotion bridge.

---

_Verified: 2026-03-08_
_Verifier: Claude (gsd-verifier)_
