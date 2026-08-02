# Phase 2: Activity Detection & Run Management - Research

**Researched:** 2026-03-09
**Domain:** CoreLocation (CLLocationUpdate), CoreMotion (CMMotionActivityManager), Swift actor state machine, SwiftUI debug HUD
**Confidence:** HIGH (primary APIs), MEDIUM (chairlift heuristics), LOW (speed threshold calibration)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Session automation model**
- User taps 'Start Day' to arm the classifier — one deliberate action at the trailhead starts GPS + IMU + classifier
- Once armed, ActivityClassifier fully owns run start and end boundaries — no user action per run
- User taps 'End Day' to stop all capture immediately: finalizes any open RunRecord, stops GPS + IMU
- No manual run splitting or boundary override — classifier owns all boundaries (v2 consideration if needed post on-mountain testing)

**Hysteresis philosophy**
- Conservative bias: prefer missing the first frame of a run over recording chairlift data inside a run record
- Asymmetric windows: longer confirmation required for SKIING onset (e.g., 3 sec) than for run END (e.g., 2 sec) — specific values are Claude's calibration targets
- RunRecord is NOT created until the full skiing hysteresis window elapses (no provisional records)
- Frames captured during the hysteresis window are held in memory and attributed to the run once confirmed

**Chairlift detection logic**
- All three signals required to confirm CHAIRLIFT: automotive CMMotionActivity + GPS speed in lift range + low g-force variance
- Two of three is insufficient — prevents false chairlift detection on slow traverses
- Brief stops (stationary mid-run) do not end a run — only the full chairlift signature does
- During GPS blackout (gondola tunnel, enclosed cabin): if already in CHAIRLIFT state, remain in CHAIRLIFT — do not flip back to skiing due to missing GPS; rely on IMU + motion activity to sustain the state

**Debug overlay**
- #if DEBUG only — compiled out of release builds, no gesture gymnastics, no production risk
- Persistent HUD overlaid on ContentView — always visible in debug builds when session is active
- Must show: current classifier state (SKIING / CHAIRLIFT / IDLE), GPS speed, g-force variance, CMMotionActivity label
- Also show hysteresis progress (how far into the confirmation window the current signal is)

### Claude's Discretion
- Specific hysteresis threshold values (calibration targets after on-mountain testing)
- GPS accuracy threshold for trusting speed readings vs falling back to IMU-only
- Exact g-force variance window size (rolling N-frame window)
- CLLocationManager placement in app architecture (likely a new actor, wired into AppModel alongside MotionManager)
- How the ActivityClassifier subscribes to StreamBroadcaster (via makeStream()) and CLLocationManager

### Deferred Ideas (OUT OF SCOPE)
- Manual run splitting / bookmark drops — v2 feature if classifier misses boundaries in real-world testing
- Auto-end session after prolonged inactivity — considered and deferred; user prefers explicit End Day
- On-mountain test harness / labeling pass for filter and hysteresis calibration — Phase 4 (Field Validation)
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| DETC-01 | ActivityClassifier distinguishes active skiing from chairlift rides using fused GPS velocity, g-force variance, and motion activity signature | CLLocationUpdate.liveUpdates() provides GPS speed; CMMotionActivityManager.automotive flag; FilteredFrame provides all IMU data for variance computation |
| DETC-02 | Classifier applies hysteresis — requires N consecutive seconds of consistent state before triggering run start or end (prevents false transitions on slow skiing or brief stops) | Timestamp-based confirmation window pattern using actor-isolated state; academic research confirms 8s windows with 30s minimum duration work well for ski activity detection |
| DETC-03 | Each detected skiing segment is automatically stored as a distinct RunRecord with start timestamp, end timestamp, and runID | PersistenceService.createRunRecord() and finalizeRunRecord() already implemented; ActivityClassifier calls these on state transitions |
</phase_requirements>

---

## Summary

Phase 2 adds three independent signal sources to the existing IMU pipeline — GPS speed from `CLLocationUpdate.liveUpdates()`, motion activity classification from `CMMotionActivityManager`, and g-force variance computed from the existing `FilteredFrame` stream — and fuses them in an `ActivityClassifier` actor whose state machine drives `RunRecord` lifecycle. The classifier is the only component that creates and finalizes `RunRecord` entries; `AppModel` is upgraded from `startSession()`/`endSession()` to `startDay()`/`endDay()` verbs that arm and disarm the classifier.

The core technical complexity is bridging two callback-based Apple frameworks (`CLLocationUpdate` via its native AsyncSequence and `CMMotionActivityManager` via a delegate-callback pattern) into Swift 6 strict-concurrency-clean actors, then fusing three asynchronous signal streams in a single actor's `processFrame()` path. The hysteresis state machine is straightforward to reason about but requires careful timestamp arithmetic to avoid timer-based `Task.sleep` dependencies.

The debug HUD is a #if DEBUG SwiftUI `overlay` on `ContentView` that reads live classifier state from `AppModel` — no gesture unlocking, no production surface.

