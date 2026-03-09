# Technology Stack

**Project:** ArcticEdge
**Researched:** 2026-03-08
**Confidence:** MEDIUM-HIGH (training data through August 2025; external docs unreachable during this session -- see confidence notes per section)

---

## Recommended Stack

### Core Sensor Layer

| Technology | Version / Target | Purpose | Why |
|------------|-----------------|---------|-----|
| CoreMotion / CMMotionManager | iOS 18+ (framework stable since iOS 4, 100Hz since iPhone 4S) | 100Hz device motion stream: attitude, rotationRate, userAcceleration, gravity | Only Apple-first-party path to fused IMU data. `CMDeviceMotion` gives sensor-fused attitude (quaternion), calibrated rotation rate, and gravity-corrected linear acceleration simultaneously. No third-party alternative exists on-device. |
| CMDeviceMotion | iOS 18+, deviceMotionUpdateInterval = 0.01 (100Hz) | Primary telemetry source | Set `deviceMotionUpdateInterval = 1.0/100.0` on `CMMotionManager`. iPhone 16 Pro's Apple A18 Pro handles 100Hz comfortably. Use `startDeviceMotionUpdates(to:withHandler:)` wrapped in `AsyncStream` via a continuation. |
| CMAttitudeReferenceFrame | `.xMagneticNorthZVertical` | Absolute orientation reference | Required for meaningful heading data on a mountain. Falls back to `.xArbitraryZVertical` if magnetometer unavailable (underground/lift). |

**Confidence:** HIGH -- CoreMotion at 100Hz on iPhone Pro is well-documented and validated behavior predating this project.

**What NOT to use:**
- `CMAccelerometer` raw (no fusion, no attitude) -- use `CMDeviceMotion` only
- Combine (`receiveOn:`) for the sensor pipeline -- structured concurrency (`AsyncStream`) fits the Swift 7 mandate and avoids Combine's type-erasure overhead at 100Hz
- `startAccelerometerUpdates(to:withHandler:)` callback pattern -- wrap in `AsyncStream` instead

---

### Concurrency Architecture

| Technology | Version / Target | Purpose | Why |
|------------|-----------------|---------|-----|
| Swift Concurrency (Actor, AsyncStream, Task) | Swift 6+ (Swift 7 targeted) | Sensor pipeline, data flow isolation | `Actor` enforces serial access to the ring buffer without locks. `AsyncStream` bridges CMMotionManager callbacks into the structured concurrency world. `TaskGroup` enables parallel flush + UI update without data races. |
| `@Observable` macro | iOS 17+, Swift 5.9+ | ViewModel / UI model layer | Replaces ObservableObject. Granular dependency tracking reduces unnecessary SwiftUI re-renders at 100Hz update rates. Use for MotionViewModel holding aggregated display values (not raw sensor structs). |
| `withTaskCancellationHandler` | Swift 5.9+ | Graceful sensor teardown | Ensures CMMotionManager stops when the enclosing Task is cancelled (e.g., app background without workout). |

**Confidence:** HIGH -- Swift 6 strict concurrency and `@Observable` shipped in iOS 17/Swift 5.9 and are well-established.

**Actor pattern for MotionManager:**
```swift
actor MotionManager {
    private let motionManager = CMMotionManager()
    private var continuation: AsyncStream<CMDeviceMotion>.Continuation?

    func startStream() -> AsyncStream<CMDeviceMotion> {
        AsyncStream { continuation in
            self.continuation = continuation
            motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
            motionManager.startDeviceMotionUpdates(to: .main) { motion, error in
                guard let motion else { return }
                continuation.yield(motion)
            }
        }
    }
}
```

**What NOT to use:**
- `DispatchQueue` or `OperationQueue` for sensor data -- Actors replace this
- Global actors for MotionManager -- it needs its own isolated actor to avoid blocking `@MainActor`
- `@MainActor` for the sensor loop itself -- dispatch only aggregated/display values to main

---

### Signal Processing

| Technology | Version / Target | Purpose | Why |
|------------|-----------------|---------|-----|
| Accelerate framework (vDSP) | iOS 13+ (ships with OS) | High-pass filter, FFT, vector math | Apple's SIMD-accelerated DSP framework. Zero dependencies, no App Store risk. `vDSP_biquad` implements IIR biquad filters (Butterworth high-pass at 0.5Hz/2Hz cutoffs) at native SIMD throughput. Processes 100 samples/sec trivially on A18 Pro. |
| vDSP biquad filter | Via Accelerate | Carve pressure isolation filter | Two cascaded biquad stages: (1) high-pass at 2Hz to reject postural sway, (2) low-pass at ~25Hz to reject aliasing. Coefficients computed once at init using bilinear transform at Fs=100Hz. |
| simd (Swift simd types) | Swift 5.5+ | Quaternion math, vector arithmetic | `simd_quatd` for attitude quaternion operations. No external library needed -- simd types are first-party and zero-cost on A18. |

