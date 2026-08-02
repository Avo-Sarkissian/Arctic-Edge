# Research Summary

**Project:** ArcticEdge
**Synthesized:** 2026-03-08
**Synthesized by:** gsd-research-synthesizer

---

## Executive Summary

ArcticEdge is a high-performance iOS skiing telemetry app targeting iPhone 16 Pro, with a clear and defensible market gap: no existing competitor delivers real-time IMU carving dynamics (pitch, roll, g-force waveform) without additional hardware. The product's core identity is a 100Hz CoreMotion sensor pipeline that drives a live scrolling carve-pressure waveform rendered at ProMotion 120Hz — a combination that places it categorically above GPS-only apps like Slopes and SkiTracks, and positions it as the software-only alternative to Carv's $200+ hardware insoles.

The recommended architecture is a layered, actor-isolated pipeline: CoreMotion feeds a `MotionManager` actor that applies a high-pass biquad filter, writes to an in-memory ring buffer, and fans out via `AsyncStream` to both the live UI and the activity classifier. Persistence is a background side-effect using SwiftData batched writes, never inline at 100Hz. HealthKit's `HKWorkoutSession` is the mandatory CPU budget gate for background execution — the entire product is non-functional in pocketed-phone conditions without it. The technology stack is entirely first-party Apple frameworks with zero third-party dependencies, which is both a deliberate choice and a constraint that happens to be fully sufficient.

The most significant risks are not in the happy path but in the integration seams: Swift strict concurrency violations at the CoreMotion callback boundary, actor reentrancy data loss in the ring buffer flush cycle, SwiftData main-thread autosave under high write frequency, and silent background termination without data recovery. All four are documented, well-understood, and have concrete mitigations — but each will be encountered in Phase 1 and must be resolved before any feature work can proceed reliably. The activity classifier and filter cutoff values carry the highest empirical uncertainty and require on-mountain validation data before the results can be trusted.

---

## Key Findings

### From STACK.md

**Core technologies:**

| Technology | Rationale |
|------------|-----------|
| CoreMotion / CMDeviceMotion at 100Hz | Only Apple-first-party path to fused IMU data; iPhone 16 Pro A18 Pro handles 100Hz comfortably |
| AsyncStream + Actor (Swift 7) | Bridges CoreMotion callbacks into structured concurrency without Combine; mandatory for strict concurrency compliance |
| Accelerate / vDSP biquad filter | Zero-dependency SIMD-accelerated DSP; `vDSP_biquad` implements IIR filters with native throughput |
| SwiftData with ring-buffer flush pattern | First-party ORM on SQLite; NOT safe at per-frame insert rate; batched flush every 100 frames is the required pattern |
| HKWorkoutSession on iPhone (iOS 17+) | The only legitimate background CPU budget mechanism; must be started before CMMotionManager |
| SwiftUI 6 / Canvas + TimelineView | Canvas renders the live waveform without per-sample view nodes; TimelineView drives ProMotion redraws |
| Swift Charts | Covers all post-run chart types (line, area, rule marks); no external charting library needed |
| CMMotionActivityManager + rule-based classifier | Coarse activity gating plus GPS vertical speed + g-force variance for skiing vs. chairlift discrimination |

**Critical version requirement:** iOS 18.0 minimum. `HKWorkoutSession` on iPhone requires iOS 17+; Swift 7 / strict concurrency complete mode requires Xcode 16+ / iOS 18 SDK; `@Observable` requires iOS 17+.

**Dependency policy:** Zero third-party dependencies for v1. Every identified capability is available through Apple first-party frameworks.

**Confidence:** HIGH on CoreMotion, AsyncStream, Accelerate, Swift Charts, SwiftUI. MEDIUM on SwiftData write throughput (pattern is validated; exact numbers unverified). MEDIUM-HIGH on HKWorkoutSession background CPU budget specifics on A18 Pro.

---

### From FEATURES.md

**Table stakes (must ship in v1):**
- Background sensor capture at 100Hz (app is non-functional without this)
- Automatic run detection — skiing vs. chairlift (missing = users leave on day one)
- Per-run stats: top speed, average speed, vertical drop, duration, distance
- Session-level aggregates: total vertical, total runs, total time skiing vs. riding
- Speed over time graph (post-run)
- Persistent run history, browsable by day
- Battery efficiency for 4-8 hour ski days
- Altitude / vertical tracking (barometric altimeter for relative, GPS for absolute)
- Mountain / resort identification (reverse geocode)