**Primary recommendation:** Use `CLLocationUpdate.liveUpdates(.otherNavigation)` in a new `GPSManager` actor (NSObject + OSAllocatedUnfairLock pattern), `CMMotionActivityManager` wrapped in a similar `ActivityManager` actor, and fuse all three signals inside `ActivityClassifier`. Keep the hysteresis state machine as pure timestamp arithmetic — no `Timer`, no `Task.sleep`.

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| CoreLocation | iOS 17+ | GPS speed via CLLocationUpdate.liveUpdates() | Native AsyncSequence, no delegate gymnastics, strict-concurrency-friendly |
| CoreMotion (CMMotionActivityManager) | iOS 17+ | Automotive activity classification signal | Only Apple API for activity type classification; no third-party alternative |
| CoreMotion (CMDeviceMotion) | Already wired | G-force variance source (FilteredFrame stream) | Already in place via StreamBroadcaster — no new start needed |
| SwiftData | Already wired | RunRecord persistence | PersistenceService already has createRunRecord/finalizeRunRecord |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Accelerate/vDSP | Already wired | Fast variance computation over rolling window | Use when window size exceeds ~20 samples; vDSP_meanv + variance in one pass |
| OSAllocatedUnfairLock | iOS 16+ | Thread-safe state in NSObject subclasses | Required for CMMotionActivityManager delegate bridge |
| CLBackgroundActivitySession | iOS 17+ | Keep CLLocationUpdate.liveUpdates() alive when screen locks | Required since HKWorkoutSession does not cover GPS background time |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| CLLocationUpdate.liveUpdates() | CLLocationManager + delegate | liveUpdates() is native AsyncSequence — no delegate bridge needed; preferred for Swift 6 |
| OSAllocatedUnfairLock | actor for CMMotionActivityManager | CMMotionActivityManager requires NSObject delegate; cannot be an actor directly |
| Timestamp arithmetic for hysteresis | Task.sleep / Timer | Arithmetic is deterministic and testable; Timer and Task.sleep introduce timing jitter |

**Installation:** No new packages. All APIs are first-party.

---

## Architecture Patterns

### Recommended Project Structure

```
ArcticEdge/
├── Motion/                      # EXISTING — IMU pipeline
│   ├── FilteredFrame.swift
│   ├── MotionManager.swift
│   ├── StreamBroadcaster.swift
│   ├── RingBuffer.swift
│   └── BiquadHighPassFilter.swift
├── Location/                    # NEW — GPS signal source
│   └── GPSManager.swift         # actor wrapping CLLocationUpdate.liveUpdates()
├── Activity/                    # NEW — classification engine
│   ├── ActivityManager.swift    # actor wrapping CMMotionActivityManager callbacks
│   └── ActivityClassifier.swift # actor — state machine + RunRecord lifecycle
├── Schema/                      # EXISTING
│   ├── FrameRecord.swift
│   └── RunRecord.swift
├── Session/                     # EXISTING
│   ├── PersistenceService.swift
│   └── WorkoutSessionManager.swift
└── Debug/                       # NEW
    └── ClassifierDebugHUD.swift  # #if DEBUG SwiftUI view
```

### Pattern 1: GPSManager Actor — CLLocationUpdate.liveUpdates() bridge

**What:** NSObject subclass wrapping CLLocationUpdate's native AsyncSequence, exposed as an `AsyncStream<GPSReading>` for actor-to-actor consumption.

**When to use:** Whenever GPS speed + horizontalAccuracy are needed in a strict-concurrency actor.

CLLocationUpdate is a native AsyncSequence (iOS 17+), so the bridge is cleaner than the CLLocationManager delegate pattern. The key constraints:
- `CLBackgroundActivitySession` must be held as a stored property (deallocation stops updates)
- `CLServiceSession` is required in iOS 18+ for authorization continuity
- `liveUpdates()` yields `update.location` as optional CLLocation — nil when GPS unavailable
- Speed is at `update.location?.speed` (Double, m/s; -1.0 means invalid)
- `horizontalAccuracy < 0` means invalid fix; use as unreliable-GPS gate
- Update rate: ~1-2 Hz in foreground (confirmed empirically)

```swift
// Source: WWDC23 "Discover streamlined location updates" + twocentstudios.com/2024/12/02
actor GPSManager {
    private var backgroundSession: CLBackgroundActivitySession?
    private var streamTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<GPSReading>.Continuation] = [:]

    struct GPSReading: Sendable {
        let speed: Double            // m/s, -1 if invalid
        let horizontalAccuracy: Double  // meters, <0 if invalid
        let timestamp: Date
    }

    func start() {
        backgroundSession = CLBackgroundActivitySession()
        streamTask = Task { [weak self] in
            for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                guard let location = update.location else { continue }
                let reading = GPSReading(
                    speed: location.speed,
                    horizontalAccuracy: location.horizontalAccuracy,
                    timestamp: location.timestamp
                )
                await self?.broadcast(reading)
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        backgroundSession = nil  // deallocation stops background updates
        for continuation in continuations.values { continuation.finish() }
        continuations = [:]
    }

    func makeStream() -> AsyncStream<GPSReading> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<GPSReading>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self, id] _ in
            Task { await self?.removeContinuation(id: id) }
        }
        return stream
    }

    private func broadcast(_ reading: GPSReading) {
        for continuation in continuations.values { continuation.yield(reading) }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
```

**LiveConfiguration choice:** `.otherNavigation` — does not snap coordinates to roads (chairlifts are not on road networks). `.automotiveNavigation` would introduce coordinate snapping artifacts on mountain terrain.

