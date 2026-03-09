# Domain Pitfalls

**Domain:** iOS high-performance motion telemetry (skiing)
**Researched:** 2026-03-08
**Confidence:** MEDIUM-HIGH (verified against WWDC sessions and official Apple documentation where reachable; some findings carry LOW confidence from training data where official sources were inaccessible)

---

## Critical Pitfalls

Mistakes that cause silent data loss, rewrites, or App Store rejection.

---

### Pitfall 1: CMMotionManager Callback Threading Breaks Swift Strict Concurrency

**What goes wrong:** `CMMotionManager` calls its `deviceMotionUpdateInterval` handler on an `OperationQueue` you supply, not on an actor-isolated context. Under Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`), passing the `CMDeviceMotion` value or mutating actor state from inside that callback produces a Sendable violation. Developers work around this by marking closures `nonisolated` or using `MainActor.assumeIsolated`, but do it incorrectly, producing either a compile error or an unsafe suppression.

**Why it happens:** `CMDeviceMotion` is an Objective-C reference type. It does not conform to `Sendable`. The CoreMotion callback runs on a raw OS thread with no actor isolation guarantee. Swift's strict concurrency checker cannot statically verify that passing this value across the actor boundary is safe.

**Consequences:**
- Build fails with hundreds of Sendable errors when enabling complete checking.
- Suppression with `nonisolated(unsafe)` silences the compiler but reintroduces data races.
- If the actor processes the `CMDeviceMotion` reference after the callback returns, the reference's internal state may have changed (CoreMotion reuses objects internally in some modes).

**Prevention:**
1. Provide a dedicated `OperationQueue` (not `main`) to `startDeviceMotionUpdates(to:withHandler:)`.
2. Inside the handler, extract only primitive `Double` values (timestamp, roll, pitch, yaw, accelerations) immediately.
3. Wrap extracted values in a `Sendable` struct (all stored properties are value types: `Double`, `TimeInterval`).
4. Bridge into the actor with `Task { await motionActor.receive(sample) }`.
5. Never hold a reference to `CMDeviceMotion` across an `await` boundary.

**Warning signs:**
- Compiler emits "sending 'motion' risks causing data races" errors in your handler closure.
- You see `nonisolated(unsafe)` on any motion-related property as a suppression bandage.

**Phase:** Motion Engine (Phase 1) -- must be resolved before any other feature builds on top.

**Confidence:** HIGH (WWDC24 "Migrate your app to Swift 6", WWDC22 "Beyond the Basics of Structured Concurrency")

---

### Pitfall 2: Actor Reentrancy Corrupts Ring Buffer State

**What goes wrong:** The `MotionManager` actor accumulates samples and periodically flushes to SwiftData. If the flush is written as two separate `await` calls -- one to read the buffer, one to clear it -- another task can call `receive()` between the two awaits. The second sample lands in a buffer that is about to be cleared, and that sample disappears from the flush.

**Why it happens:** Actors are reentrant across `await` points. Between two `await` statements, the actor can interleave with other callers. This is the classic "non-transactional double-await" problem documented in WWDC22 "Visualize and Optimize Swift Concurrency."

**Consequences:** Silent sample loss at the boundary of every flush cycle. Under 100Hz sampling, a 1-second flush interval loses approximately 0 to 100 samples depending on flush timing. Over a 60-second run, that is measurable data gaps.

**Prevention:**
- Make read-and-clear a single synchronous, transactional method on the actor (no `await` inside). Call `drain()` as one atomic step: take the buffer contents and swap in an empty buffer in a single synchronous block.
- Pattern: `let chunk = buffer; buffer = []; return chunk` -- all synchronous, no awaits.

**Warning signs:**
- Flush cycle logs show sample counts lower than expected for the interval.
- Post-run waveform has periodic gaps of consistent duration matching flush frequency.

**Phase:** Motion Engine (Phase 1) / SwiftData persistence layer.

**Confidence:** HIGH (WWDC22 "Beyond the Basics of Structured Concurrency" -- actor reentrancy example with twin awaits)

---

### Pitfall 3: SwiftData Autosave Blocks the Main Thread at 100Hz

**What goes wrong:** SwiftData's default model container provides a `@MainActor`-bound model context that autosaves on UI events. If you insert `MotionSample` objects into this context at 100Hz directly, the save transaction fires on the main thread during every UI refresh cycle. At 120Hz ProMotion, every frame tick triggers a Core Data write. The app freezes during long runs.

**Why it happens:** SwiftData's main context is explicitly `MainActor`-aligned ("a special MainActor-aligned model context intended for working with ModelObjects in scenes and views" -- WWDC23 "Dive Deeper into SwiftData"). It is not designed for high-frequency inserts. Autosave is triggered by UI events, which at 120Hz means multiple times per second.

**Consequences:**
- Main thread hangs of 10-50ms per autosave under load.
- ProMotion drops to 60Hz or lower when the main thread is blocked.
- Thermal pressure accelerates because the main thread and disk I/O compete during sustained runs.

**Prevention:**
1. Create a detached background `ModelContext` for sensor data: `ModelContext(container)` off the main actor.
2. Disable autosave on this context (`autosaveEnabled = false` -- iOS 17+).
3. Accumulate samples in-memory (ring buffer in the `MotionManager` actor).
4. Flush to the background context in batches of 200-500 samples (2-5 seconds at 100Hz).
5. Call `try context.save()` explicitly on the background context after each batch.
6. The main context only handles run-level metadata (start time, total distance, etc.).

**Warning signs:**
- Time Profiler shows `NSManagedObjectContext save:` on the main thread during recording.
- The live waveform stutters at a regular interval (matching the flush period).

**Phase:** Persistence layer (Phase 1 or dedicated Phase 2 data layer).

**Confidence:** HIGH (WWDC23 "Dive Deeper into SwiftData", "Meet SwiftData")

---

### Pitfall 4: HKWorkoutSession Background Execution Does Not Resurrect a Terminated App

**What goes wrong:** Developers assume that because `HKWorkoutSession` grants background CPU budget, the app will be relaunched automatically if iOS terminates it mid-run (memory pressure, crash). It is not. If the app is killed with an active session, the session becomes orphaned. On relaunch, there is no automatic session recovery -- the app starts fresh with no in-progress session reference.

**Why it happens:** `HKWorkoutSession` on iPhone (not Watch) was introduced to provide a legitimate background CPU budget and HealthKit workout-builder integration. The "Workout processing" background mode keeps an already-running app alive, but it does not guarantee relaunch after termination. This is a different contract from a Watch, where the system takes more responsibility for session continuity.

**Consequences:**
- An entire ski run lost if the user receives a low-memory phone call that kills the app.
- The ring buffer in memory is discarded. If the SwiftData flush was mid-cycle, the last N seconds of the run are gone.
- The HealthKit workout builder may have an incomplete workout with no end event.

**Prevention:**
1. Flush the ring buffer to SwiftData aggressively when `applicationDidEnterBackground` fires (not just on the periodic timer).
2. On `applicationWillTerminate`, perform a synchronous (non-async) emergency flush. Keep the flush path free of `await` so it can complete in the termination window.
3. On app launch, check for an orphaned `HKWorkoutSession` via `HKHealthStore.workoutSessionMirroringStartHandler` and recover or discard it gracefully.
4. Write a "run in progress" sentinel to `UserDefaults` at session start; clear it at session end. On launch, if the sentinel is present, offer to recover partial data.

**Warning signs:**
- After a simulated memory kill (Xcode memory tool), re-opening the app shows no in-progress session.
- SwiftData run records have a start timestamp but no end timestamp.

**Phase:** Background execution / session lifecycle (Phase 1 hardening or Phase 2).

**Confidence:** MEDIUM (WWDC23 "Build a multi-device workout app" -- 10-second companion launch window implies session is not auto-restored; official Apple documentation inaccessible due to JavaScript requirement; training data supports this)

---

### Pitfall 5: High-Pass Filter Cutoff Chosen in Lab, Not on Snow

**What goes wrong:** The project specifies a high-pass filter passing frequencies above 2Hz and rejecting below 0.5Hz based on carving biomechanics reasoning. This is reasonable in theory, but if implemented without iterating on real snow data, the cutoff will reject or distort signals at edge transitions. Carve engagement at low speed (groomer traversals, flat sections near lifts) may have fundamental edge-pressure frequencies below 2Hz. Chairlift vibration from cable towers can have periodic impulses at 1-3Hz that the filter will pass as "skiing signal."

**Why it happens:** Filter design from biomechanical first principles is a starting hypothesis. The actual spectral content of skiing dynamics depends on snow conditions, ski geometry, skier mass, and run steepness -- none of which are controllable in pre-launch design.

**Consequences:**
- Activity detection misclassifies slow traversals as "not skiing."
- Chairlift cable-tower vibration impulses appear as carve spikes in post-run graphs.
- A fixed filter applied universally produces inconsistent results across different resort terrain profiles.

**Prevention:**
1. Implement the filter coefficients as runtime-configurable constants (not hard-coded). Use a `FilterConfig` struct stored in `UserDefaults` or a debug settings panel.
2. Log raw unfiltered sensor data alongside filtered data for the first N beta runs (write both to SwiftData, prune raw after verification).
3. Plan a filter calibration pass after first real-snow testing: record chairlift rides and downhill runs labeled manually, then analyze spectrograms.
4. Consider a second-order Butterworth rather than a simple first-order RC filter -- sharper rolloff reduces the risk of chairlift vibration leaking through.

**Warning signs:**
- Post-run graphs show carve spikes on the lift segment.
- Short flat sections between runs show no signal despite the skier walking or pushing with poles.

**Phase:** Motion Engine (Phase 1 implementation), calibration pass after first on-snow test.

**Confidence:** MEDIUM (signal processing principles, LOW on specific frequency values without real-world data)

---

### Pitfall 6: Activity Detection Confuses Chairlift Vibration for Skiing

**What goes wrong:** A simple threshold-based classifier (e.g., "g-force variance above X means skiing") fails in two common scenarios: (a) a gondola or high-speed detachable chair has substantial sway and vibration that triggers the "skiing" threshold, and (b) a slow, gliding traversal across a groomer has low variance and triggers the "chairlift/stopped" threshold.

**Why it happens:** Chairlift rides are not zero-motion events. Fixed-grip chairs sway significantly. High-speed detachable quads accelerate and brake with measurable g-forces. Simple energy-based classifiers cannot distinguish "periodic sway from a cable attachment" from "periodic carve forces from edging."

**Consequences:**
- Chairlift rides are recorded as ski runs, inflating run count and run time metrics.
- Slow traversals between runs are dropped from run records.
- Post-run analysis shows nonsensical carve-pressure spikes during lift time.
- Battery drains faster than expected because the app is recording and processing at full rate during 8-10 minute lift rides.

**Prevention:**
1. Fuse accelerometer data with GPS velocity (from `CLLocationManager`) for activity classification. Chairlifts move at predictable speeds (4-7 m/s typical); skiing moves at 5-30+ m/s. GPS velocity is a strong discriminator.
2. Add a chairlift-specific signature detector: look for periodic low-frequency oscillation (cable sway at 0.1-0.3Hz) combined with nearly constant heading.
3. Treat activity transitions as requiring hysteresis: require N consecutive seconds of "skiing signal" before starting a run, and M consecutive seconds of "non-skiing signal" before ending one.
4. Log GPS track alongside motion data during beta; display it in a debug view to manually verify segmentation quality.

**Warning signs:**
- Beta testers report extra "runs" appearing for lift rides.
- Run duration statistics include 8-10 minute entries with low average g-force.

**Phase:** Activity detection module (Phase 2 or dedicated classification phase).

**Confidence:** MEDIUM (domain knowledge of skiing telemetry; GPS fusion approach confirmed as standard in sports telemetry literature)

---

## Moderate Pitfalls

---

### Pitfall 7: Thermal Throttling Silently Reduces CoreMotion Update Rate

**What goes wrong:** On sustained 100Hz capture with live UI rendering, location services active, and SwiftData background writes all running simultaneously, the iPhone's thermal state climbs. iOS responds by throttling CPU clocks and, critically, can reduce the effective delivery rate of CoreMotion updates. The update interval property you set on `CMMotionManager` is a "desired" rate, not a guaranteed rate. The actual delivery rate silently decreases.

**Why it happens:** CoreMotion update rate is a hint to the hardware DSP. Under thermal pressure, the OS scheduler deprioritizes non-essential wakeups. The sensor fusion pipeline itself runs in the motion co-processor, but the delivery of results to the app is subject to scheduler priority. The app is never notified that its effective sample rate has decreased.

**Consequences:**
- The ring buffer fills at less than 100 samples/second without the app knowing.
- Signal processing code that assumes a fixed 10ms sample interval (e.g., Euler integration, filter difference equations) accumulates timing error.
- Post-run FFT analysis is incorrect if the sample rate is assumed constant.

**Prevention:**
1. Timestamp every sample using `CMDeviceMotion.timestamp` (device uptime, not wall clock). Never assume fixed intervals.
2. Compute actual elapsed time between consecutive samples in the processing path. If the gap exceeds 15ms (50% over nominal 10ms), flag it.
3. Use `ProcessInfo.processInfo.thermalState` and subscribe to `ProcessInfo.thermalStateDidChangeNotification`. When state reaches `.serious` or `.critical`, reduce UI rendering complexity (drop waveform refresh rate), disable GPS polling, and log a thermal event to the run record.
4. Profile in Instruments on a device in a warm environment (not climate-controlled lab) under full load before shipping.

**Warning signs:**
- Sample timestamps show gaps of 15-30ms interspersed with the expected 10ms intervals during long runs.
- Instruments "Thermal State" track shows `.fair` or higher state during recording tests.

**Phase:** Motion Engine hardening (Phase 1) and thermal response (Phase 1 or Phase 2 QA).

**Confidence:** MEDIUM (CoreMotion behavior under thermal pressure from training data; ProcessInfo thermal API is official iOS 11+)

---

### Pitfall 8: Cold Weather Reduces iPhone Battery Capacity by 20-40%

**What goes wrong:** At 0°C to -15°C (typical ski resort conditions), lithium-ion battery available capacity drops significantly. An iPhone 16 Pro with a full charge at room temperature may have effective capacity equivalent to 60-80% at ski resort temperatures when carried in an outer jacket pocket. If the app's battery usage has not been profiled under cold conditions, the estimated per-run and per-day battery consumption from lab tests will be significantly optimistic.

**Why it happens:** Lithium-ion electrochemical reaction rates slow with temperature. This reduces both capacity and peak discharge current. iPhones also run Low Power Mode or thermal protection that further reduces clock speeds when the battery voltage drops unexpectedly under load at cold temperatures.

**Consequences:**
- App shuts down mid-run due to unexpected low battery.
- iPhone unexpectedly powers off at 20-30% reported charge (because the battery management model was calibrated at room temperature).
- Users report the app "drains battery fast" even though lab profiling showed acceptable consumption.

**Prevention:**
1. Profile battery consumption via MetricKit / Xcode Organizer after beta release, specifically looking at ski-resort-temperature data from beta testers.
2. Implement a "Power Saver Recording" mode that reduces UI refresh rate (from 120Hz to 60Hz), disables GPS, and uses only the motion co-processor. Activate automatically when `UIDevice.current.batteryLevel < 0.30`.
3. Recommend in onboarding that users keep the iPhone in an inner pocket (body heat) and use a battery case for all-day sessions.
4. Design the app's battery consumption budget for the real operating environment: assume 65% effective battery capacity, not 100%.

**Warning signs:**
- Beta testers at ski resorts report 3-4 hour session battery drain while lab testing predicted 6+ hours.
- App logs show unexpected `UIApplicationWillResignActiveNotification` events mid-run at resorts.

**Phase:** Power management (Phase 2 or Phase 3 hardening).

**Confidence:** MEDIUM (well-established lithium-ion cold weather behavior; specific percentage ranges from materials science; iOS behavior confirmed in MetricKit docs)

---

### Pitfall 9: CMBatchedSensorManager Is Not a Drop-In for CMMotionManager

**What goes wrong:** iOS 17 introduced `CMBatchedSensorManager` providing 800Hz accelerometer and 200Hz device motion data. Developers see this and assume it is a better version of `CMMotionManager` for all use cases. They switch to it and lose real-time latency: `CMBatchedSensorManager` delivers data in one-batch-per-second intervals by design. For a live telemetry waveform (which requires sub-100ms update latency), this is unusable.

Additionally, `CMBatchedSensorManager` requires an active HealthKit workout session to operate -- it will not run without one. If `HKWorkoutSession` is not yet started when the app tries to start `CMBatchedSensorManager`, the manager silently fails or throws.

**Why it happens:** Apple designed `CMBatchedSensorManager` for sports analytics use cases (golf swing, tennis impact detection) where you need the highest possible sample density but can tolerate batch latency. The ArcticEdge use case requires both high rate and low latency for the live dashboard.

**Prevention:**
1. Use `CMMotionManager` at 100Hz for the live recording path. This provides adequate density for carve pressure analysis and delivers per-sample in real time.
2. Do not use `CMBatchedSensorManager` unless a post-run reanalysis feature needs higher-rate replay data.
3. If ever integrating `CMBatchedSensorManager`, ensure `HKWorkoutSession` is `.running` state before calling `startAccelerometerUpdates()`. Handle the case where the session has not started yet with an explicit guard.

**Warning signs:**
- Live waveform updates in 1-second jumps instead of continuously.
- The motion manager throws an authorization error when the workout session has not been started.

**Phase:** Motion Engine (Phase 1) -- choose the right API from day one.

**Confidence:** HIGH (WWDC23 "What's new in Core Motion" session 10179 -- explicitly states CMBatchedSensorManager requires active HealthKit workout session and delivers one batch per second)

---

### Pitfall 10: Background Execution Terminated When HKWorkoutSession Enters Paused State

**What goes wrong:** If the user explicitly pauses the HKWorkoutSession (e.g., to take a photo at the top), or if the session is paused automatically (incoming phone call), the background CPU budget associated with the session is reduced or suspended. CoreMotion may continue delivering updates to the co-processor hardware, but the app's main process may be suspended before it can consume them.

**Why it happens:** The "Workout processing" background mode provides elevated CPU access while the workout is in `.running` state. In `.paused` state, the app regresses to standard background execution rules. The `CMMotionManager` instance is still configured, but there is no guarantee the app will be woken to process its callbacks.

**Consequences:**
- Gaps in motion data during pause/resume transitions.
- If the user pauses at the top of a run, then resumes while skiing, the first 1-10 seconds of the run may be missing.
- The ring buffer does not fill during suspension, so the flush cycle after resume has no gap -- the gap is just absent from the data, not flagged.

**Prevention:**
1. Observe `HKWorkoutSessionDelegate.workoutSession(_:didChangeTo:from:date:)`. On transition to `.paused`, log a pause event with timestamp to the run record.
2. On transition back to `.running`, insert a gap-marker sample into the buffer with an explicit "recording resumed" flag.
3. Consider holding a `UIBackgroundTaskIdentifier` during the pause-to-resume transition window (up to 30 seconds) to buffer any pending samples.
4. In the post-run dashboard, display gaps explicitly rather than interpolating across them.

**Warning signs:**
- Run records show time jumps (e.g., a 10-second gap in timestamps) at pause/resume boundaries.
- Post-run waveform shows a flat zero section that does not correspond to a stationary period.

**Phase:** Background execution / session lifecycle (Phase 1 hardening).

**Confidence:** MEDIUM (background mode behavior under pause state from training data; HKWorkoutSession state machine is documented but session page inaccessible)

---

## Minor Pitfalls

---

### Pitfall 11: Kalman Filter Divergence from Initialization Transient

**What goes wrong:** A Kalman filter for sensor fusion requires initial state estimates for position, velocity, and the covariance matrix. If the filter starts with incorrect initial state (common when the user puts on the app and immediately starts moving), it takes 2-5 seconds to converge. The carve pressure signal during this convergence window is garbage -- large transient spikes that will appear in the post-run graph.

**Prevention:**
- Require the user to hold the phone still for 2 seconds at session start (show a calibration indicator in the UI).
- Mark the first 3 seconds of every run as "warm-up" and exclude from run statistics. Display them on the graph with a visual indicator.
- Alternatively: use the simpler complementary filter (alpha-beta) for real-time display and run a Kalman smoother offline in post-run analysis where convergence is not a concern.

**Phase:** Motion Engine (Phase 1) and post-run analysis (later phase).

**Confidence:** MEDIUM (signal processing domain knowledge)

---

### Pitfall 12: SwiftData Index Missing on Timestamp Causes Slow Post-Run Queries

**What goes wrong:** Post-run analysis queries all `MotionSample` records for a given run, filtered and sorted by timestamp. Without a `#Index` on the timestamp property, SwiftData/Core Data performs a full table scan. After 5+ runs of 5000 samples each, this query takes hundreds of milliseconds on the main thread.

