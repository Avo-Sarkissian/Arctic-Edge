# Phase 1: Motion Engine & Session Foundation - Research

**Researched:** 2026-03-08
**Domain:** CoreMotion / Accelerate / SwiftData / HealthKit / Swift Structured Concurrency
**Confidence:** HIGH

---

## Summary

Phase 1 builds the sensor pipeline that every other phase depends on. The core challenge is not the happy path -- it is the integration seams where Apple's Objective-C frameworks meet Swift's strict concurrency model. `CMDeviceMotion` is a non-Sendable Objective-C reference type. `SwiftData` autosaves on the main thread by default. `CMMotionManager` silently replaces its handler if started twice. Each of these will cause build-breaking errors or data loss at 100Hz if not handled correctly from the start.

The project already targets `IPHONEOS_DEPLOYMENT_TARGET = 26.2` (iOS 26 / Xcode 26 SDK), which is the correct target. `HKWorkoutSession` on iPhone -- the background CPU budget mechanism -- was not available on iPhone until iOS 26 per WWDC25 session 322. The existing research summary stated "iOS 17+" which was incorrect; iOS 26 is the correct minimum. This does not change any implementation decisions because the project is already targeting 26.2, but it must be understood when configuring capabilities and entitlements.

The architecture pattern is well-understood: CoreMotion callback extracts primitives into a Sendable struct, bridges via `Task { await actor.receive(sample) }` into the `MotionManager` actor, which writes to a `RingBuffer` actor with a synchronous `drain()` method. A `StreamBroadcaster` actor owns the single `CMMotionManager` instance and fans out one `AsyncStream` to multiple consumers. `PersistenceService` is a `@ModelActor` actor that flushes the ring buffer in batches of 200-500 frames using a background `ModelContext` with `autosaveEnabled = false`. The `WorkoutSessionManager` must reach `.running` state before `CMMotionManager.startDeviceMotionUpdates` is called.

**Primary recommendation:** Build in the dependency order established in ARCHITECTURE.md -- FilteredFrame struct first, then vDSP filter, RingBuffer, MotionManager, StreamBroadcaster, WorkoutSessionManager, PersistenceService, SwiftData schema. Test each component in isolation with Swift Testing before wiring them together.

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| MOTN-01 | App captures CMDeviceMotion at 100Hz via MotionManager actor using Swift 7 AsyncStream | CoreMotion `deviceMotionUpdateInterval = 0.01`, AsyncStream continuation pattern, actor isolation boundary |
| MOTN-02 | High-pass biquad filter (Accelerate/vDSP) isolates carve-pressure signal: preserve >2Hz, reject <0.5Hz | `vDSP.Biquad` coefficients via Audio EQ Cookbook formulas, bilinear transform at 100Hz sample rate |
| MOTN-03 | In-memory ring buffer stores last ~10 seconds of filtered frames (1000 samples) with synchronous, transactional drain | Actor with synchronous `drain()` -- no internal awaits; atomic swap pattern |
| MOTN-04 | StreamBroadcaster actor fans out sensor stream to LiveViewModel and ActivityClassifier without calling CMMotionManager start twice | Single `CMMotionManager` owner, `AsyncStream` fan-out via `makeStream()` + continuation storage |
| MOTN-05 | Thermal-aware throttling gracefully degrades sample rate (100Hz to 50Hz to 25Hz) when ProcessInfo.thermalState reaches critical | `ProcessInfo.thermalStateDidChangeNotification`, `.serious` triggers 50Hz, `.critical` triggers 25Hz |
| SESS-01 | HKWorkoutSession provides background CPU budget, keeping sensor capture active when screen locks | iOS 26 required; HealthKit capability entitlement; `NSHealthShareUsageDescription` + `NSHealthUpdateUsageDescription` in Info.plist |
| SESS-02 | SwiftData persists sensor frames in batches via background ModelContext -- never per-frame; flush every 200-500 samples | `@ModelActor` with `autosaveEnabled = false`, explicit `try modelContext.save()` after each batch |
| SESS-03 | SwiftData schema defines FrameRecord with `#Index` on timestamp and runID | `#Index<FrameRecord>([\.timestamp], [\.runID], [\.runID, \.timestamp])` -- iOS 18+ feature, confirmed available on iOS 26 target |
| SESS-04 | Emergency data flush on applicationDidEnterBackground and applicationWillTerminate | `UIApplication.didEnterBackgroundNotification`, synchronous flush pattern |
| SESS-05 | Detects and recovers orphaned HKWorkoutSession on launch (UserDefaults sentinel pattern) | UserDefaults `Bool` sentinel set on session start, cleared on clean end; checked in app init |
</phase_requirements>

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| CoreMotion / CMMotionManager | iOS 26 SDK | 100Hz fused IMU (attitude, rotation rate, userAcceleration, gravity) | Only Apple-first-party path to sensor-fused data at 100Hz; no alternative |
| Accelerate / vDSP.Biquad | iOS 26 SDK | High-pass IIR biquad filter on accelerometer data | Zero-dependency SIMD-accelerated DSP; correct API for single-channel IIR filtering |
| SwiftData | iOS 18+ (iOS 26 SDK) | Persistent storage of FrameRecord and RunRecord | First-party ORM; `#Index` macro requires iOS 18+, available on iOS 26 target |
| HealthKit / HKWorkoutSession | iOS 26 | Background CPU budget for sustained sensor capture | Only legitimate mechanism for background execution on iPhone; required iOS 26 |
| Swift Concurrency (actor, AsyncStream, Task) | Swift 6 / Xcode 26 | Bridge CoreMotion callbacks into structured concurrency; actor isolation | Mandatory under SWIFT_STRICT_CONCURRENCY = complete |
| Swift Testing | Xcode 16+ | Unit tests for filter, ring buffer, broadcaster logic | Project requirement; `import Testing` with `@Test` and `#expect` |