**Confidence:** HIGH -- Accelerate/vDSP is the standard Apple-platform DSP path. No viable Swift-native alternative with comparable performance exists.

**What NOT to use:**
- Any Python-originated signal processing library ported to Swift -- Accelerate is sufficient and safer
- CoreML for the filter -- overkill for fixed-coefficient IIR; CoreML adds latency and model management overhead
- `vDSP_conv` (FIR convolution) instead of biquad IIR -- FIR requires long taps for steep cutoffs at 100Hz; biquad IIR is far more efficient here

---

### Persistence

| Technology | Version / Target | Purpose | Why |
|------------|-----------------|---------|-----|
| SwiftData | iOS 17+ (required), iOS 18 for history tracking | Structured run/segment/sample persistence | First-party Swift-native ORM. `@Model` macro, `ModelContainer`, `ModelContext`. Avoids Core Data boilerplate while staying on the same SQLite backend. |
| In-memory ring buffer (custom) | Swift stdlib | Real-time 100Hz buffer (last N seconds) | SwiftData `ModelContext.insert` is not safe at 100Hz -- each insert goes through the ORM layer. Ring buffer holds ~5-10 seconds of raw samples in-memory; periodic flush (every 1-2 seconds or at run segment boundary) batches writes to SwiftData. |
| SwiftData background ModelContext | iOS 17+ | Async batch flush | Use `ModelContext(container)` off `@MainActor` inside a detached `Task` for flush operations. This keeps the main context clean and prevents UI hitches during persistence. |

**Confidence:** MEDIUM -- SwiftData performance characteristics at high write frequency are based on WWDC23 guidance and community reports; specific throughput numbers are unverified in this session. The ring-buffer-flush pattern is the established approach for high-frequency sensor apps on any ORM.

**SwiftData write pattern for telemetry:**
```swift
// In a detached Task, on background ModelContext:
let context = ModelContext(modelContainer)
for sample in ringBuffer.drain() {
    context.insert(sample)
}
try context.save()
```

**Known SwiftData limitation (MEDIUM confidence):** `@Query` in SwiftUI re-fetches on every context save. For the post-run analysis view, fetch via `FetchDescriptor` in a Task rather than `@Query` to avoid binding the UI to 100Hz save cycles.

**What NOT to use:**
- Core Data directly -- SwiftData is the modern layer; Core Data XML store is irrelevant here
- SQLite directly (GRDB, etc.) -- SwiftData is sufficient for this data volume; raw SQLite adds complexity without benefit at skiing-session scale (a full ski day is ~50k-200k samples, well within SQLite/SwiftData comfort zone)
- UserDefaults for any telemetry -- not appropriate for structured time-series
- CloudKit sync (SwiftData + CloudKit) in v1 -- adds schema constraints (no optionals on relationships, etc.) and sync complexity; defer to v2

---

### Background Execution

| Technology | Version / Target | Purpose | Why |
|------------|-----------------|---------|-----|
| HealthKit / HKWorkoutSession | iOS 17+ on iPhone (iPhone support added iOS 17) | Background CPU budget during active ski run | `HKWorkoutSession` on iPhone grants the app an active workout background mode, allowing continuous sensor collection when the screen locks. This is the correct mechanism -- not background fetch, not location background mode. |
| HKWorkoutBuilder | iOS 17+ | Attach HealthKit workout data to session | Paired with `HKWorkoutSession` to record workout events and heart rate if available. Provides legitimate HealthKit integration path for future watch pairing. |
| BackgroundTasks framework | iOS 13+ | Deferred analytics processing | `BGProcessingTaskRequest` for post-run heavy computation (e.g., full-run FFT, segment classification) when plugged in. Not needed for real-time capture. |

**Confidence:** MEDIUM-HIGH -- `HKWorkoutSession` on iPhone is documented as of iOS 17. The specific CPU budget granted and exact behavior under iOS 18 thermal conditions on A18 Pro is based on training data; verify against Apple's background execution documentation before shipping.

**Critical note on HKWorkoutSession entitlement:** The app requires `com.apple.developer.healthkit` and `com.apple.developer.healthkit.background-delivery` entitlements. The `HKWorkoutSession` on iPhone also requires `NSHealthUpdateUsageDescription` and `NSHealthShareUsageDescription` in Info.plist. Without the entitlement, session start will fail silently.

**What NOT to use:**
- `CLLocationManager` background mode as the sole background mechanism -- location background mode works but consumes significant battery and requires "Always" location permission, creating a worse user experience and App Store review friction
- `UIApplication.beginBackgroundTask` -- 30-second limit, not viable for multi-hour ski days
- Audio background mode (silent audio hack) -- Apple rejects apps abusing this for non-audio use

---

