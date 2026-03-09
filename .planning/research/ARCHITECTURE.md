# Architecture Patterns

**Domain:** High-performance iOS motion telemetry (skiing)
**Researched:** 2026-03-08
**Confidence:** HIGH (established Swift concurrency patterns, CoreMotion, HealthKit lifecycle)

---

## Recommended Architecture

ArcticEdge is structured as a layered pipeline: sensors feed a processing actor, which writes to a hybrid buffer, which publishes to UI via AsyncStream. Persistence and HealthKit are side-effects of the pipeline, not inline concerns.

```
CoreMotion (100Hz)
       |
       v
 MotionManager (Actor)
  - receives CMDeviceMotion callbacks
  - applies high-pass filter inline
  - writes to RingBuffer
  - yields filtered frames to AsyncStream
       |
       +----> RingBuffer (actor-protected value type)
       |        - in-memory, fixed capacity (~10s at 100Hz = 1000 frames)
       |        - overwrite-oldest on overflow
       |        - periodic flush trigger (every N frames or time interval)
       |                |
       |                v
       |          SwiftData flush (background ModelContext)
       |            - batched inserts, not per-frame
       |            - crash-safe: buffer drains before session ends
       |
       v
 TelemetryStream (AsyncStream<FilteredFrame>)
  - consumed by LiveViewModel (@Observable, @MainActor)
  - drives live waveform + metric cards
       |
       v
 LiveTelemetryView (SwiftUI)
  - scrolling carve-pressure waveform
  - frosted glass metric cards (pitch, roll, g-force)
  - reads from LiveViewModel only

 HKWorkoutSession (separate actor or class, HealthKit delegate)
  - starts/stops alongside MotionManager
  - provides background CPU budget
  - session state changes propagate to MotionManager via continuation

 ActivityClassifier (actor)
  - consumes same FilteredFrame stream (fan-out)
  - classifies: skiing vs. chairlift
  - emits ActivitySegment events to SessionManager

 SessionManager (@Observable, @MainActor)
  - owns run segments
  - writes segment boundaries to SwiftData
  - notifies PostRunViewModel when run completes

 PostRunViewModel (@Observable, @MainActor)
  - loads completed run data from SwiftData (main ModelContext)
  - drives PostRunAnalysisView

 PostRunAnalysisView (SwiftUI)
  - charts per-segment: speed, g-force, carve pressure
  - no live stream dependency -- pure SwiftData reads
```

---

## Component Boundaries

| Component | Responsibility | Consumes | Produces |
|-----------|---------------|----------|----------|
| `MotionManager` (actor) | CoreMotion ingestion, high-pass filter, stream emission | `CMDeviceMotion` callbacks | `AsyncStream<FilteredFrame>` |
| `RingBuffer` (actor) | Fixed-capacity in-memory frame storage | `FilteredFrame` | Batch array for flush; recent-N frames for live display |
| `PersistenceService` (actor) | SwiftData batch writes | `[FilteredFrame]` from ring buffer | `ModelContext` commits |
| `ActivityClassifier` (actor) | Classify skiing vs. chairlift | `FilteredFrame` | `ActivitySegment` events |
| `SessionManager` (@Observable @MainActor) | Run lifecycle, segment bookkeeping | `ActivitySegment` events | `RunRecord` (SwiftData model) |
| `WorkoutSessionManager` (class, HealthKit delegate) | HKWorkoutSession lifecycle | User start/stop signals | Background CPU grant; session state |
| `LiveViewModel` (@Observable @MainActor) | Bridge pipeline to live UI | `AsyncStream<FilteredFrame>` | Published frame + metrics for view |
| `PostRunViewModel` (@Observable @MainActor) | Bridge SwiftData to analysis UI | `RunRecord` from SwiftData | Processed chart data |
| `LiveTelemetryView` (SwiftUI) | Real-time dashboard | `LiveViewModel` | None |
| `PostRunAnalysisView` (SwiftUI) | Post-run charting | `PostRunViewModel` | None |

**Key boundaries:**

- Actors never call `@MainActor` methods directly -- they publish via `AsyncStream` or `continuation.yield`.
- `@MainActor` ViewModels never access `CMMotionManager` or `ModelContext` off the main actor.
- `SwiftData` has two `ModelContext` instances: one background context (in `PersistenceService` actor) for writes, one main context for reads in ViewModels.
- `HKWorkoutSession` delegate methods arrive on an unspecified queue -- always wrap in `Task { @MainActor in }` or route through actor.

---

## Data Flow

### Hot Path (100Hz, latency-sensitive)