### No Third-Party Dependencies

Zero third-party packages. Every capability in Phase 1 is covered by Apple first-party frameworks. This is both a project constraint and the correct technical choice.

### Installation

No package installation required. All frameworks are linked via Xcode target capabilities:
- HealthKit: Signing & Capabilities -> HealthKit (adds entitlement automatically)
- CoreMotion: Link binary with libraries -> CoreMotion.framework
- Accelerate: Link binary with libraries -> Accelerate.framework (usually auto-linked)
- SwiftData: `import SwiftData` -- included in iOS 18+ SDK

---

## Architecture Patterns

### Recommended Project Structure

```
ArcticEdge/
|- Motion/
|   |- FilteredFrame.swift          # Sendable value type carrying all extracted sensor values
|   |- BiquadHighPassFilter.swift   # vDSP.Biquad wrapper, stateful, not Sendable
|   |- RingBuffer.swift             # actor with O(1) append and synchronous drain()
|   |- MotionManager.swift          # actor owning CMMotionManager, emits FilteredFrame stream
|   |- StreamBroadcaster.swift      # actor for fan-out to multiple AsyncStream consumers
|- Session/
|   |- WorkoutSessionManager.swift  # HKWorkoutSession lifecycle, delegate
|   |- PersistenceService.swift     # @ModelActor, batched SwiftData writes
|- Schema/
|   |- FrameRecord.swift            # @Model with #Index
|   |- RunRecord.swift              # @Model with #Index
|- ArcticEdgeApp.swift              # ModelContainer setup, WorkoutSessionManager init
|- ContentView.swift                # placeholder until Phase 3
ArcticEdgeTests/
|- Motion/
|   |- FilteredFrameTests.swift
|   |- BiquadFilterTests.swift
|   |- RingBufferTests.swift
|   |- MotionManagerTests.swift
|   |- StreamBroadcasterTests.swift
|- Session/
|   |- PersistenceServiceTests.swift
```

### Pattern 1: Sendable Boundary at CoreMotion Callback

**What:** CMDeviceMotion is not Sendable. Extract all needed values as primitive Doubles immediately in the callback closure, wrap in a Sendable struct, then bridge into the actor via `Task { await actor.receive(frame) }`.

**When to use:** Always. This is the mandatory pattern for any CoreMotion -> actor data transfer.

```swift
// FilteredFrame.swift
struct FilteredFrame: Sendable {
    let timestamp: TimeInterval    // CMDeviceMotion.timestamp
    let runID: UUID
    let pitch: Double              // attitude.pitch
    let roll: Double               // attitude.roll
    let yaw: Double                // attitude.yaw
    let userAccelX: Double         // userAcceleration.x
    let userAccelY: Double         // userAcceleration.y
    let userAccelZ: Double         // userAcceleration.z
    let gravityX: Double           // gravity.x
    let gravityY: Double           // gravity.y
    let gravityZ: Double           // gravity.z
    let rotationRateX: Double      // rotationRate.x
    let rotationRateY: Double      // rotationRate.y
    let rotationRateZ: Double      // rotationRate.z
}

// Inside MotionManager actor's startUpdates() method:
motionManager.startDeviceMotionUpdates(to: OperationQueue()) { [weak self] motion, error in
    guard let motion, let self else { return }
    // Extract primitives immediately -- do NOT store motion reference
    let frame = FilteredFrame(
        timestamp: motion.timestamp,
        runID: self.currentRunID,     // captured by value -- actor property read is unsafe here
        // ... extract all doubles ...
    )
    // Bridge into actor context
    Task { await self.receive(frame) }
}
```

**Critical note:** The `self` capture in the callback is nonisolated. Actor properties cannot be read safely from the callback thread. The pattern is to extract only CMDeviceMotion fields (which are value types / primitives on the motion object), then use `Task { await }` to cross into actor isolation for any state access. `currentRunID` must be captured before starting updates or passed differently -- see Pattern 4 below.

### Pattern 2: RingBuffer with Synchronous Drain

**What:** Fixed-capacity circular buffer as an actor. `append(_:)` is an actor method (async from outside, synchronous body). `drain()` is also an actor method but its body performs a synchronous atomic swap -- no `await` inside.

**When to use:** Whenever you need to atomically consume accumulated data without risking reentrancy data loss.