**Differentiators (v1 core identity):**
- 100Hz IMU live scrolling carve-pressure waveform — the product's identity; no competitor has this from iPhone IMU alone
- Live telemetry dashboard: pitch, roll, g-force with frosted glass metric cards alongside the waveform
- Per-run segmented waveform replay (post-run "video replay for skiers without a camera")
- Thermal-aware sensor throttling (100Hz -> 50Hz -> 25Hz graceful degradation)

**Deferred to v2+:**
- Carving quality score (requires real-world data calibration; scoring function not yet validated)
- Edge engagement classification — carve vs. skid vs. mixed (needs a trained or well-heuristic-validated classifier)
- Turn count and turn frequency analysis (peak detection on noisy 100Hz signal; engineering research problem)
- Slope gradient estimation per segment
- Apple Watch standalone app

**Anti-features (explicitly excluded):**
- Social sharing / leaderboards (Slopes and Strava already own this; scope dilution)
- Real-time audio coaching (requires validated classifier; false coaching worse than none)
- Trail / piste mapping overlays (licensing burden, GPS accuracy ~5m insufficient for trail attribution)
- Video recording or overlay (thermal + battery problem)
- Weather integration, subscription monetization, mountain resort database

**Feature dependency critical path:**
Background capture -> IMU stream -> filter -> live waveform -> waveform storage -> post-run replay / turn analysis / carving score. Everything depends on the motion engine being correct first.

---

### From ARCHITECTURE.md

**Major components and responsibilities:**

| Component | Role |
|-----------|------|
| `MotionManager` (actor) | CoreMotion ingestion, high-pass filter, stream emission via AsyncStream |
| `RingBuffer` (actor) | Fixed-capacity in-memory storage (~1000 frames = 10s at 100Hz, ~200KB) |
| `PersistenceService` (actor) | SwiftData batched writes on background ModelContext |
| `StreamBroadcaster` (actor) | Fan-out single CMMotionManager stream to LiveViewModel + ActivityClassifier |
| `ActivityClassifier` (actor) | Classify skiing vs. chairlift from windowed frames; emits ActivitySegment events |
| `WorkoutSessionManager` (class, HealthKit delegate) | HKWorkoutSession lifecycle; provides background CPU grant |
| `SessionManager` (@Observable @MainActor) | Run lifecycle, segment bookkeeping, RunRecord persistence |
| `LiveViewModel` (@Observable @MainActor) | Bridges pipeline to live UI |
| `PostRunViewModel` (@Observable @MainActor) | Bridges SwiftData to analysis UI |

**Key patterns to follow:**
1. Actor as sensor boundary — CMMotionManager is owned exclusively by MotionManager actor; all output exits via AsyncStream
2. Ring buffer as fixed-capacity actor — O(1) `append`, synchronous `drain()` with no internal awaits (critical for reentrancy safety)
3. AsyncStream fan-out via StreamBroadcaster — prevents multiple CMMotionManager start calls that silently replace handlers
4. SwiftData dual-context — background context for writes (PersistenceService actor), main context for reads (ViewModels only)
5. HKWorkoutSession as CPU budget gate — MotionManager.start() must only be called after session state is `.running`

**Suggested build order (dependency-driven):**
FilteredFrame struct + filter -> RingBuffer -> MotionManager -> StreamBroadcaster -> PersistenceService -> WorkoutSessionManager -> ActivityClassifier -> SessionManager -> LiveViewModel -> LiveTelemetryView -> PostRunViewModel -> PostRunAnalysisView

Three natural phase gates emerge: **Motion Engine** (steps 1-4), **Session Layer** (steps 5-8), **UI Layer** (steps 9-12).

---

### From PITFALLS.md

**Top 5 pitfalls with prevention strategies:**