### Pattern 2: ActivityManager Actor — CMMotionActivityManager bridge

**What:** Actor that wraps CMMotionActivityManager's callback-based API into an `AsyncStream<CMMotionActivity>`.

**When to use:** CMMotionActivityManager uses `startActivityUpdates(to:withHandler:)` — a classic callback bridge that cannot be an actor directly (NSObject constraint doesn't apply to CMMotionActivityManager itself, but the handler is a @Sendable closure challenge).

The key insight: CMMotionActivityManager is **not** an NSObject subclass requirement — we can own it from inside an actor. The `startActivityUpdates` handler closure is `@Sendable`, so we can safely capture actor-isolated state by yielding into a continuation.

```swift
// Source: Apple CMMotionActivityManager docs + NSHipster.com/cmmotionactivity
actor ActivityManager {
    private let manager = CMMotionActivityManager()
    private var continuations: [UUID: AsyncStream<CMMotionActivity>.Continuation] = [:]

    func start() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        manager.startActivityUpdates(to: OperationQueue()) { [weak self] activity in
            guard let activity else { return }
            Task { await self?.broadcast(activity) }
        }
    }

    func stop() {
        manager.stopActivityUpdates()
        for continuation in continuations.values { continuation.finish() }
        continuations = [:]
    }

    func makeStream() -> AsyncStream<CMMotionActivity> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<CMMotionActivity>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self, id] _ in
            Task { await self?.removeContinuation(id: id) }
        }
        return stream
    }

    private func broadcast(_ activity: CMMotionActivity) {
        for continuation in continuations.values { continuation.yield(activity) }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
```

**Note on CMMotionActivity.automotive:** This property is `true` when the device detects automobile-like motion. It is NOT officially documented for chairlift use — it fires based on electromagnetic and accelerometer signatures consistent with motorized vehicle travel. The STATE.md correctly flags this as a hypothesis requiring on-mountain validation. In practice, the three-signal gate (automotive + GPS speed + low IMU variance) is the safeguard against false positives.

**CMMotionActivity confidence:** Each activity object has `.confidence` of `.low`, `.medium`, or `.high`. Classifier should weight `.high` and `.medium` automotive reads more heavily than `.low` ones for the chairlift gate.

### Pattern 3: ActivityClassifier Actor — Hysteresis State Machine

**What:** Actor that consumes three AsyncStreams (FilteredFrame from StreamBroadcaster, GPSReading from GPSManager, CMMotionActivity from ActivityManager) and drives RunRecord lifecycle via pure timestamp-based hysteresis.

**State machine states:**
```
IDLE        — no session armed; ignores all signals
UNCERTAIN   — signals are ambiguous; holding previous state
SKIING      — confirmed skiing; RunRecord is open
CHAIRLIFT   — confirmed chairlift; no RunRecord open
```

**Transition logic (conservative bias — locked decision):**

```
IDLE → (startDay called) → CHAIRLIFT (default safe state)
CHAIRLIFT → SKIING:  All skiing signals for >= 3.0s continuously
SKIING → CHAIRLIFT:  All three chairlift signals for >= 2.0s continuously
SKIING → SKIING:     Brief stop mid-run does NOT transition (not all three chairlift signals)
GPS blackout in CHAIRLIFT:  Stay CHAIRLIFT (GPS unavailable = skip GPS gate, retain state)
```

**Hysteresis implementation — timestamp arithmetic, no Task.sleep:**

```swift
// Source: research synthesis — timestamp arithmetic pattern
actor ActivityClassifier {
    private enum ClassifierState { case idle, skiing, chairlift }
    private var state: ClassifierState = .idle

    // Hysteresis windows (Claude's discretion — calibration targets)
    private let skiingOnsetSeconds: Double = 3.0
    private let runEndSeconds: Double = 2.0

    // Pending transition tracking
    private var pendingSkiingOnsetAt: Date? = nil   // nil = not accumulating
    private var pendingRunEndAt: Date? = nil

    // Hysteresis frame buffer (frames held during onset window)
    private var pendingFrames: [FilteredFrame] = []

    // Current run tracking
    private var currentRunID: UUID? = nil

    // Rolling variance window — fixed-size circular buffer of recent g-force samples
    private var varianceWindow: [Double] = []
    private let varianceWindowSize = 50  // 0.5s at 100Hz — Claude's discretion

    // Latest signals from each source (updated asynchronously)
    private var latestGPS: GPSManager.GPSReading? = nil
    private var latestActivity: CMMotionActivity? = nil
}
```

**Key design: three separate consumption tasks, one classifier.**

The classifier starts three Tasks on `startDay()`, each consuming one stream:

```swift
func startDay(
    frameStream: AsyncStream<FilteredFrame>,
    gpsStream: AsyncStream<GPSManager.GPSReading>,
    activityStream: AsyncStream<CMMotionActivity>
) {
    // Three concurrent tasks — each updates a different "latest" property
    Task { for await gps in gpsStream { await self.updateGPS(gps) } }
    Task { for await act in activityStream { await self.updateActivity(act) } }
    Task { for await frame in frameStream { await self.processFrame(frame) } }
}
```

The `processFrame()` path (100Hz) reads the latest GPS and activity snapshots, computes rolling variance from the frame, then evaluates transitions. This avoids needing to synchronize three async sources into one combined event — the IMU stream is the heartbeat; GPS and activity updates are side-channel state.

**G-force variance computation — rolling window:**

```swift
// Within actor isolation — safe to mutate varianceWindow
private func updateVarianceWindow(frame: FilteredFrame) {
    // Use magnitude of user acceleration vector as g-force proxy
    let g = sqrt(frame.userAccelX * frame.userAccelX +
                 frame.userAccelY * frame.userAccelY +
                 frame.userAccelZ * frame.userAccelZ)
    varianceWindow.append(g)
    if varianceWindow.count > varianceWindowSize {
        varianceWindow.removeFirst()
    }
}

private var gForceVariance: Double {
    guard varianceWindow.count > 1 else { return 0 }
    let mean = varianceWindow.reduce(0, +) / Double(varianceWindow.count)
    let sumSq = varianceWindow.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
    return sumSq / Double(varianceWindow.count - 1)
}
```

Note: `varianceWindow.removeFirst()` is O(n) for Array. At 100Hz with a 50-sample window this is 5000 O(n) ops/sec — negligible for this window size. A true circular buffer (like the existing `RingBuffer`) would be more efficient for larger windows; use the same `RingBuffer` pattern if varianceWindowSize grows past ~200 samples.

**Chairlift gate evaluation:**

```swift
// All three signals must be present (locked decision: two-of-three insufficient)
private func chairliftSignalActive(at now: Date) -> Bool {
    // 1. CMMotionActivity automotive flag
    let isAutomotive = (latestActivity?.automotive ?? false) &&
                       (latestActivity?.confidence != .low)

    // 2. GPS speed in lift range (if GPS available)
    let gpsSpeed = latestGPS?.speed ?? -1
    let gpsValid = (latestGPS?.horizontalAccuracy ?? -1) >= 0
    let speedInLiftRange: Bool
    if gpsValid && gpsSpeed >= 0 {
        // Chairlift speed range: ~1–6 m/s (empirical; Claude's calibration target)
        speedInLiftRange = gpsSpeed >= 0.5 && gpsSpeed <= 7.0
    } else {
        // GPS blackout: if already CHAIRLIFT, do NOT block the gate — skip GPS check
        speedInLiftRange = (state == .chairlift)  // sustain on blackout
    }

    // 3. Low g-force variance (low body movement = riding, not carving)
    // Threshold is Claude's calibration target; 0.01 g^2 is starting hypothesis
    let lowVariance = gForceVariance < 0.01

    return isAutomotive && speedInLiftRange && lowVariance
}
```

**Skiing signal evaluation:**

```swift
private func skiingSignalActive() -> Bool {
    // Speed must exceed threshold OR GPS unavailable (trust IMU alone)
    let gpsValid = (latestGPS?.horizontalAccuracy ?? -1) >= 0
    let gpsSpeed = latestGPS?.speed ?? -1
    let speedOK: Bool
    if gpsValid && gpsSpeed >= 0 {
        // Recreational skiing: 5–30+ m/s. Starting threshold: 3 m/s (Claude's target)
        speedOK = gpsSpeed >= 3.0
    } else {
        speedOK = true  // GPS unavailable; don't block skiing detection
    }

    // High g-force variance = body movement = turning/carving
    let highVariance = gForceVariance > 0.005  // Claude's calibration target

    // NOT automotive (or low confidence automotive)
    let notAutomotive = !(latestActivity?.automotive ?? false) ||
                         (latestActivity?.confidence == .low)

    return speedOK && highVariance && notAutomotive
}
```

### Pattern 4: RunRecord lifecycle (driven by ActivityClassifier)

**What:** On CHAIRLIFT→SKIING transition (after full hysteresis), ActivityClassifier:
1. Generates a new `runID = UUID()`
2. Calls `persistenceService.createRunRecord(runID:startTimestamp:)` — sets `startTimestamp` to the timestamp of the FIRST frame in `pendingFrames` (the start of the hysteresis window, not the end)
3. Reassigns `pendingFrames.forEach { frame.runID = runID }` and flushes them to the ring buffer's context
4. Continues attributing incoming frames to this `runID` via `StreamBroadcaster.start(runID:)`

On SKIING→CHAIRLIFT transition (after full hysteresis):
1. Calls `persistenceService.finalizeRunRecord(runID:endTimestamp:)` — sets `endTimestamp` to the last frame timestamp before the hysteresis window started
2. Clears `currentRunID`

**Critical: runID assignment.** `FilteredFrame.runID` is set by `MotionManager.startUpdates(runID:)`. To support ActivityClassifier changing the active runID without restarting the CMMotionManager, consider: the ActivityClassifier owns the current runID and passes it to `StreamBroadcaster.start(runID:)` on each new run. The `StreamBroadcaster.start()` is already idempotent; we need a new method `StreamBroadcaster.setRunID(_:)` that calls through to `motionManager.startUpdates(runID:)` with the new ID without restarting the underlying CMMotionManager.

Alternatively (simpler): ActivityClassifier tracks its own `currentRunID` and stamps incoming frames with it when routing to PersistenceService, ignoring the runID embedded in `FilteredFrame`. This avoids modifying the established `StreamBroadcaster` contract.

**Recommendation:** Have ActivityClassifier hold `currentRunID` and pass it to `PersistenceService.createRunRecord()` + `finalizeRunRecord()`. Do NOT re-stamp `FilteredFrame.runID` — accept that frames stored in SwiftData will have the runID from when CMMotionManager started (the "day" runID). The RunRecord's own `runID` is the authoritative key for run analysis; FrameRecord runIDs are useful but not critical if they differ during onset.

### Pattern 5: AppModel refactor — startDay/endDay

**What:** `AppModel.startSession()` → `startDay()` and `endSession()` → `endDay()`. These arm and disarm the full pipeline including the new GPS and activity managers.

```swift
// On AppModel — startDay arms classifier, starts GPS + activity managers
func startDay() async throws {
    try await workoutSessionManager.start()  // HKWorkoutSession first (SESS-01)
    await gpsManager.start()
    await activityManager.start()

    let frameStream = await broadcaster.makeStream()
    let gpsStream = await gpsManager.makeStream()
    let activityStream = await activityManager.makeStream()

    await activityClassifier.startDay(
        frameStream: frameStream,
        gpsStream: gpsStream,
        activityStream: activityStream,
        persistenceService: persistenceService!
    )

    let runID = UUID()  // "day" runID for CMMotionManager
    await broadcaster.start(runID: runID)
    startPeriodicFlush(runID: runID)
}

func endDay() async throws {
    periodicFlushTask?.cancel()
    await activityClassifier.endDay()  // finalizes any open RunRecord
    await broadcaster.stop()
    await gpsManager.stop()
    await activityManager.stop()
    await workoutSessionManager.end()
    if let service = persistenceService {
        try await service.emergencyFlush(ringBuffer: ringBuffer)
    }
}
```

### Pattern 6: Debug HUD (#if DEBUG)

**What:** SwiftUI `overlay` on `ContentView`, reading published state from `AppModel` via `@Environment`.

```swift
// ClassifierDebugHUD.swift — #if DEBUG block
#if DEBUG
struct ClassifierDebugHUD: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("STATE: \(appModel.classifierStateLabel)")
                .foregroundStyle(stateColor)
            Text("GPS: \(String(format: "%.1f", appModel.lastGPSSpeed)) m/s")
            Text("VAR: \(String(format: "%.4f", appModel.lastGForceVariance)) g²")
            Text("ACT: \(appModel.lastActivityLabel)")
            ProgressView(value: appModel.hysteresisProgress)
                .tint(stateColor)
            Text(String(format: "%.0f%%", appModel.hysteresisProgress * 100))
                .font(.caption2)
        }
        .font(.caption.monospacedDigit())
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var stateColor: Color {
        switch appModel.classifierStateLabel {
        case "SKIING":    return .green
        case "CHAIRLIFT": return .orange
        default:          return .secondary
        }
    }
}
#endif

// In ContentView:
var body: some View {
    mainContent
        #if DEBUG
        .overlay(alignment: .topLeading) { ClassifierDebugHUD() }
        #endif
}
```

`AppModel` exposes HUD-readable properties: `classifierStateLabel: String`, `lastGPSSpeed: Double`, `lastGForceVariance: Double`, `lastActivityLabel: String`, `hysteresisProgress: Double` (0.0–1.0). These are `@Published`-equivalent via `@Observable` — ActivityClassifier calls back to AppModel on the main actor via `await MainActor.run { appModel.updateDebugState(...) }` or AppModel polls via a dedicated debug stream.

### Anti-Patterns to Avoid

- **Task.sleep for hysteresis windows:** Non-deterministic in tests; timestamp arithmetic is testable and correct.
- **Holding CLBackgroundActivitySession in a local variable:** It deallocates and stops updates. Must be a stored property on GPSManager.
- **Filtering CLLocationUpdate.liveUpdates() by horizontalAccuracy:** Can block indefinitely if GPS signal degrades. Filter at the classifier level, not at the stream level.
- **Calling CMMotionActivityManager.startActivityUpdates on MainActor:** The callback fires on an internal thread; bridging with `Task { await self.broadcast(...) }` is correct.
- **Re-stamping FilteredFrame.runID mid-stream:** Modifying a `let` property requires a new struct — mutable by design via struct copy, but adds complexity. Prefer having ActivityClassifier carry its own runID as mutable state.
- **Three-signal wait with combined AsyncStream:** Combining three async sources into a single event via `AsyncSequence.zip`-equivalent is complex and unordered. The "heartbeat" pattern (IMU at 100Hz, GPS and activity as side-channel state) is simpler and correct.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| GPS location updates | Custom polling/timer | CLLocationUpdate.liveUpdates() | Native AsyncSequence, handles background, iOS 17+ |
| Activity type classification | Accelerometer-only heuristics | CMMotionActivityManager | Uses magnetometer + accelerometer fusion; far more accurate |
| Background location | Polling with significant-location-change | CLBackgroundActivitySession | Designed for this; works with whenInUse authorization |
| Circular buffer for variance | Custom linked list | Array + cap check (or existing RingBuffer) | 50-sample window; O(n) removeFirst is negligible |

**Key insight:** The three-signal fusion is where custom code earns its place. The individual signals are all Apple-provided; the value is in how you gate, weight, and hysteresis them.

---

## Common Pitfalls

### Pitfall 1: CLBackgroundActivitySession deallocation kills GPS

**What goes wrong:** GPS updates stop when the screen locks, even with Background Modes enabled.
**Why it happens:** `CLBackgroundActivitySession` must remain alive. If stored in a local variable or temporary, it deallocates and implicitly invalidates the session.
**How to avoid:** Store as a `private var backgroundSession: CLBackgroundActivitySession?` on `GPSManager`. Set to `nil` only in `stop()`.
**Warning signs:** GPS readings stop in debug HUD when screen locks mid-run.

### Pitfall 2: CLLocationUpdate.liveUpdates() on wrong LiveConfiguration

**What goes wrong:** Coordinates snap to road networks, producing nonsensical position data on mountain terrain.
**Why it happens:** `.automotiveNavigation` applies road-snapping. Chairlifts are not on road networks.
**How to avoid:** Use `.otherNavigation` or `.default`. Never `.automotiveNavigation` for ski-hill tracking.
**Warning signs:** GPS track shows points on nearby roads instead of mountain terrain.

### Pitfall 3: CMMotionActivity.automotive as sole chairlift signal

**What goes wrong:** False CHAIRLIFT detection on slow ski traverses, snowcat crossings, or slow-speed sections.
**Why it happens:** `automotive` fires on any motorized-vehicle-like motion signature, not only chairlifts.
**How to avoid:** Locked decision (three-signal gate). Do not relax to two-of-three in v1.
**Warning signs:** Runs end prematurely on slow terrain or while passing over snowcat tracks.

### Pitfall 4: GPS speed -1.0 treated as "slow"

**What goes wrong:** An invalid GPS fix (`speed == -1.0`, `horizontalAccuracy < 0`) is interpreted as 0 m/s, triggering CHAIRLIFT classification when the user is skiing.
**Why it happens:** CLLocation.speed returns -1.0 when speed is unavailable, not 0.
**How to avoid:** Gate on `horizontalAccuracy >= 0 && speed >= 0` before using speed value. When GPS is unavailable, either skip the GPS component of the gate or use the blackout rule from locked decisions.
**Warning signs:** Runs end whenever GPS signal weakens (tree cover, cloud, tunnels).

### Pitfall 5: Hysteresis frames attributed to wrong runID

**What goes wrong:** Frames captured during the skiing onset window end up in the wrong RunRecord (or are lost).
**Why it happens:** `FilteredFrame.runID` is set at IMU capture time by `MotionManager`, which uses the "day" runID. The actual per-run RunRecord is only created after hysteresis completes.
**How to avoid:** ActivityClassifier maintains its own `currentRunID`. FrameRecords in SwiftData carry the day-level runID from MotionManager; the RunRecord.runID is the authoritative key for associating metadata. For Phase 2, this is acceptable — Phase 3 analysis queries by RunRecord timestamps, not by FrameRecord.runID.
**Warning signs:** Post-run analysis shows no frames for a run, or frames appear in wrong run segment.

### Pitfall 6: CMMotionActivityManager on simulator

**What goes wrong:** `isActivityAvailable()` returns false on simulator; no callbacks fire.
**Why it happens:** Simulator does not emulate the M-series motion coprocessor that CMMotionActivityManager uses.
**How to avoid:** Inject a mock `ActivityManager` protocol in tests. In the real app, guard on `isActivityAvailable()` and treat unavailability as "unknown" activity (do not block skiing detection on missing activity data).
**Warning signs:** ActivityClassifier never transitions out of IDLE in simulator tests.

### Pitfall 7: Swift 6 Sendability with CLLocationUpdate task capture

**What goes wrong:** Compiler error: "capture of 'self' with non-Sendable type" inside the `for await` loop task.
**Why it happens:** `GPSManager` is an actor; capturing `self` weakly in `Task { [weak self] in ... }` satisfies Sendable checking. But if the task is a bare `Task { ... }` without isolation, it may not compile under SWIFT_STRICT_CONCURRENCY = complete.
**How to avoid:** The `for await` loop task must be created inside an actor-isolated function context. Use `Task { [weak self] in ... }` with explicit `await self?.broadcast(reading)` to cross actor boundary explicitly.
**Warning signs:** Build fails with "non-sendable type 'GPSManager' in concurrently-executed code."

---

## Code Examples

Verified patterns from official sources and Phase 1 codebase:

### CLLocationUpdate consumption (iOS 17+)

```swift
// Source: WWDC23 "Discover streamlined location updates"
// Note: .otherNavigation avoids road-snapping on mountain terrain
for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
    guard let location = update.location else { continue }
    guard location.horizontalAccuracy >= 0, location.speed >= 0 else { continue }
    // location.speed is in m/s
    let reading = GPSReading(speed: location.speed, ...)
}
```

### CMMotionActivity bridge

```swift
// Source: Apple CMMotionActivityManager docs
// Task bridge to actor: safe because Task inherits actor context when created inside actor method
manager.startActivityUpdates(to: OperationQueue()) { [weak self] activity in
    guard let activity else { return }
    Task { await self?.broadcast(activity) }
}
```

### Hysteresis timestamp arithmetic

```swift
// Source: research synthesis — deterministic, testable
private func evaluateSkiingOnset(now: Date) async {
    if skiingSignalActive() {
        if pendingSkiingOnsetAt == nil {
            pendingSkiingOnsetAt = now
        }
        let elapsed = now.timeIntervalSince(pendingSkiingOnsetAt!)
        // hysteresisProgress = min(elapsed / skiingOnsetSeconds, 1.0) → HUD display
        if elapsed >= skiingOnsetSeconds {
            await confirmSkiingTransition(confirmedAt: now)
        }
    } else {
        pendingSkiingOnsetAt = nil  // reset — signal was not sustained
        pendingFrames = []
    }
}
```

### Swift Testing actor pattern (Phase 1 precedent)

```swift
// Source: Phase 1 StreamBroadcasterTests.swift
@Suite("ActivityClassifier Tests", .serialized)
struct ActivityClassifierTests {
    @Test("CHAIRLIFT signal for 3s triggers SKIING transition")
    func testSkiingOnsetAfterHysteresis() async {
        let classifier = ActivityClassifier(...)
        // Inject synthetic signals via testable interface
        await classifier.injectGPS(speed: 12.0, accuracy: 5.0)
        await classifier.injectActivity(.ski)  // high variance, no automotive
        // Advance synthetic clock by skiingOnsetSeconds
        await classifier.advanceTime(by: 3.0)
        let state = await classifier.currentState
        #expect(state == .skiing)
    }
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| CLLocationManager + delegate | CLLocationUpdate.liveUpdates() AsyncSequence | iOS 17 / WWDC23 | No delegate bridge needed; native for-await loop |
| .always authorization for background GPS | whenInUse + CLBackgroundActivitySession | iOS 17 | Less invasive permission; user more likely to grant |
| CLServiceSession implicit | CLServiceSession explicit (iOS 18) | iOS 18 | Must hold CLServiceSession for authorization continuity |

**Deprecated/outdated:**
- `CLLocationManager.startUpdatingLocation()` + delegate: Still works, but requires NSObject subclass + OSAllocatedUnfairLock bridge for Swift 6. Prefer `CLLocationUpdate.liveUpdates()`.
- `isStationary` property on CLLocationUpdate: Deprecated in iOS 18, renamed to `stationary`. Use `.stationary` if targeting iOS 18+.

---

## Open Questions

1. **CLServiceSession requirement on iOS 18**
   - What we know: iOS 18 requires an active CLServiceSession for location updates to be delivered.
   - What's unclear: Does `CLLocationUpdate.liveUpdates()` implicitly hold a session, or must we explicitly create one?
   - Recommendation: Create an explicit `CLServiceSession(authorization: .whenInUse, fullAccuracyPurposeKey: "skiing")` stored alongside `CLBackgroundActivitySession` in GPSManager. Add the `fullAccuracyPurposeKey` to Info.plist. This is safe even on iOS 17 (where it's a no-op).

2. **CMMotionActivity.automotive confidence distribution on chairlifts**
   - What we know: Apple does not document chairlift-specific behavior. NSHipster notes automotive fires for any motorized vehicle. Confidence level is `.low`/`.medium`/`.high` per reading.
   - What's unclear: What confidence level does a chairlift typically produce? Is it reliable at `.medium`?
   - Recommendation: Block on `.low` automotive reads for the chairlift gate (require `.medium` or `.high`). Flag for on-mountain validation in Phase 4.

3. **FrameRecord.runID vs RunRecord.runID mismatch**
   - What we know: MotionManager stamps frames with the "day" runID (set at `broadcaster.start()`); ActivityClassifier creates per-run RunRecords with new UUIDs.
   - What's unclear: Phase 3 analysis queries FrameRecords by runID to reconstruct waveforms. If FrameRecord.runID != RunRecord.runID, post-run analysis breaks.
   - Recommendation: ActivityClassifier must call `broadcaster.start(runID: newRunID)` on each confirmed SKIING onset, propagating the correct runID into MotionManager. Add a `StreamBroadcaster.updateRunID(_:)` method that calls `motionManager.startUpdates(runID:)` without restarting the underlying `CMMotionManager`. Treat frames in the pending hysteresis window (which have the old runID) as pre-run data — do not persist them to SwiftData as part of the new run.

4. **GPS speed accuracy during lift load/unload**
   - What we know: Chairlift load zones are very slow (0–1 m/s). GPS speed may read 0 m/s here, overlapping with ski stop signatures.
   - What's unclear: Will the three-signal gate correctly hold CHAIRLIFT through slow load/unload if automotive is `.high` and variance is low?
   - Recommendation: The locked three-signal gate should handle this correctly (automotive + low variance sustains CHAIRLIFT even at 0 m/s). The 2.0s hysteresis window prevents brief mid-run stops from ending a run. Validate on mountain.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Swift Testing (`import Testing`) |
| Config file | None (Xcode scheme-based) |
| Quick run command | `xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:ArcticEdgeTests/ActivityClassifierTests 2>&1 | grep -E "Test|error|passed|failed"` |
| Full suite command | `xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 | grep -E "Test Suite|passed|failed"` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| DETC-01 | ActivityClassifier correctly classifies SKIING when all three signals are present | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testSkiingClassification` | ❌ Wave 0 |
| DETC-01 | ActivityClassifier classifies CHAIRLIFT only when all three signals are present simultaneously | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testChairliftRequiresAllThreeSignals` | ❌ Wave 0 |
| DETC-01 | Two-of-three signals do NOT trigger CHAIRLIFT | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testTwoOfThreeInsufficientForChairlift` | ❌ Wave 0 |
| DETC-01 | GPS unavailable in CHAIRLIFT state sustains CHAIRLIFT | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testGPSBlackoutSustainsChairlift` | ❌ Wave 0 |
| DETC-02 | Classifier does not transition on signals shorter than onset window | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testShortSignalDoesNotTransition` | ❌ Wave 0 |
| DETC-02 | Classifier transitions after full hysteresis window elapses | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testFullHysteresisWindowTriggersTransition` | ❌ Wave 0 |
| DETC-02 | Brief stops mid-run do not end the run | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testBriefStopDoesNotEndRun` | ❌ Wave 0 |
| DETC-03 | Confirmed SKIING onset creates a RunRecord in SwiftData | integration | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testConfirmedSkiingCreatesRunRecord` | ❌ Wave 0 |
| DETC-03 | SKIING→CHAIRLIFT transition finalizes RunRecord with endTimestamp | integration | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testTransitionFinalizesRunRecord` | ❌ Wave 0 |
| DETC-03 | endDay() with open run finalizes the RunRecord | integration | `xcodebuild test ... -only-testing:ArcticEdgeTests/ActivityClassifierTests/testEndDayFinalizesOpenRun` | ❌ Wave 0 |

**CMMotionActivityManager tests:** `isActivityAvailable()` returns false on simulator. Tests must use a mock `ActivityManagerProtocol` that can be injected. Actual automotive classification is manual-only validation (on-mountain, Phase 4).

**GPSManager tests:** CLLocationUpdate.liveUpdates() does not run in unit tests. Tests use a mock `GPSManagerProtocol`. Speed threshold boundary tests (`speed == -1`, `speed == 0`, `speed == 3.0`, `speed == 12.0`) are fully unit-testable via injection.

### Sampling Rate

- **Per task commit:** Run ActivityClassifierTests only (< 10 seconds)
- **Per wave merge:** Full suite
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps

- [ ] `ArcticEdgeTests/Activity/ActivityClassifierTests.swift` — covers DETC-01, DETC-02, DETC-03 (pure logic tests with mock GPS + activity injection)
- [ ] `ArcticEdgeTests/Activity/ActivityManagerTests.swift` — covers CMMotionActivityManager mock bridge
- [ ] `ArcticEdgeTests/Location/GPSManagerTests.swift` — covers GPSReading model, speed validation logic
- [ ] `ArcticEdgeTests/Helpers/MockGPSManager.swift` — injectable protocol for ActivityClassifier tests
- [ ] `ArcticEdgeTests/Helpers/MockActivityManager.swift` — injectable protocol for ActivityClassifier tests

---

## Sources

### Primary (HIGH confidence)

- Apple WWDC23 "Discover streamlined location updates" — CLLocationUpdate.liveUpdates() API, LiveConfiguration enum, CLBackgroundActivitySession pattern
- twocentstudios.com/2024/12/02/core-location-modern-api-tips/ — Real-world gotchas: backgroundSession deallocation, locationUnavailable unreliability, no built-in filtering, 1-2 Hz update rate
- theinkedengineer.com/insights/bridging-core-location-to-swift-6-concurrency — OSAllocatedUnfairLock + UUID-keyed continuation pattern for Swift 6 compliance
- Apple CMMotionActivityManager documentation — startActivityUpdates(to:withHandler:) signature, CMMotionActivity properties, confidence enum
- NSHipster.com/cmmotionactivity — Multiple simultaneous activity booleans (automotive + stationary possible together), confidence interpretation guidance
- Phase 1 codebase — StreamBroadcaster pattern, actor conventions, Swift Testing patterns (PersistenceServiceTests, StreamBroadcasterTests)

### Secondary (MEDIUM confidence)

- PMC/PubMed: "Alpine Skiing Activity Recognition Using Smartphone's IMUs" (MDPI Sensors 2022) — 8s window optimal, 30s minimum run duration, periodic turn patterns are primary discriminator
- Apple Developer Forums thread/758704 — CLLocationUpdate with automotiveNavigation (road-snapping confirmed)
- Apple WWDC24 "What's new in location authorization" — CLServiceSession requirement on iOS 18

### Tertiary (LOW confidence)

- Chairlift speed range 1–7 m/s: derived from Wikipedia Ski lift article (rope speeds 2.5–6 m/s) + empirical adjustment for measurement variance — treat as calibration hypothesis
- G-force variance thresholds (0.005/0.01 g²): derived from research synthesis and domain reasoning — needs on-mountain calibration (Phase 4)
- Skiing onset threshold 3.0s, run end threshold 2.0s: within the range supported by academic literature (30s minimum run, 8s window) — starting values for Phase 4 calibration

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all APIs are first-party, well-documented, iOS 17+
- Architecture: HIGH — actor patterns follow Phase 1 precedent exactly; CLLocationUpdate AsyncSequence is straightforward
- Chairlift heuristics: MEDIUM — automotive signal logic is confirmed reasonable; specific thresholds need on-mountain data
- Speed thresholds: LOW — derived from rope speed specs and domain reasoning; primary calibration target for Phase 4

**Research date:** 2026-03-09
**Valid until:** 2026-09-09 (stable Apple APIs; 6-month estimate)