```swift
actor RingBuffer {
    private var buffer: [FilteredFrame] = []
    private let capacity: Int = 1000  // ~10 seconds at 100Hz

    func append(_ frame: FilteredFrame) {
        if buffer.count >= capacity {
            buffer.removeFirst()  // drop oldest sample -- acceptable for live telemetry
        }
        buffer.append(frame)
    }

    // Synchronous drain: atomic swap, no await inside
    // Returns all buffered frames and resets the buffer atomically.
    func drain() -> [FilteredFrame] {
        let chunk = buffer
        buffer = []
        return chunk
    }

    var count: Int { buffer.count }
}
```

**Why no await inside drain():** Actor reentrancy allows a second caller to interleave between two awaits. If `drain()` had an `await`, new frames could arrive between the read and the clear, and those frames would be lost. The synchronous swap eliminates this window.

### Pattern 3: AsyncStream Fan-Out in StreamBroadcaster

**What:** StreamBroadcaster owns the single `CMMotionManager` instance and provides multiple independent `AsyncStream<FilteredFrame>` handles. Consumers iterate their own stream; new consumers subscribe without touching the motion manager.

**When to use:** Whenever you have one source (CMMotionManager) and multiple consumers (LiveViewModel, ActivityClassifier).

```swift
actor StreamBroadcaster {
    private var continuations: [UUID: AsyncStream<FilteredFrame>.Continuation] = [:]
    private let motionManager: MotionManager

    // Returns a new independent AsyncStream for one consumer.
    func makeStream() -> AsyncStream<FilteredFrame> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<FilteredFrame>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self, id] _ in
            Task { await self?.removeContinuation(id: id) }
        }
        return stream
    }

    // Called by MotionManager on each new frame.
    func broadcast(_ frame: FilteredFrame) {
        for continuation in continuations.values {
            continuation.yield(frame)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
```

**Note:** `AsyncStream.makeStream()` is the Swift 5.9+ API that returns `(stream, continuation)` as a tuple. Use it instead of the older closure-based initializer.

### Pattern 4: WorkoutSessionManager Must Reach .running Before CMMotionManager

**What:** HealthKit's background CPU budget is only granted once `HKWorkoutSession` reaches the `.running` state. Starting `CMMotionManager` before this means the app will be suspended when the screen locks.

**When to use:** Always. This is an ordering requirement, not an optimization.

```swift
// Correct startup sequence:
// 1. Start HKWorkoutSession and await .running state
// 2. Only then call MotionManager.startUpdates()
func startSession() async throws {
    try await workoutSessionManager.start()     // waits for .running
    await motionManager.startUpdates()           // safe to start now
    UserDefaults.standard.set(true, forKey: "sessionInProgress")  // orphan sentinel
}
```

### Pattern 5: PersistenceService as @ModelActor with Batched Flush

**What:** SwiftData `@ModelActor` creates an actor with a background `ModelContext` tied to its own serial queue. Set `autosaveEnabled = false`. Accumulate frames in the ring buffer, flush in batches of 200-500 samples.

**When to use:** All SwiftData writes from Phase 1. Never insert FrameRecords one at a time.

```swift
@ModelActor
actor PersistenceService {
    func flush(frames: [FilteredFrame]) throws {
        // modelContext is automatically the background context provided by @ModelActor
        modelContext.autosaveEnabled = false
        for frame in frames {
            let record = FrameRecord(
                timestamp: frame.timestamp,
                runID: frame.runID,
                pitch: frame.pitch,
                roll: frame.roll,
                userAccelX: frame.userAccelX,
                userAccelY: frame.userAccelY,
                userAccelZ: frame.userAccelZ
                // ... other fields
            )
            modelContext.insert(record)
        }
        try modelContext.save()
    }
}
```

**Note:** `@ModelActor` macro must be initialized from a non-main thread to guarantee it gets a private queue context. Use `Task.detached` for initialization if called from a `@MainActor` context.

### Pattern 6: High-Pass Biquad Filter Coefficients

**What:** Compute biquad coefficients using the Audio EQ Cookbook second-order HPF formula, then initialize `vDSP.Biquad` with them.

**When to use:** MOTN-02. Filter coefficients are computed at init time from the cutoff frequency and sample rate.

```swift
// BiquadHighPassFilter.swift
// NOT Sendable -- stateful filter; owned exclusively by MotionManager actor.
final class BiquadHighPassFilter {
    private var filter: vDSP.Biquad<Double>

    // cutoffHz: filter cutoff frequency in Hz (start: 0.5 Hz for reject threshold)
    // sampleRate: samples per second (100.0 for 100Hz)
    // Q: resonance / quality factor (0.707 for Butterworth maximally flat)
    init(cutoffHz: Double, sampleRate: Double, Q: Double = 0.707) {
        let omega = 2.0 * .pi * cutoffHz / sampleRate
        let alpha = sin(omega) / (2.0 * Q)
        let cosOmega = cos(omega)

        // Audio EQ Cookbook second-order HPF coefficients:
        let b0 = (1.0 + cosOmega) / 2.0
        let b1 = -(1.0 + cosOmega)
        let b2 = (1.0 + cosOmega) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha

        // vDSP.Biquad coefficient array: [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]
        let coefficients = [b0/a0, b1/a0, b2/a0, a1/a0, a2/a0]
        self.filter = vDSP.Biquad(
            coefficients: coefficients,
            channelCount: 1,
            sectionCount: 1,
            ofType: Double.self
        )!
    }

    // Apply filter to a single sample by wrapping in array.
    // vDSP.Biquad maintains internal state between calls.
    func apply(_ sample: Double) -> Double {
        return filter.apply(input: [sample])[0]
    }
}
```