```
CMMotionManager.startDeviceMotionUpdates(to:queue:)
  --> MotionManager actor (serial operation queue, not main)
      --> high-pass filter (synchronous, ~microseconds)
      --> RingBuffer.append(frame)          [actor hop, non-blocking]
      --> continuation.yield(frame)         [AsyncStream -- no allocation]
        --> LiveViewModel.Task { for await frame in stream }
            --> @MainActor publish to view   [one hop per frame]
```

Frame objects must be value types (structs). No heap allocation in the hot path beyond the stream buffer. The `continuation.yield` in `AsyncStream` is the only crossing between the MotionManager actor and the consumer -- this is the backpressure point.

### Warm Path (periodic, ~1s intervals)

```
RingBuffer.flushIfNeeded()   [called from MotionManager after N frames]
  --> PersistenceService.persist([FilteredFrame])
      --> background ModelContext.insert(batch)
      --> ModelContext.save()
```

Flush is triggered by the MotionManager after accumulating a batch (e.g., every 100 frames = 1 second at 100Hz). The PersistenceService actor serializes all SwiftData writes, so multiple callers are safe.

### Classification Path (async, low-frequency)

```
same AsyncStream fan-out (second consumer, or windowed copy from RingBuffer)
  --> ActivityClassifier.classify(window: [FilteredFrame])
      --> emits ActivitySegment (skiing | chairlift | unknown)
      --> SessionManager.handleSegment(segment)
          --> creates or closes RunRecord
          --> PersistenceService.persist(runRecord)
```

Classification operates on windows (e.g., 2-second sliding window, 200 frames). It runs on the ActivityClassifier actor's executor, not the hot path. Emit rate is low (~0.5Hz decisions), so it never blocks the sensor pipeline.

### Background Path (HKWorkoutSession)

```
User taps "Start Run"
  --> WorkoutSessionManager.startSession()
      --> HKHealthStore.startWorkoutSession(session)
          --> delegate: didChangeTo(.running)
              --> MotionManager.start()   [actor method, async]

Screen locks / app backgrounds
  --> iOS grants background CPU via workout session
  --> MotionManager continues at 100Hz
  --> RingBuffer + PersistenceService continue flushing
  --> LiveViewModel pauses (no UI, but stream is still consumed to prevent backpressure buildup)
```

The `HKWorkoutSession` must be started before `CMMotionManager` to guarantee the background CPU budget is active when motion capture begins.

### Post-Run Path (cold, on-demand)

```
SessionManager.finalizeRun(runID)
  --> PersistenceService flushes remaining buffer
  --> RunRecord.isComplete = true; save
  --> SessionManager publishes runCompletedID via continuation or @Observable

PostRunViewModel.load(runID)
  --> main ModelContext.fetch(RunRecord where id == runID)
  --> fetch associated FrameRecords (paginated if large)
  --> compute chart series (pitch/roll/g-force over time)
  --> publish to PostRunAnalysisView
```

---

## Patterns to Follow

### Pattern 1: Actor as Sensor Boundary

Wrap `CMMotionManager` entirely inside an actor. The actor is the only object that touches the motion manager instance. All output leaves via `AsyncStream`.

```swift
actor MotionManager {
    private let motionManager = CMMotionManager()
    private var continuation: AsyncStream<FilteredFrame>.Continuation?

    var frames: AsyncStream<FilteredFrame> {
        AsyncStream { [weak self] continuation in
            self?.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                self?.motionManager.stopDeviceMotionUpdates()
            }
        }
    }

    func start() {
        motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
        motionManager.startDeviceMotionUpdates(to: .current ?? .main) { [weak self] motion, _ in
            guard let motion else { return }
            Task { await self?.process(motion) }
        }
    }

    private func process(_ motion: CMDeviceMotion) {
        let frame = filter(motion)          // synchronous filter
        ringBuffer.append(frame)
        continuation?.yield(frame)
    }
}
```

Key: `OperationQueue.current` inside the actor ensures CoreMotion callbacks are serialized on the actor's executor. No `nonisolated` tricks needed.

### Pattern 2: Ring Buffer as Fixed-Capacity Actor

A ring buffer avoids unbounded growth. At 100Hz with 1000-frame capacity, memory footprint is bounded at ~200KB (200 bytes per frame * 1000 frames).

```swift
actor RingBuffer {
    private var buffer: [FilteredFrame]
    private var head = 0
    private var count = 0
    private let capacity: Int

    init(capacity: Int = 1000) {
        self.capacity = capacity
        self.buffer = Array(repeating: .zero, count: capacity)
    }

    func append(_ frame: FilteredFrame) {
        buffer[head % capacity] = frame
        head = (head + 1) % capacity
        count = min(count + 1, capacity)
    }

    func drain() -> [FilteredFrame] {
        // returns ordered copy, resets
        let result = orderedFrames()
        count = 0
        head = 0
        return result
    }
}
```