**Pitfall 1 — CMMotionManager callback threading breaks strict concurrency (CRITICAL)**
CMDeviceMotion is an Objective-C reference type; it is not Sendable. Under `SWIFT_STRICT_CONCURRENCY = complete`, passing it across actor boundaries produces build-breaking Sendable errors. Fix: extract only primitive Double values immediately in the callback, wrap in a Sendable struct, bridge via `Task { await actor.receive(sample) }`. Never hold a reference to CMDeviceMotion across an await boundary.

**Pitfall 2 — Actor reentrancy corrupts ring buffer during flush (CRITICAL)**
Between two `await` calls in a flush cycle, new samples arrive and get lost. Fix: make `drain()` a single synchronous, transactional method — no awaits inside. `let chunk = buffer; buffer = []; return chunk` atomically.

**Pitfall 3 — SwiftData autosave blocks the main thread at 100Hz (CRITICAL)**
SwiftData's main context autosaves on UI events. At 120Hz ProMotion, this fires multiple times per second with high-frequency inserts, causing 10-50ms main thread hangs. Fix: create a detached background ModelContext (`autosaveEnabled = false`), accumulate in ring buffer, flush in batches of 200-500 samples.

**Pitfall 4 — HKWorkoutSession termination does not resurrect a killed app (CRITICAL)**
If iOS kills the app (memory pressure, crash) during a run, the workout session becomes orphaned with no auto-restore. Data in the ring buffer is lost. Fix: aggressive flush on `applicationDidEnterBackground`, synchronous emergency flush in `willTerminate`, "run in progress" sentinel in UserDefaults, orphan session check on launch.

**Pitfall 6 — Activity detection confuses chairlift vibration for skiing (HIGH)**
Fixed-grip chairs sway and vibrate with patterns that trigger energy-based "skiing" thresholds. Fix: fuse GPS velocity (chairlifts: 4-7 m/s; skiing: 5-30+ m/s) as a strong discriminator; add hysteresis (require N consecutive seconds before state transition); look for periodic low-frequency oscillation signature of cable sway.

**Other notable pitfalls:**
- Pitfall 5: Filter cutoffs chosen without on-snow data — implement as runtime-configurable constants, log raw + filtered data for first beta runs
- Pitfall 7: Thermal throttling silently reduces CoreMotion update rate — always timestamp samples; monitor `ProcessInfo.thermalState`
- Pitfall 8: Cold weather reduces effective battery capacity 20-40% — design for 65% capacity; implement Power Saver mode
- Pitfall 9: CMBatchedSensorManager is NOT a drop-in replacement — it delivers 1-second batches; useless for live dashboard
- Pitfall 12: Missing SwiftData index on timestamp causes slow post-run queries — add `#Index` at model definition time
- Pitfall 13: AsyncStream backpressure overflow at 100Hz — use `.unbounded` buffer; keep consumer synchronous

---

## Implications for Roadmap

Research strongly suggests a 4-phase structure, driven by hard technical dependencies. Each phase produces a shippable gate before the next begins.

### Suggested Phase Structure

**Phase 1 — Motion Engine & Session Foundation**

Rationale: Everything else depends on this being correct. The critical pitfalls (Pitfalls 1-3, 9, 13) all live here. Until the sensor pipeline is provably correct under strict concurrency with no data loss, no feature work is meaningful.

Delivers:
- `FilteredFrame` struct + high-pass biquad filter (Accelerate/vDSP)
- `MotionManager` actor (CoreMotion ingestion, Sendable boundary, stream emission)
- `RingBuffer` actor (fixed-capacity, transactional drain)
- `StreamBroadcaster` actor (fan-out)
- `WorkoutSessionManager` (HKWorkoutSession lifecycle, background CPU grant)
- `PersistenceService` actor (SwiftData background context, batched flush)
- SwiftData schema: `FrameRecord` + `RunRecord` with `#Index` on timestamp and runID

Must avoid: Pitfalls 1, 2, 3, 9, 13 (all critical or build-breaking in Phase 1)
Research flag: STANDARD PATTERNS — no additional phase research needed. Architecture is well-documented.

---

**Phase 2 — Activity Detection & Session Management**

Rationale: Without reliable skiing/chairlift discrimination, all per-run stats and session aggregates are meaningless. This is the table-stakes feature users judge in their first session.