**Filter design note:** The cutoff values (preserve >2Hz, reject <0.5Hz) suggest a transition band, not a single cutoff. A single second-order biquad has one cutoff frequency. The practical implementation: set cutoff to the geometric mean of 0.5 and 2.0 Hz (approximately 1.0 Hz) with Q = 0.707 (Butterworth). The "preserve >2Hz, reject <0.5Hz" values are REQUIREMENTS for the output behavior, not direct inputs to the filter formula. Treat cutoff (approximately 0.8-1.0 Hz) as a tunable constant until beta data is available.

**Confidence:** HIGH on vDSP.Biquad API; MEDIUM on exact cutoff value (calibration needed with real skiing data).

### Pattern 7: Thermal Throttling

**What:** Observe `ProcessInfo.thermalStateDidChangeNotification` and adjust `deviceMotionUpdateInterval` dynamically.

```swift
// Inside MotionManager actor:
func observeThermalState() {
    NotificationCenter.default.addObserver(
        forName: ProcessInfo.thermalStateDidChangeNotification,
        object: nil,
        queue: nil
    ) { [weak self] _ in
        let state = ProcessInfo.processInfo.thermalState
        Task { await self?.adjustSampleRate(for: state) }
    }
}

func adjustSampleRate(for state: ProcessInfo.ThermalState) {
    let interval: Double
    switch state {
    case .nominal, .fair:
        interval = 1.0 / 100.0   // 100 Hz
    case .serious:
        interval = 1.0 / 50.0    // 50 Hz
    case .critical:
        interval = 1.0 / 25.0    // 25 Hz
    @unknown default:
        interval = 1.0 / 50.0
    }
    motionManager.deviceMotionUpdateInterval = interval
}
```

### Pattern 8: Emergency Flush and Orphan Recovery

**What:** Flush ring buffer synchronously on background entry and termination. Set UserDefaults sentinel on session start; clear on clean end. Check on launch for orphan.

```swift
// In ArcticEdgeApp or AppDelegate equivalent:
func setupLifecycleObservers() {
    NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
    ) { _ in
        Task { try await persistenceService.emergencyFlush(ringBuffer: ringBuffer) }
    }
}

// On app launch:
func checkForOrphanedSession() async {
    let sentinel = UserDefaults.standard.bool(forKey: "sessionInProgress")
    if sentinel {
        // Previous session did not end cleanly -- recover or mark as orphaned
        await workoutSessionManager.recoverOrphanedSession()
    }
}
```

### Anti-Patterns to Avoid

- **Storing CMDeviceMotion reference across an await:** Non-Sendable object; causes strict concurrency build error.
- **Calling CMMotionManager.startDeviceMotionUpdates twice:** Silently replaces the handler; second consumer receives nothing. All start calls must go through StreamBroadcaster.
- **Per-frame SwiftData insert and save:** 100 saves/second on main context causes 10-50ms hangs. Always batch.
- **await inside RingBuffer.drain():** Creates actor reentrancy window where new frames are lost.
- **Using CMBatchedSensorManager:** Delivers 1-second batches. Incompatible with live 100Hz dashboard.
- **Starting MotionManager before HKWorkoutSession reaches .running:** Sensor capture will be suspended when screen locks.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| IIR biquad filter | Custom filter loop | `vDSP.Biquad` (Accelerate) | SIMD-accelerated; handles state correctly; single line of Swift |
| Thread-safe actor queue for ModelContext | Custom dispatch queue | `@ModelActor` macro | Macro generates correct executor binding; manual is error-prone |
| Sensor data serialization | Custom binary format | `SwiftData @Model` + `FrameRecord` | SQL-backed with WAL mode; `#Index` for fast queries |
| Background execution budget | Background task scheduling | `HKWorkoutSession` | HealthKit is the only mechanism with the required sustained CPU grant on iPhone |
| Async bridging from callback to actor | Manual continuation management | `AsyncStream.makeStream()` + `continuation.yield()` | Standard API, handles cancellation and backpressure |

**Key insight:** Every non-trivial problem in this phase has a first-party Apple solution. Building custom alternatives adds maintenance cost without correctness benefit under strict concurrency.

---

## Common Pitfalls

### Pitfall 1: CMDeviceMotion Sendable Violation (Build-Breaking)

**What goes wrong:** Passing `CMDeviceMotion` object across the CoreMotion callback boundary into an actor method causes a `Sendable` conformance error under `SWIFT_STRICT_CONCURRENCY = complete`. The build fails entirely.