The `drain()` method is called by `PersistenceService` on a timer or frame-count threshold. The ring buffer never blocks the hot path because `append` is O(1).

### Pattern 3: AsyncStream Fan-Out via Broadcast Actor

A single `CMMotionManager` stream needs two consumers: `LiveViewModel` and `ActivityClassifier`. Fan-out via a broadcast actor avoids multiple `CMMotionManager` start calls (which fail silently).

```swift
actor StreamBroadcaster {
    private var continuations: [UUID: AsyncStream<FilteredFrame>.Continuation] = [:]

    func makeStream() -> (AsyncStream<FilteredFrame>, UUID) {
        var id = UUID()
        let stream = AsyncStream { continuation in
            id = UUID()
            continuations[id] = continuation
        }
        return (stream, id)
    }

    func broadcast(_ frame: FilteredFrame) {
        continuations.values.forEach { $0.yield(frame) }
    }

    func cancel(id: UUID) {
        continuations[id]?.finish()
        continuations.removeValue(forKey: id)
    }
}
```

`MotionManager` calls `broadcaster.broadcast(frame)` instead of directly holding one continuation. Each consumer gets its own stream.

### Pattern 4: SwiftData Dual-Context Pattern

Two ModelContext instances, never shared between actors:

```swift
// In PersistenceService actor (background writes)
private let backgroundContext: ModelContext

// In PostRunViewModel @MainActor (reads)
@Environment(\.modelContext) private var mainContext
```

Batch inserts use `backgroundContext.insert()` followed by `backgroundContext.save()` every ~100 frames. Never insert per-frame on the main context -- SwiftData's main context is for reads and single-record mutations only in this architecture.

Schema design: `FrameRecord` is a lightweight `@Model` with a relationship to `RunRecord`. Avoid `Codable` serialization per frame -- store raw float fields directly on the model to let SwiftData use its native column layout.

### Pattern 5: HKWorkoutSession as CPU Budget Gate

The workout session is the "permission slip" for background CPU. The architecture enforces this by requiring session state `.running` before allowing `MotionManager.start()`.

```swift
// WorkoutSessionManager is NOT an actor -- HKWorkoutSessionDelegate requires class
final class WorkoutSessionManager: NSObject, HKWorkoutSessionDelegate {
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    var onStateChange: ((HKWorkoutSessionState) -> Void)?

    func workoutSession(_ session: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            self.onStateChange?(toState)
        }
    }
}
```

State changes route to `@MainActor` so `SessionManager` (also `@MainActor`) can react safely. The `onStateChange` closure is the only coupling between HealthKit and the rest of the pipeline.

---

## Anti-Patterns to Avoid

### Anti-Pattern 1: Per-Frame SwiftData Writes

**What:** Calling `modelContext.save()` on every `CMDeviceMotion` callback.
**Why bad:** At 100Hz, this is 100 SQLite transactions per second. CPU usage spikes, thermal throttling degrades sensor accuracy within minutes, battery drains.
**Instead:** Batch writes every 100 frames (1 second). Use the ring buffer as the accumulator.

### Anti-Pattern 2: Storing CMDeviceMotion Objects

**What:** Capturing `CMDeviceMotion` instances directly in the ring buffer or SwiftData models.
**Why bad:** `CMDeviceMotion` is an Objective-C object; it is not `Sendable`. Crossing actor boundaries with it triggers strict concurrency errors. It also holds a strong reference to the motion manager's internal state.
**Instead:** Convert to a `FilteredFrame` value type (struct) immediately in the `MotionManager` actor before any inter-actor communication.

### Anti-Pattern 3: @Published / Combine in the Hot Path

**What:** Using `PassthroughSubject` or `@Published` to emit 100Hz data to the UI.
**Why bad:** Combine's sink executes on the publisher's scheduler by default, requiring explicit `receive(on: DispatchQueue.main)`. Under high frequency, this creates scheduling pressure. More critically, Combine is not `Sendable`-safe, causing warnings under strict concurrency.
**Instead:** `AsyncStream` with `for await` on `@MainActor`. One clean hop, fully `Sendable`, structured lifetime.

### Anti-Pattern 4: Starting CoreMotion Before HKWorkoutSession

**What:** Starting `CMMotionManager` immediately on app launch or at "start run" tap without waiting for HealthKit session confirmation.
**Why bad:** App moves to background mid-run. Without an active `HKWorkoutSession`, iOS suspends the app within seconds. Motion capture silently stops. Data is lost.
**Instead:** Always await `workoutSession(_:didChangeTo:.running)` before calling `MotionManager.start()`.

### Anti-Pattern 5: Using CMMotionManager from Multiple Actors