**Prevention:**
- Add `#Index<MotionSample>([\.timestamp], [\.runID, \.timestamp])` to the model.
- Add `#Index<MotionSample>([\.runID])` to support efficient per-run fetches.
- Profile queries with Instruments after accumulating 20+ runs of data before shipping.

**Phase:** Data model design (Phase 1 or data layer phase).

**Confidence:** HIGH (WWDC24 "What's new in SwiftData" -- #Index macro documented explicitly)

---

### Pitfall 13: AsyncStream Backpressure Overflow at 100Hz

**What goes wrong:** An `AsyncStream<MotionSample>` with a default `.bufferNewest(1)` or `.bufferOldest(1)` buffering policy will silently drop samples if the consumer (the processing actor) is slower than the 10ms production interval. The `CMMotionManager` callback produces at 100Hz; any `await` in the consumer longer than 10ms causes the stream buffer to fill and drop.

**Prevention:**
- Use `.unbounded` buffer policy on the `AsyncStream` and monitor buffer depth with a counter.
- Keep the stream consumer loop free of blocking `await` calls. The consumer should only enqueue into the in-memory ring buffer (synchronous); the ring buffer flush to SwiftData happens on a separate, less-frequent cycle.
- Add a debug metric: samples produced vs. samples consumed per second. Log a warning if the ratio drops below 0.99.

**Phase:** Motion Engine (Phase 1).

**Confidence:** MEDIUM (AsyncStream buffer policy behavior from official docs)

---

### Pitfall 14: GPS Always-On During Recording Drains Battery Faster Than Expected

**What goes wrong:** Using `CLLocationManager` in full accuracy mode (for activity classification and speed discrimination) runs the GPS hardware continuously. On an iPhone 16 Pro, full GPS adds approximately 10-15% additional battery drain per hour. For an 8-hour ski day, this is 80-120% of battery capacity from GPS alone -- before counting the motion processing, display, and SwiftData writes.

**Prevention:**
- Use `CLLocationManager` in `.reducedAccuracy` mode or with `desiredAccuracy = kCLLocationAccuracyHundredMeters` for activity classification. Speed and heading are sufficient for chairlift discrimination -- you do not need GPS-level position accuracy.
- Alternatively, use activity classification from the accelerometer alone (chairlift vs. skiing classifier) and only enable GPS in brief bursts when the classifier is uncertain (hysteresis zone).
- Disable GPS entirely when in `.paused` state.

**Phase:** Activity detection module and power management phase.

**Confidence:** MEDIUM (GPS battery behavior documented by Apple in energy efficiency guidelines; specific percentages from MetricKit aggregate data in training data)

---

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| Motion Engine actor design | CMMotionManager callback Sendable violation (Pitfall 1) | Extract primitives immediately; bridge via Sendable struct |
| Ring buffer flush logic | Actor reentrancy data loss (Pitfall 2) | Synchronous drain() with no internal awaits |
| SwiftData integration | Main-thread autosave at 100Hz (Pitfall 3) | Background ModelContext, explicit batched saves |
| Background session setup | CMBatchedSensorManager wrong API choice (Pitfall 9) | Use CMMotionManager; CMBatchedSensorManager is batch-latency |
| Background session lifecycle | HKWorkoutSession termination and pause behavior (Pitfalls 4, 10) | Sentinel in UserDefaults; emergency flush in willTerminate |
| Filter implementation | Cutoff chosen without on-snow data (Pitfall 5) | Configurable coefficients; log raw + filtered for calibration |
| Activity classifier | Chairlift vs. skiing false positives (Pitfall 6) | Fuse GPS velocity; hysteresis on state transitions |
| Thermal management | Silent CoreMotion rate reduction (Pitfall 7) | Timestamp-based gap detection; ProcessInfo.thermalState observer |
| On-mountain QA | Cold weather battery model is wrong (Pitfall 8) | Design for 65% effective capacity; Power Saver mode |
| Data model | Missing index on timestamp (Pitfall 12) | Add #Index at model definition time |
| AsyncStream pipeline | Backpressure overflow at 100Hz (Pitfall 13) | .unbounded buffer; synchronous ring buffer consumer |
| GPS activity classification | Always-on GPS battery drain (Pitfall 14) | Reduced accuracy mode or intermittent polling |

---

## Sources

- WWDC23 "What's new in Core Motion" (session 10179) -- CMBatchedSensorManager requires active HKWorkoutSession; batch latency design
- WWDC24 "Migrate your app to Swift 6" (session 10169) -- Global mutable state, Sendable violations, delegate callback isolation patterns
- WWDC22 "Beyond the Basics of Structured Concurrency" (session 110351) -- Actor reentrancy, non-transactional double-await data races
- WWDC23 "Dive Deeper into SwiftData" (session 10196) -- MainActor-bound main context, enumerate() for batch traversal
- WWDC23 "Meet SwiftData" (session 10187) -- ModelContext autosave triggers on UI events
- WWDC24 "What's new in SwiftData" (session 10137) -- #Index macro for query performance
- WWDC23 "Build a multi-device workout app" (session 10023) -- 10-second companion launch window implies no auto-restore of orphaned session
- WWDC20 "Explore the Action and Vision app" (session 10099) -- Buffer release and backpressure patterns for high-rate data pipelines
- ProcessInfo.thermalState: official iOS 11+ API (HIGH confidence)
- Apple Energy Efficiency Guide for iOS Apps: GPS battery drain guidance