**Why it happens:** `CMDeviceMotion` is an Objective-C reference type with no Sendable conformance. Swift's strict concurrency checker rejects any transfer of non-Sendable types across isolation boundaries.

**How to avoid:** Extract all needed values as primitive `Double` values immediately in the callback closure. Construct a `FilteredFrame` struct (which is Sendable by composition of Sendable properties) in the callback. Then `Task { await actor.receive(frame) }` to cross the boundary.

**Warning signs:** Compiler error mentioning "Capture of 'motion' with non-sendable type 'CMDeviceMotion?'" or "passing argument of non-sendable type".

### Pitfall 2: Actor Reentrancy in Flush Cycle (Data Loss at 100Hz)

**What goes wrong:** If `drain()` has an internal `await`, the actor becomes reentrant at that suspension point. New frames arriving during the await are appended to the buffer after `drain()` already read it -- but before `buffer = []` executes. Those frames are silently dropped.

**Why it happens:** Swift actors do not guarantee mutual exclusion across suspension points. Between two awaits, other callers can interleave.

**How to avoid:** `drain()` must be a fully synchronous method body -- `let chunk = buffer; buffer = []; return chunk`. No awaits. The entire operation is atomic because the actor scheduler cannot interleave synchronous code.

**Warning signs:** Frame count in PersistenceService does not match MotionManager emission count over time.

### Pitfall 3: SwiftData Autosave on Main Thread at High Frequency (UI Freezes)

**What goes wrong:** SwiftData's main `ModelContext` autosaves on UI events. At 120Hz ProMotion with 100Hz inserts, autosave fires multiple times per second causing 10-50ms main thread hangs, dropped frames in the waveform, and UI stutters.

**Why it happens:** The default `@Environment(\.modelContext)` context is tied to the main thread and autosaves automatically.

**How to avoid:** Never insert `FrameRecord` objects on the main context. Create a `@ModelActor` actor that owns its own background `ModelContext`. Set `modelContext.autosaveEnabled = false`. Accumulate 200-500 samples in the ring buffer, then call actor's `flush(frames:)` method which inserts the batch and calls `try modelContext.save()` explicitly.

**Warning signs:** Instruments Time Profiler shows `autosave` or `NSManagedObjectContext.save` on the main thread during motion capture.

### Pitfall 4: HKWorkoutSession Orphaned After Crash (Data Loss)

**What goes wrong:** If iOS kills the app during a session, the `HKWorkoutSession` becomes orphaned. The ring buffer contents are lost. The session ID in the data records does not resolve to a completed `RunRecord`.

**Why it happens:** There is no automatic resurrection. The sentinel in UserDefaults is the only signal available at next launch.

**How to avoid:** Set `UserDefaults.standard.set(true, forKey: "sessionInProgress")` immediately after the session reaches `.running`. Clear it only after the session ends cleanly. On app launch, check this sentinel before anything else. If set, attempt orphan recovery: query `HKHealthStore` for active sessions, finalize or discard the orphaned run, recover any FrameRecords that were flushed to SwiftData.

**Warning signs:** UserDefaults sentinel is `true` at app launch after a crash.

### Pitfall 5: Missing SWIFT_STRICT_CONCURRENCY Build Setting

**What goes wrong:** The project currently has `SWIFT_VERSION = 5.0` and no `SWIFT_STRICT_CONCURRENCY` key in `project.pbxproj`. Without setting `SWIFT_STRICT_CONCURRENCY = complete`, Sendable errors silently become warnings and data race bugs compile without error.

**Why it happens:** Xcode does not default to complete mode. It must be set explicitly.

**How to avoid:** Add `SWIFT_STRICT_CONCURRENCY = complete` to all build configurations (Debug and Release) for the main target and test target. This is a Wave 0 / Plan 01-01 prerequisite -- set it before writing any actor code.

**Warning signs:** Actor code compiles with warnings rather than errors. CMDeviceMotion capture across boundaries does not produce a build error.

### Pitfall 6: vDSP.Biquad Filter Warm-Up Transient

**What goes wrong:** The first few dozen samples after filter initialization produce a transient artifact as the filter's internal state converges. This shows up as a spike at the start of each run.

**Why it happens:** IIR filters require time to populate their internal delay line state.

**How to avoid:** Discard or zero-weight the first 50-100 samples after filter init. Alternatively, pre-load the delay state with the first sample value (DC initialization). For Phase 1, simply drop the first 100 frames of a new run segment.

**Warning signs:** Visible spike at the beginning of each run in post-run waveform review.

### Pitfall 7: HKWorkoutSession Requires iOS 26 on iPhone

**What goes wrong:** The existing SUMMARY.md states "HKWorkoutSession on iPhone requires iOS 17+". This is incorrect. Per WWDC25 session 322 ("Track workouts with HealthKit on iOS and iPadOS"), `HKWorkoutSession` primary sessions on iPhone were added in iOS 26.

**Why it matters for planning:** The project already targets `IPHONEOS_DEPLOYMENT_TARGET = 26.2`, so no deployment target change is needed. However, the entitlement verification must be done against iOS 26 documentation, not iOS 17 docs. Do not rely on any pre-iOS-26 HealthKit iPhone workout session tutorials.