### Location / GPS

| Technology | Version / Target | Purpose | Why |
|------------|-----------------|---------|-----|
| CoreLocation / CLLocationManager | iOS 18+ | GPS track, speed, altitude | `desiredAccuracy = kCLLocationAccuracyBest` during active run. `distanceFilter = kCLDistanceFilterNone` to capture all GPS updates. Speed from `CLLocation.speed` (GPS Doppler), altitude from `CLLocation.altitude`. |
| CLLocation.speed | iOS 18+ | Real-time speed display | Doppler-derived speed from GPS. More accurate than position-delta speed at low update rates. Accurate to ±0.5 km/h under good sky view. |

**Confidence:** HIGH -- CoreLocation GPS is stable and well-understood.

**What NOT to use:**
- MapKit overlays in real-time during skiing -- battery and CPU cost; defer map rendering to post-run analysis
- `CLLocationManager` as the primary background execution anchor (see above under Background Execution)
- Barometer (`CMAltimeter`) as the primary altitude source -- use GPS altitude, supplemented by `CMAltimeter.relativeAltitude` for relative elevation gain between checkpoints (barometric is more precise for relative changes but drifts absolutely)

---

### UI Framework

| Technology | Version / Target | Purpose | Why |
|------------|-----------------|---------|-----|
| SwiftUI 6 | iOS 18+ | All UI | Mandated by project. `Canvas` for the scrolling waveform (direct drawing API, avoids view recycling overhead at 100Hz). `TimelineView` for animation-driven updates tied to display refresh. |
| Swift Charts | iOS 16+ | Post-run graphed analysis | First-party charting. `LineMark`, `AreaMark` for carve-pressure time series. `RuleMark` for segment boundaries. No external charting library needed. |
| TimelineView + Canvas | iOS 15+ | Live waveform rendering | `TimelineView(.animation)` drives redraws at ProMotion rates (up to 120Hz on iPhone 16 Pro). `Canvas` inside renders the ring buffer directly without creating SwiftUI view nodes per sample. |
| Material / ultraThinMaterial | iOS 15+ | Frosted glass metric cards | `ZStack` with `.background(.ultraThinMaterial)` on metric cards over the waveform. Consistent with Arctic Dark aesthetic. |

**Confidence:** HIGH -- All of these are stable, shipping APIs.

**What NOT to use:**
- UIKit for any new views -- SwiftUI is the mandate; UIKit interop (`UIViewRepresentable`) only for chart types not available in Swift Charts
- Third-party charting (Charts.js bridged, etc.) -- Swift Charts covers all needed chart types
- `List` or `ScrollView` for the live waveform -- `Canvas` is the right tool for arbitrary real-time drawing

---

### Activity Classification

| Technology | Version / Target | Purpose | Why |
|------------|-----------------|---------|-----|
| CoreMotion CMMotionActivityManager | iOS 7+ | Coarse activity detection (stationary/walking) | `CMMotionActivityManager` gives stationary/walking/automotive/cycling classification. "Automotive" fires during chairlift (gondola movement pattern). Use as a gating signal. |
| Custom classifier (rule-based) | Custom Swift logic | Skiing vs. chairlift discrimination | Combine CMMotionActivityManager hints with: (1) vertical speed from GPS (descending = skiing, ascending = chairlift), (2) g-force magnitude variance (skiing has high-frequency oscillation, chairlift is smooth). A simple threshold-based state machine is sufficient for v1; no CoreML needed. |
| CoreML (deferred) | iOS 12+ | v2: learned activity model | Train on labelled IMU sequences from v1 telemetry. Defer to v2 when ground-truth data exists. |

**Confidence:** MEDIUM -- The rule-based classifier approach is validated by the project's own context (GPS vertical speed + g-force variance). CMMotionActivityManager's "automotive" classification for chairlifts is a reasonable heuristic but not Apple-documented behavior for this use case; flag for on-mountain validation.

---

### Testing

| Technology | Version / Target | Purpose | Why |
|------------|-----------------|---------|-----|
| Swift Testing (`import Testing`) | iOS 17+, Swift 5.9+ | All sensor fusion and signal processing tests | Mandated by CLAUDE.md. `@Test`, `#expect`, `#require` macros. Parameterized tests with `@Test(arguments:)` for filter coefficient validation across Fs values. |
| XCTest | Existing only | Legacy UI tests only | Do not write new XCTest-based tests. Swift Testing is the target. |