Delivers:
- `ActivityClassifier` actor (rule-based state machine: GPS velocity + g-force variance + chairlift vibration signature)
- `SessionManager` (run lifecycle, segment boundaries, RunRecord finalization)
- Background termination resilience (Pitfall 4: UserDefaults sentinel, emergency flush, orphan recovery)
- HKWorkoutSession pause/resume gap handling (Pitfall 10)
- Thermal-aware sensor throttling (Pitfall 7: ProcessInfo.thermalState observer)
- GPS integration (CLLocationManager, speed, altitude)

Must avoid: Pitfalls 4, 5, 6, 7, 10, 14
Research flag: NEEDS PHASE RESEARCH — chairlift classification edge cases (gondola, T-bar, magic carpet) are highly empirical. The classifier heuristics will require iteration once real skiing data is available. Filter cutoff calibration also lives here.

---

**Phase 3 — Live Telemetry UI & Post-Run Analysis**

Rationale: The visual identity of ArcticEdge — the live scrolling waveform and frosted glass metric cards — builds on Phase 1 and Phase 2 being stable. This is also where the "table stakes" per-run stats and run history land in the user-facing product.

Delivers:
- `LiveViewModel` + `LiveTelemetryView` (Canvas + TimelineView waveform, 120Hz ProMotion)
- Frosted glass metric cards (pitch, roll, g-force, speed) using `ultraThinMaterial`
- `PostRunViewModel` + `PostRunAnalysisView` (Swift Charts: speed, g-force, carve-pressure time series)
- Per-run stats summary (top speed, average speed, vertical, duration, distance)
- Session-level aggregate stats
- Run history browser (SwiftData FetchDescriptor, paginated)
- Resort / mountain identification (CoreLocation reverse geocode)
- Segmented waveform replay (time-aligned IMU + GPS, click-to-inspect)

Must avoid: Pitfall 11 (filter warm-up transient at run start), Pitfall 12 (missing index — already addressed in Phase 1 schema), per-frame @Query re-fetch antipattern
Research flag: STANDARD PATTERNS — Swift Charts, Canvas, TimelineView are all well-documented.

---

**Phase 4 — Hardening, Power Management & Beta Validation**

Rationale: On-mountain conditions (cold battery, thermal pressure, varied chairlift types, filter calibration) can only be validated with real-world data. This phase exists to close the gap between lab correctness and mountain reliability.

Delivers:
- Power Saver Recording mode (60Hz UI, GPS off, motion co-processor only) triggered at < 30% battery
- Cold-weather battery design validation (design for 65% effective capacity per Pitfall 8)
- Filter coefficient calibration from beta raw + filtered data logs
- Activity classifier iteration from labeled beta run data
- MetricKit / Xcode Organizer battery profiling from field beta testers
- Debug overlay (sample rate, thermal state, GPS accuracy, classifier state) for QA

Must avoid: Pitfall 8 (cold battery), Pitfall 5 (filter cutoffs), Pitfall 6 (classifier false positives)
Research flag: NEEDS PHASE RESEARCH — thermal behavior of A18 Pro at sustained 100Hz under field conditions is not publicly documented. Chairlift edge cases require empirical on-mountain data.

---

## Research Flags