**What:** Multiple components holding references to the same `CMMotionManager` instance and calling `startDeviceMotionUpdates` independently.
**Why bad:** A second `startDeviceMotionUpdates` call on an already-running manager silently replaces the update handler. Data from the first consumer is dropped.
**Instead:** One `MotionManager` actor owns the `CMMotionManager`. Fan-out is handled by `StreamBroadcaster`.

### Anti-Pattern 6: nonisolated CoreMotion Callback

**What:** Marking the `CMMotionManager` update block as `nonisolated` to avoid actor hopping.
**Why bad:** CoreMotion callbacks arrive on an internal operation queue. Writing to actor-isolated state from `nonisolated` context without `Task { await actor.method() }` is a data race. Under strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`), the compiler will reject this.
**Instead:** The callback always uses `Task { await self.process(motion) }` to hop onto the actor's executor.

---

## Scalability Considerations

| Concern | MVP (single run, 1 user) | v2 (multiple runs, charts) | v3 (long-term history) |
|---------|--------------------------|---------------------------|------------------------|
| Frame storage | In-memory ring buffer + periodic flush | SwiftData with indexed RunRecord | Paginated fetch descriptors; consider CloudKit sync |
| Filter complexity | Single high-pass filter | Add edge-detection pass, speed estimation | Per-activity calibration profiles |
| Classification | Simple threshold classifier | ML model via CoreML (trained on real ski data) | On-device training from user corrections |
| Chart rendering | Swift Charts on loaded array | Paginated Swift Charts with `chartOverlayContent` | Downsampled series for large datasets |
| Background time | HKWorkoutSession only | Same -- sufficient for full-day use | Same |
| Thermal management | iPhone 16 Pro has headroom | Monitor `ProcessInfo.thermalState`; reduce Hz if `.serious` | Adaptive Hz: 100Hz carving, 25Hz chairlift |

---

## Suggested Build Order

Dependencies drive this order. Each layer requires the one below to be testable.

```
1. FilteredFrame struct + high-pass filter logic
   (Pure value type, no dependencies -- fully unit-testable with Swift Testing)

2. RingBuffer actor
   (Depends on FilteredFrame only -- test append/drain/overflow semantics)

3. MotionManager actor (with mock CMDeviceMotion injection)
   (Depends on RingBuffer + filter -- test stream emission, actor isolation)

4. StreamBroadcaster actor
   (Depends on MotionManager -- test fan-out, cancellation)

5. PersistenceService actor + SwiftData schema
   (Depends on FilteredFrame -- test batch writes, flush triggers)

6. WorkoutSessionManager (HealthKit)
   (Depends on nothing in the pipeline -- test state machine separately)

7. ActivityClassifier actor
   (Depends on FilteredFrame + StreamBroadcaster -- test classification windows)

8. SessionManager (@MainActor)
   (Depends on ActivityClassifier + PersistenceService -- integration point)

9. LiveViewModel (@MainActor)
   (Depends on StreamBroadcaster -- test @MainActor publishing)

10. LiveTelemetryView (SwiftUI)
    (Depends on LiveViewModel -- UI integration, no unit tests required)

11. PostRunViewModel (@MainActor)
    (Depends on PersistenceService + SessionManager -- test data loading)

12. PostRunAnalysisView (SwiftUI)
    (Depends on PostRunViewModel -- UI integration)
```

**Phase gate:** Steps 1-4 form the Motion Engine. Steps 5-8 form the Session Layer. Steps 9-12 form the UI Layer. Each gate can be shipped and tested independently.

---

## Sources

Note: Apple Developer documentation (developer.apple.com) requires JavaScript and could not be fetched programmatically. The following findings are based on MEDIUM-HIGH confidence from training data (Swift concurrency patterns established in Swift 5.5-5.10, CoreMotion patterns stable since iOS 11, SwiftData patterns from iOS 17+, HealthKit workout session patterns from iOS 17+).

- Swift Evolution SE-0314: AsyncStream (HIGH confidence -- shipped Swift 5.5)
- Swift Evolution SE-0337: Incremental migration to concurrency (HIGH confidence)
- CoreMotion `CMMotionManager` threading model: one manager per app, callbacks on provided OperationQueue (HIGH confidence -- documented constraint)
- HKWorkoutSession background CPU budget for iPhone: requires HealthKit entitlement + workout session in `.running` state (HIGH confidence)
- SwiftData dual-context pattern (background writes, main-thread reads): consistent with Apple's own recommendations from WWDC 2023 SwiftData sessions (MEDIUM confidence -- session content from training)
- Ring buffer architecture for high-frequency sensors: standard pattern in audio/signal processing, well-established in iOS DSP apps (HIGH confidence)
- Swift Testing framework (`import Testing`): shipped Xcode 16 / Swift 6 (HIGH confidence)