**Confidence:** HIGH -- Swift Testing is the project mandate and is the modern replacement for XCTest.

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| Persistence | SwiftData | GRDB (SQLite wrapper) | SwiftData is first-party, Swift-native, and sufficient at skiing-session data volumes. GRDB offers better raw write throughput but adds a dependency. |
| Persistence | SwiftData | Core Data directly | SwiftData is the modern API over the same backend. Core Data boilerplate is unnecessary. |
| Signal processing | Accelerate/vDSP | Surge (Swift numerics lib) | Surge is a community wrapper over Accelerate; adds a dependency without capability gain. Use Accelerate directly. |
| Signal processing | Accelerate/vDSP | CoreML inference | Overkill for fixed-coefficient IIR filter. CoreML adds model management, latency, and unnecessary complexity. |
| Background execution | HKWorkoutSession | CLLocationManager (Always) | Requires "Always" location permission, worse UX, higher battery drain. HKWorkoutSession provides legitimate workout CPU budget. |
| Background execution | HKWorkoutSession | Audio background (silent) | App Store rejection risk. Against Apple guidelines. |
| UI waveform | Canvas + TimelineView | Metal / SpriteKit | Significant complexity increase. Canvas is sufficient at 120Hz for a 1D waveform display. |
| Activity classification | Rule-based state machine | CoreML classifier | No training data exists yet. Rule-based is correct for v1; revisit in v2 with labelled data. |
| Charts | Swift Charts | DGCharts (Charts library) | Swift Charts covers all needed types (line, area, rule marks). No external dependency needed. |
| Concurrency | AsyncStream + Actor | Combine | Combine is legacy pattern for Swift 7. AsyncStream integrates cleanly with structured concurrency and strict concurrency checking. |

---

## Dependency Policy

**Zero third-party dependencies for v1.** Every capability identified above is available through Apple first-party frameworks (CoreMotion, Accelerate, SwiftData, HealthKit, CoreLocation, Swift Charts, SwiftUI). This is intentional:

- No SPM dependency graph to audit or update
- No App Store review risk from third-party SDK behavior
- No ABI stability concerns
- Ski-day reliability: no upstream breakage possible

If a third-party library is considered in a future phase, it must clear the bar: "does something first-party cannot do at all, not just differently."

---

## iOS Deployment Target

**Minimum: iOS 18.0**

Rationale:
- `HKWorkoutSession` on iPhone requires iOS 17+; iOS 18 gives the full Swift 6 runtime and latest SwiftData history-tracking APIs
- SwiftData `ModelContext` background usage patterns are most stable on iOS 17.4+ (early SwiftData had persistence bugs fixed in point releases)
- `@Observable` requires iOS 17+
- iPhone 16 Pro ships with iOS 18; no user will be on iOS 17 in this context
- Swift 7 / strict concurrency complete mode requires Xcode 16+ toolchain targeting iOS 18 SDK

**No iOS 17 backcompat required.** ArcticEdge targets iPhone 16 Pro exclusively per PROJECT.md.

---

## Installation

No third-party packages. All frameworks are system-provided.

Xcode project configuration required:

```
Entitlements:
  com.apple.developer.healthkit = true
  com.apple.developer.healthkit.background-delivery = true

Info.plist keys:
  NSHealthUpdateUsageDescription
  NSHealthShareUsageDescription
  NSLocationWhenInUseUsageDescription
  NSMotionUsageDescription

Build Settings:
  SWIFT_STRICT_CONCURRENCY = complete
  IPHONEOS_DEPLOYMENT_TARGET = 18.0
  SWIFT_VERSION = 6.0
```

---

## Confidence Assessment

| Area | Confidence | Basis |
|------|------------|-------|
| CoreMotion 100Hz capability | HIGH | Well-documented Apple behavior, stable since iPhone 4S |
| AsyncStream bridge pattern | HIGH | Standard Swift concurrency pattern, well-established |
| Accelerate/vDSP for IIR filter | HIGH | First-party, documented, no alternatives |
| SwiftData for telemetry persistence | MEDIUM | Write throughput at high frequency not benchmarked in this session; ring-buffer flush pattern mitigates |
| HKWorkoutSession on iPhone background | MEDIUM-HIGH | iPhone support confirmed iOS 17+; exact A18 Pro thermal/CPU budget behavior unverified in session |
| CMMotionActivityManager for chairlift | MEDIUM | "Automotive" heuristic for chairlifts is logical but not Apple-documented for this case |
| Swift Charts for post-run analysis | HIGH | Stable API, covers all needed chart types |
| Rule-based activity classifier | MEDIUM | Requires on-mountain validation of threshold values |

---

## Sources

- Apple PROJECT.md decisions (authoritative for this project's constraints)
- WWDC23 "Meet SwiftData" session content (confirmed via WebFetch during research)
- Apple CLAUDE.md constraints (Swift 7, strict concurrency, SwiftUI 6 mandate)
- Training data: CoreMotion, HealthKit, Accelerate frameworks through August 2025
- NOTE: apple.developer.com documentation pages returned JavaScript-only content during this research session; confidence on API details relies on training data cross-checked against project context. Verify HKWorkoutSession entitlements and SwiftData background context behavior against current Apple documentation before implementation.