**Warning signs:** Attempting to use HKWorkoutSession on an iOS 18 or iOS 17 simulator -- it will not work.

---

## Code Examples

Verified patterns from official sources and established Swift concurrency practice:

### vDSP.Biquad Initialization (Accelerate)

```swift
// Source: Apple Developer Documentation - vDSP.Biquad
// Coefficient array order: [b0, b1, b2, a1, a2] (normalized by a0)
let filter = vDSP.Biquad(
    coefficients: [b0_norm, b1_norm, b2_norm, a1_norm, a2_norm],
    channelCount: 1,
    sectionCount: 1,
    ofType: Double.self
)!

// Apply to a buffer:
var outputBuffer = [Double](repeating: 0, count: inputBuffer.count)
outputBuffer = filter.apply(input: inputBuffer)

// Apply to a single sample (wrapping in array):
let filtered = filter.apply(input: [rawSample])[0]
```

### AsyncStream Fan-Out (makeStream API)

```swift
// Source: Swift Evolution SE-0314, Swift 5.9+ API
let (stream, continuation) = AsyncStream<FilteredFrame>.makeStream()
// Store continuation, yield to it from producer
continuation.yield(frame)
// Consumer iterates:
for await frame in stream {
    process(frame)
}
```

### @ModelActor Background Context

```swift
// Source: Apple Documentation - SwiftData ModelActor
@ModelActor
actor PersistenceService {
    // modelContext is provided automatically by the macro
    // It is bound to a background serial queue
    func insert(_ frames: [FilteredFrame]) throws {
        for frame in frames {
            modelContext.insert(FrameRecord(from: frame))
        }
        try modelContext.save()
    }
}

// Initialize from non-main context to guarantee background queue:
let service = await Task.detached {
    PersistenceService(modelContainer: container)
}.value
```

### SwiftData #Index on FrameRecord

```swift
// Source: WWDC24 "What's new in SwiftData" (session 10137), iOS 18+
@Model
final class FrameRecord {
    #Index<FrameRecord>([\.timestamp], [\.runID], [\.runID, \.timestamp])

    var timestamp: TimeInterval
    var runID: UUID
    var pitch: Double
    var roll: Double
    var userAccelX: Double
    var userAccelY: Double
    var userAccelZ: Double
    // ... other fields

    init(from frame: FilteredFrame) {
        self.timestamp = frame.timestamp
        self.runID = frame.runID
        self.pitch = frame.pitch
        self.roll = frame.roll
        self.userAccelX = frame.userAccelX
        self.userAccelY = frame.userAccelY
        self.userAccelZ = frame.userAccelZ
    }
}

@Model
final class RunRecord {
    #Index<RunRecord>([\.runID], [\.startTimestamp])

    var runID: UUID
    var startTimestamp: Date
    var endTimestamp: Date?
    var isOrphaned: Bool = false
}
```

### ProcessInfo Thermal State Observer

```swift
// Source: Apple Developer Documentation - ProcessInfo.ThermalState
// Observe from an actor:
func setupThermalObserver() {
    NotificationCenter.default.addObserver(
        forName: ProcessInfo.thermalStateDidChangeNotification,
        object: nil,
        queue: nil
    ) { [weak self] _ in
        let newState = ProcessInfo.processInfo.thermalState
        Task { await self?.handleThermalChange(newState) }
    }
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Combine / callbacks for sensor pipeline | AsyncStream + actor isolation | Swift 5.5 / WWDC21, mandatory in Swift 6 | Required under strict concurrency complete mode |
| XCTest for sensor logic | Swift Testing (`import Testing`) | Xcode 16 / WWDC24 | Project requirement; cleaner `#expect` DSL, better parallel test support |
| Per-frame CoreData save | Batched SwiftData flush via @ModelActor | SwiftData iOS 17, #Index iOS 18 | Correct for 100Hz write throughput |
| NSOperationQueue + delegate for CMMotionManager | Actor-owned CMMotionManager + AsyncStream | Swift 6 | Eliminates race conditions at compiler level |
| HKWorkoutSession Watch-only (before iOS 26) | HKWorkoutSession on iPhone (iOS 26+) | WWDC25 | Background CPU budget now achievable without a Watch |

**Deprecated / outdated:**
- CMBatchedSensorManager: Delivers 1-second batches; explicitly excluded from this project.
- `AsyncStream` closure-based initializer (old): Prefer `AsyncStream.makeStream()` which returns `(stream, continuation)` tuple; available since Swift 5.9.
- `XCTest`: Do not add new XCTest-based tests. All new tests use `import Testing`.

---

## Open Questions

1. **HKWorkoutSession exact entitlement string on iOS 26**
   - What we know: HealthKit capability is added via Xcode Signing & Capabilities; `NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription` are required in Info.plist. iOS 26 added primary workout sessions on iPhone (WWDC25 session 322).
   - What's unclear: Whether iOS 26 requires an additional entitlement beyond the standard HealthKit capability for background workout execution (similar to `com.apple.developer.healthkit.background-delivery` introduced for iOS 15 background delivery).
   - Recommendation: Add HealthKit capability via Xcode UI (which auto-adds entitlement), add both Info.plist privacy strings, then test on physical device before declaring background session working. Do not rely on Simulator -- HealthKit does not function in Simulator.