| Phase | Needs `/gsd:research-phase`? | Reason |
|-------|------------------------------|--------|
| Phase 1 — Motion Engine | No | Architecture is well-documented; Swift concurrency + CoreMotion + SwiftData patterns are established |
| Phase 2 — Activity Detection | Yes | Chairlift classification edge cases require empirical data; heuristic thresholds cannot be derived from first principles alone |
| Phase 3 — Live UI & Post-Run | No | Swift Charts, Canvas, TimelineView are stable APIs; standard patterns apply |
| Phase 4 — Hardening & Beta | Yes | Thermal behavior of A18 Pro at 100Hz under field conditions; cold-weather battery model; filter calibration need real-world data |

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack — CoreMotion, Accelerate, SwiftUI, Swift Charts | HIGH | Well-documented, stable APIs; no significant uncertainty |
| Stack — SwiftData write throughput | MEDIUM | Ring-buffer flush pattern is validated; specific throughput numbers not benchmarked in this session |
| Stack — HKWorkoutSession background budget on A18 Pro | MEDIUM-HIGH | iPhone support confirmed iOS 17+; exact thermal/CPU behavior under A18 Pro field conditions unverified |
| Features — Table stakes and differentiators | HIGH | Competitive landscape analysis from training data is consistent; gap is real and specific |
| Features — v2 deferrals | HIGH | Rationale is solid; carving quality score and turn segmentation both carry empirical research risk that justifies deferral |
| Architecture — Layer design, actor patterns | HIGH | Established Swift concurrency patterns; phase build order is dependency-correct |
| Architecture — StreamBroadcaster fan-out | HIGH | Standard pattern; well-understood |
| Pitfalls — Concurrency violations, reentrancy, SwiftData | HIGH | All backed by specific WWDC sessions with documented behavior |
| Pitfalls — CMMotionActivityManager for chairlift | MEDIUM | "Automotive" mode for chairlifts is a logical heuristic, not Apple-documented behavior for this use case; needs on-mountain validation |
| Pitfalls — Filter cutoff values | MEDIUM-LOW | Biomechanically motivated but not empirically validated; treat as calibration targets, not ground truth |
| Pitfalls — Cold weather battery numbers | MEDIUM | Well-established lithium-ion behavior; specific percentage ranges are representative, not device-specific measurements |

**Overall confidence: MEDIUM-HIGH**

The architecture and technology choices are well-grounded and carry HIGH confidence. The empirical risks (classifier thresholds, filter cutoffs, thermal behavior in field conditions) are correctly identified and deferred to validation phases rather than treated as solved. No blocking unknowns exist for beginning Phase 1 implementation.

---

## Gaps to Address

1. **HKWorkoutSession entitlement verification** — developer.apple.com was JavaScript-gated during research. Verify exact entitlement string and Info.plist key requirements against current Apple documentation before submitting the first TestFlight build.

2. **CMMotionActivityManager "automotive" classification for chairlifts** — this heuristic is logical but not Apple-documented behavior. Build an explicit test harness (gondola, fixed-grip chair, T-bar, magic carpet) before relying on it in production.

3. **Filter cutoff empirical calibration** — implement filter coefficients as runtime-configurable from day one. The 2Hz / 0.5Hz values from PROJECT.md are starting hypotheses; plan a structured beta labeling pass before treating them as settled.

4. **SwiftData background ModelContext thread-safety edge cases** — SwiftData early point releases (iOS 17.0-17.3) had persistence bugs fixed in iOS 17.4+. Target iOS 18 mitigates this, but verify background context behavior against current SwiftData release notes.

5. **Carving quality score algorithm** — intentionally deferred to v2 but needs tracking: no established algorithm exists for this from iPhone IMU alone. Plan a research spike in parallel with Phase 3 to scope the problem before committing to a Phase 4 or v2 timeline.

---

## Sources

Aggregated from research files:

- Apple CLAUDE.md project constraints (Swift 7, strict concurrency, SwiftUI 6 mandate) — HIGH confidence
- Training data: CoreMotion, HealthKit, Accelerate, SwiftData, CoreLocation frameworks through August 2025
- WWDC23 "Meet SwiftData" (session 10187) — ModelContext autosave behavior
- WWDC23 "Dive Deeper into SwiftData" (session 10196) — background ModelContext pattern
- WWDC24 "What's new in SwiftData" (session 10137) — #Index macro
- WWDC23 "What's new in Core Motion" (session 10179) — CMBatchedSensorManager batch latency, HKWorkoutSession requirement
- WWDC24 "Migrate your app to Swift 6" (session 10169) — Sendable violations, delegate callback isolation
- WWDC22 "Beyond the Basics of Structured Concurrency" (session 110351) — actor reentrancy
- WWDC23 "Build a multi-device workout app" (session 10023) — HKWorkoutSession session continuity limits
- Swift Evolution SE-0314: AsyncStream — HIGH confidence
- Apple Energy Efficiency Guide for iOS Apps — GPS battery drain
- Competitive landscape: Slopes, SkiTracks, Carv, Alpine Replay — MEDIUM confidence (training data, cutoff August 2025, not externally verified in this session)
- NOTE: developer.apple.com required JavaScript and was not accessible during research sessions. API details rely on training data cross-checked against project context. Verify entitlements and SwiftData background context behavior against current Apple documentation before shipping.