2. **@ModelActor initialization threading requirement**
   - What we know: A `ModelContext` created on the main thread uses the main queue. `@ModelActor` must be initialized off the main thread for background queue behavior.
   - What's unclear: Whether `Task.detached` is always sufficient for iOS 26 or whether specific executor configuration is needed.
   - Recommendation: Always use `Task.detached` for `PersistenceService` initialization. Verify with Instruments Thread Sanitizer that context operations run on a non-main thread.

3. **vDSP.Biquad filter cutoff calibration**
   - What we know: HPF coefficients are computed from cutoff frequency (Hz) and Q factor. Requirements state preserve >2Hz, reject <0.5Hz, suggesting a geometric mean cutoff of approximately 1.0 Hz. Q = 0.707 for Butterworth response.
   - What's unclear: The exact cutoff (0.5-1.0 Hz range) that produces the best carve-pressure signal in real skiing conditions.
   - Recommendation: Implement `cutoffHz` as a compile-time constant (not hardcoded literal) from the start: `let kFilterCutoffHz: Double = 1.0`. Log both raw and filtered values during initial runs for calibration.

4. **RunID capture in CoreMotion callback**
   - What we know: The CoreMotion callback runs on a non-isolated background thread. Actor-isolated properties (like `currentRunID`) cannot be safely read from that callback.
   - What's unclear: The cleanest pattern for providing the current run ID to `FilteredFrame` without touching actor state in the callback.
   - Recommendation: Capture `currentRunID` as a local constant before calling `startDeviceMotionUpdates`, pass it into the closure by value: `let capturedRunID = self.currentRunID; motionManager.startDeviceMotionUpdates(...) { motion, _ in let frame = FilteredFrame(runID: capturedRunID, ...) }`. Restarting updates is required if the run ID changes.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Swift Testing (import Testing) |
| Config file | None -- detected automatically by Xcode 16+ |
| Quick run command | `xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:ArcticEdgeTests` |
| Full suite command | `xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 16 Pro'` |

**Note:** HealthKit and CMMotionManager do not function in Simulator. Tests for `WorkoutSessionManager` integration must be manual on a physical iPhone 16 Pro. All other Phase 1 components (filter, ring buffer, broadcaster, persistence logic) are fully testable in Simulator.

### Phase Requirements to Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| MOTN-01 | MotionManager emits FilteredFrame via AsyncStream | unit (mock CMMotionManager) | `xcodebuild test ... -only-testing:ArcticEdgeTests/MotionManagerTests` | Wave 0 |
| MOTN-02 | BiquadHighPassFilter passes >2Hz, rejects <0.5Hz sinusoid | unit (signal synthesis) | `xcodebuild test ... -only-testing:ArcticEdgeTests/BiquadFilterTests` | Wave 0 |
| MOTN-03 | RingBuffer drain() is atomic: no samples lost across concurrent append+drain | unit (actor concurrency) | `xcodebuild test ... -only-testing:ArcticEdgeTests/RingBufferTests` | Wave 0 |
| MOTN-04 | StreamBroadcaster delivers frames to two consumers without double-starting CMMotionManager | unit (mock MotionManager) | `xcodebuild test ... -only-testing:ArcticEdgeTests/StreamBroadcasterTests` | Wave 0 |
| MOTN-05 | Thermal state change adjusts deviceMotionUpdateInterval | unit (mock ProcessInfo notification) | `xcodebuild test ... -only-testing:ArcticEdgeTests/MotionManagerTests` | Wave 0 |
| SESS-01 | HKWorkoutSession starts successfully and reaches .running | manual (physical device) | N/A -- HealthKit unavailable in Simulator | N/A |
| SESS-02 | PersistenceService inserts 500 frames in one save, not 500 saves | unit (in-memory ModelContainer) | `xcodebuild test ... -only-testing:ArcticEdgeTests/PersistenceServiceTests` | Wave 0 |
| SESS-03 | FrameRecord and RunRecord schemas include #Index; queries on timestamp and runID are fast | unit (in-memory ModelContainer) | `xcodebuild test ... -only-testing:ArcticEdgeTests/PersistenceServiceTests` | Wave 0 |
| SESS-04 | Emergency flush drains ring buffer and saves on background notification | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/PersistenceServiceTests` | Wave 0 |
| SESS-05 | Orphan sentinel is set on session start and cleared on clean end; detected on relaunch | unit | `xcodebuild test ... -only-testing:ArcticEdgeTests/WorkoutSessionManagerTests` | Wave 0 |

### Sampling Rate

- **Per task commit:** Run the specific test file for the component just built.
- **Per wave merge:** Full `xcodebuild test` suite (all automated tests).
- **Phase gate:** Full suite green + manual HKWorkoutSession background test on physical iPhone 16 Pro before moving to Phase 2.

### Wave 0 Gaps

- [ ] `ArcticEdgeTests/Motion/BiquadFilterTests.swift` -- covers MOTN-02; needs synthetic 100Hz sine wave at 0.3Hz (reject) and 5Hz (pass)
- [ ] `ArcticEdgeTests/Motion/RingBufferTests.swift` -- covers MOTN-03; needs concurrent append+drain actor stress test
- [ ] `ArcticEdgeTests/Motion/MotionManagerTests.swift` -- covers MOTN-01, MOTN-05; needs `CMMotionManager` protocol wrapper for mocking
- [ ] `ArcticEdgeTests/Motion/StreamBroadcasterTests.swift` -- covers MOTN-04; verifies two AsyncStream consumers receive same frames
- [ ] `ArcticEdgeTests/Session/PersistenceServiceTests.swift` -- covers SESS-02, SESS-03, SESS-04; needs in-memory `ModelContainer` setup
- [ ] `ArcticEdgeTests/Session/WorkoutSessionManagerTests.swift` -- covers SESS-05; tests UserDefaults sentinel lifecycle
- [ ] Build setting: `SWIFT_STRICT_CONCURRENCY = complete` not yet set in `project.pbxproj` -- must be added as Wave 0 step before any actor code is written

---

## Sources

### Primary (HIGH confidence)

- Apple Developer Documentation - vDSP.Biquad: https://developer.apple.com/documentation/accelerate/vdsp/biquad
- Apple Developer Documentation - CMMotionManager.deviceMotionUpdateInterval: https://developer.apple.com/documentation/coremotion/cmmotionmanager/devicemotionupdateinterval
- Apple Developer Documentation - ProcessInfo.ThermalState: https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum
- Apple Developer Documentation - ModelContext.autosaveEnabled: https://developer.apple.com/documentation/swiftdata/modelcontext/autosaveenabled
- WWDC25 Session 322 "Track workouts with HealthKit on iOS and iPadOS" -- confirmed HKWorkoutSession on iPhone requires iOS 26
- WWDC24 Session 10137 "What's new in SwiftData" -- #Index macro, iOS 18 requirement
- WWDC24 Session 10179 "Meet Swift Testing" -- @Test, #expect, actor suite support
- WWDC23 Session 10023 "Build a multi-device workout app" -- HKWorkoutSession mirroring patterns
- WWDC22 Session 110351 "Beyond the Basics of Structured Concurrency" -- actor reentrancy
- Audio EQ Cookbook (W3C WebAudio): https://webaudio.github.io/Audio-EQ-Cookbook/audio-eq-cookbook.html -- HPF biquad coefficient formulas
- Swift Evolution SE-0314: AsyncStream -- HIGH confidence
- Training data: CoreMotion, HealthKit, Accelerate, SwiftData frameworks through August 2025

### Secondary (MEDIUM confidence)

- useyourloaf.com/blog/swiftdata-indexes/ -- #Index macro usage with multiple properties
- useyourloaf.com/blog/swiftdata-background-tasks/ -- @ModelActor pattern verified against Apple documentation
- polpiella.dev/core-data-swift-data-concurrency -- ModelActor thread safety, PersistentIdentifier pattern
- fatbobman.com/en/posts/concurret-programming-in-swiftdata/ -- ModelContext queue determination
- hackingwithswift.com (SwiftData by Example) -- autosaveEnabled patterns
- createwithswift.com/tracking-workouts-with-healthkit-in-ios-apps/ -- confirmed iOS 26 entitlement requirements
- gist.github.com/moutend/4f3a430e6d5a4cef4374d1947bbd3d73 -- vDSP.Biquad coefficient array order [b0, b1, b2, a1, a2]
- Swift Forums: AsyncStream and Actors (forums.swift.org/t/asyncstream-and-actors/70545) -- for-await pattern vs stored iterator

### Tertiary (LOW confidence -- flag for validation)

- The specific CPU budget duration granted by HKWorkoutSession on iPhone under iOS 26 at sustained 100Hz sensor capture -- no public measurement found; validate on physical device before Phase 2.
- The exact additional entitlement string (if any) beyond standard `com.apple.developer.healthkit` required for background iPhone workout sessions on iOS 26 -- verify against Xcode 26 Signing & Capabilities UI.

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- all frameworks are Apple-first-party with stable APIs; no third-party uncertainty
- Architecture: HIGH -- actor patterns and SwiftData @ModelActor are established; build order is dependency-correct
- Pitfalls: HIGH -- all critical pitfalls (Sendable boundary, reentrancy, autosave) are backed by documented Swift/SwiftData behavior
- HKWorkoutSession on iPhone: MEDIUM-HIGH -- iOS 26 requirement confirmed via WWDC25; exact background CPU budget duration not publicly documented
- Filter cutoff values: MEDIUM -- formula is correct; exact cutoff frequency requires empirical calibration with ski data
- SwiftData @ModelActor initialization threading: MEDIUM -- Task.detached pattern is well-documented; iOS 26 specific behavior unverified

**Research date:** 2026-03-08
**Valid until:** 2026-04-08 (stable Apple first-party APIs; HKWorkoutSession iPhone specifics may evolve in iOS 26 beta cycle)
