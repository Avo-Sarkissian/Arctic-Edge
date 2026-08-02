# Phase 3: Live Telemetry & Post-Run Analysis - Research

**Researched:** 2026-03-10
**Domain:** SwiftUI Canvas+TimelineView (120fps waveform), Swift Charts (interactive time-series), SwiftData schema migration + pagination, CoreLocation reverse geocoding, TabView navigation
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Navigation model**
- Tab bar with two tabs: Today (ContentView + live telemetry) and History (run browser)
- Live Telemetry appears automatically when the classifier transitions to `.skiing` — no user tap
- Live view presents over or within the Today tab context; dismisses when run ends
- History is a persistent dedicated tab — always one tap away

**Live waveform layout**
- Waveform is the hero: takes ~60-70% of screen height (full-bleed feel)
- Metric cards (pitch, roll, g-force, GPS speed) float as HUD overlay on lower portion of waveform
- Right-side fixed cursor line marks "now" — waveform scrolls left into it (oscilloscope/EKG style)
- Time window: ~10 seconds visible at once (matches existing ring buffer depth)
- Arctic Dark: waveform line on dark background, metric card values in white/blue against ultraThinMaterial

**Post-run trigger + layout**
- Post-run analysis sheet auto-presents the moment a run ends (classifier fires `.skiing` to `.chairlift` or `.idle`)
- Screen hierarchy: stats summary at top (top speed, avg speed, vertical drop, duration, distance), time-series charts below
- Segmented waveform replay (ANLYS-04): scrubber interaction — tap or drag on the chart to show metric snapshot at that timestamp
- Session aggregates (ANLYS-03) appear in the post-run view alongside per-run stats
- Post-run view is also the destination when tapping a run in history (same PostRunAnalysisView)

**Run history browser**
- Compact rows: run number, top speed, vertical drop, duration
- Day headers: date + resort name (CoreLocation reverse geocode) + day totals (run count + total vertical)
- Text only — no per-run sparklines or visual bars
- Tapping a run navigates to PostRunAnalysisView

### Claude's Discretion
- Navigation transition from history row to PostRunAnalysisView (push vs sheet vs fullScreenCover)
- Waveform signal color (single accent color vs multi-signal coloring)
- Exact metric card sizing and position within the HUD overlay
- Loading skeleton / empty state design for history list
- How Live Telemetry view presents within the Today tab (fullScreenCover, NavigationStack push, or ZStack overlay)
- Chart type selection for post-run (Swift Charts LineMark for time-series; layout details)
- How RunRecord schema is extended to persist vertical drop and distance

### Deferred Ideas (OUT OF SCOPE)

None — discussion stayed within phase scope.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| LIVE-01 | Live Telemetry view renders scrolling carve-pressure waveform at 120Hz using Canvas + TimelineView | TimelineView(.animation) schedule fires every display refresh; Canvas draws without SwiftUI node overhead; combined pattern is the standard for ProMotion-native waveforms |
| LIVE-02 | Live Telemetry view overlays frosted glass metric cards (ultraThinMaterial) showing real-time pitch, roll, g-force, and GPS speed | StatCard from ContentView is directly reusable; metric values bridged from LiveViewModel via 10Hz HUD polling pattern already established in AppModel |
| LIVE-03 | Live Telemetry view remains fluid at 120fps without frame drops during active 100Hz data ingestion | Canvas+TimelineView avoids per-sample SwiftUI node creation; waveform data is a simple [Double] snapshot — no heavy computation in draw closure |
| ANLYS-01 | Post-Run Analysis view displays time-series charts (Swift Charts) for speed, g-force, and carve-pressure across the full run | Swift Charts LineMark is the correct primitive; data loaded via PersistenceService FetchDescriptor from FrameRecord |
| ANLYS-02 | Post-Run Analysis view shows per-run stats summary: top speed, average speed, vertical drop, run duration, distance | Stats computed from FrameRecord + RunRecord data on PostRunViewModel; topSpeed/avgSpeed/verticalDrop/distanceMeters require RunRecord schema extension |
| ANLYS-03 | Post-Run Analysis view shows session-level aggregates: total vertical, total run count, total time skiing vs riding | PersistenceService query for all RunRecords in current day; computed in PostRunViewModel |
| ANLYS-04 | Post-Run Analysis view provides segmented waveform replay — IMU data time-aligned with GPS speed, tappable to inspect any moment | chartXSelection modifier (iOS 17+) drives scrubber; RuleMark + annotation shows metric snapshot at selected timestamp |
| HIST-01 | Run history browser lists all runs grouped by day, paginated via SwiftData FetchDescriptor (lazy loading for long season history) | FetchDescriptor.fetchLimit + fetchOffset pattern; List with onAppear-triggered next-page fetch |
| HIST-02 | Each run entry shows date, mountain/resort name (CoreLocation reverse geocode), top speed, and total vertical | CLGeocoder.reverseGeocodeLocation wrapped with withCheckedThrowingContinuation; CLPlacemark.locality or .name as primary resort label |
</phase_requirements>

---

## Summary

Phase 3 adds three new views on top of a fully operational data pipeline: a Live Telemetry view (real-time carve-pressure waveform), a Post-Run Analysis view (time-series charts, stats, scrubber), and a Run History browser (paginated, day-grouped list). No new sensor capture logic is required — all live data flows from `StreamBroadcaster.makeStream()` and all historical data from SwiftData via `PersistenceService`.

The primary technical challenge is the 120fps waveform. The canonical solution is `TimelineView(.animation)` wrapping a `Canvas` — this fires on every display refresh without creating SwiftUI view nodes per data point. The `Canvas` draw closure receives a fresh `timeline.date` timestamp each frame; the `LiveViewModel` maintains a ring-buffer snapshot that the draw closure reads directly. This pattern is well-documented and actively used in production iOS apps for oscilloscope-style visualizations.

The secondary challenge is the RunRecord schema extension. `RunRecord` currently lacks `topSpeed`, `avgSpeed`, `verticalDrop`, and `distanceMeters`. These are all optional `Double` fields, which qualifies as a lightweight SwiftData migration — no custom migration stage is required. GPS speed must also be associated with frames; the cleanest approach is adding `gpsSpeed: Double?` to `FrameRecord` (optional, yielding nil for frames where no GPS fix arrived) so post-run charts can time-align IMU and GPS data without a separate `GPSRecord` table.

**Primary recommendation:** Build LiveViewModel and LiveTelemetryView in plan 03-01 using the Canvas+TimelineView pattern; build PostRunViewModel, PostRunAnalysisView, run history, and schema migration in plan 03-02. Wrap both in a TabView root change in ArcticEdgeApp.swift.

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| SwiftUI Canvas | iOS 15+ | GPU-accelerated imperative drawing | Bypasses the SwiftUI view tree per sample; required for 120fps waveforms |
| SwiftUI TimelineView | iOS 15+ | Frame-rate-driven redraw trigger | `.animation` schedule fires on every ProMotion display refresh automatically |
| Swift Charts | iOS 16+ | Declarative time-series charts | First-party; LineMark, chartXSelection, RuleMark all available; no third-party dependency |
| SwiftData FetchDescriptor | iOS 17+ | Paginated history queries | `fetchLimit`/`fetchOffset`; existing project dependency |
| CoreLocation CLGeocoder | iOS 5+ | Reverse geocode lat/long to resort name | Only first-party option; `reverseGeocodeLocation` wrapped in async/await |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| SwiftUI TabView | iOS 14+ | Two-tab root navigation | App root restructure in ArcticEdgeApp.swift |
| SwiftUI fullScreenCover | iOS 14+ | Live view auto-presentation | Covers Today tab without destroying it; dismisses on run end |
| SwiftUI NavigationStack | iOS 16+ | History detail push | History tab wraps in NavigationStack for run-detail push navigation |
| SwiftData VersionedSchema | iOS 17+ | Schema migration plan | Required when RunRecord gains new stored properties |
| Accelerate vDSP | iOS 13+ | Vertical drop calculation | Numerical integration of GPS speed over time; already in project |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Canvas+TimelineView | Metal / SpriteKit | Metal is correct for 3D; Canvas is the SwiftUI-native solution with zero third-party dependency; ProMotion works out of the box |
| Swift Charts | Charts third-party (Charts/DGCharts) | Project constraint: zero third-party dependencies for v1 |
| CLGeocoder | MapKit MKLocalSearch | CLGeocoder is simpler for a single coordinate-to-name reverse lookup; MKLocalSearch adds complexity without benefit |
| fullScreenCover for live view | ZStack conditional overlay | fullScreenCover is cleaner — preserves Today tab state, has system transition, and is explicitly dismissable via `@Environment(\.dismiss)` |
| NavigationStack push for history detail | sheet from history row | Push is correct for drill-down detail; sheet is for contextual overlays; PostRunAnalysisView is a detail destination |

**Installation:** No new dependencies. All APIs are first-party Apple frameworks already imported in the project.

---

## Architecture Patterns

### Recommended Project Structure

```
ArcticEdge/
├── Live/
│   ├── LiveViewModel.swift         # @Observable @MainActor; ring buffer snapshot + metric bridging
│   └── LiveTelemetryView.swift     # TimelineView + Canvas waveform + HUD metric overlay
├── PostRun/
│   ├── PostRunViewModel.swift      # @Observable @MainActor; loads FrameRecords + computes stats
│   └── PostRunAnalysisView.swift   # Stats summary + Swift Charts (LineMark) + chartXSelection scrubber
├── History/
│   ├── HistoryViewModel.swift      # @Observable @MainActor; paginated RunRecord list + geocode cache
│   └── RunHistoryView.swift        # NavigationStack + grouped List + day headers
├── Schema/
│   ├── RunRecord.swift             # Extended with topSpeed, avgSpeed, verticalDrop, distanceMeters
│   ├── FrameRecord.swift           # Extended with gpsSpeed: Double?
│   └── SchemaV2.swift              # VersionedSchema definitions for migration
ArcticEdgeApp.swift                 # WindowGroup wraps TabView (Today + History tabs)
```

### Pattern 1: Canvas + TimelineView Waveform

**What:** `TimelineView(.animation)` triggers a redraw on every display frame (up to 120Hz on ProMotion). The inner `Canvas` closure reads a snapshot array from `LiveViewModel` and draws a polyline — no SwiftUI view nodes per sample.

**When to use:** Any visualization that must update at display refresh rate with a data array.

**Example:**
```swift
// Source: WWDC21 "Add rich graphics to your SwiftUI app" + Hacking with Swift TimelineView tutorial
TimelineView(.animation) { timeline in
    Canvas { context, size in
        // LiveViewModel.waveformSnapshot is a [Double] captured at last broadcast
        let samples = liveViewModel.waveformSnapshot
        guard samples.count > 1 else { return }

        let xStep = size.width / CGFloat(samples.count - 1)
        let midY = size.height / 2
        let scale: CGFloat = size.height * 0.4

        var path = Path()
        path.move(to: CGPoint(x: 0, y: midY - CGFloat(samples[0]) * scale))
        for (i, sample) in samples.dropFirst().enumerated() {
            path.addLine(to: CGPoint(x: CGFloat(i + 1) * xStep,
                                     y: midY - CGFloat(sample) * scale))
        }
        context.stroke(path, with: .color(.cyan), lineWidth: 1.5)

        // Fixed cursor at right edge
        let cursorX = size.width - 2
        context.stroke(
            Path { p in p.move(to: CGPoint(x: cursorX, y: 0))
                         p.addLine(to: CGPoint(x: cursorX, y: size.height)) },
            with: .color(.white.opacity(0.35)),
            lineWidth: 1
        )
    }
}
```

**Key constraint:** The Canvas closure must complete in under 8.3ms for 120fps. With 1000 samples (10s at 100Hz), a single polyline draw is well within budget. Do NOT perform any sorting, filtering, or allocation inside the draw closure.

### Pattern 2: Swift Charts LineMark with chartXSelection Scrubber

**What:** `LineMark` plots time-series data. `chartXSelection(value:)` (iOS 17+) accepts a binding to the selected x-axis value and drives a `RuleMark` + `.annotation` for the metric snapshot display.

**When to use:** Post-run analysis charts with tap/drag-to-inspect interaction (ANLYS-04).

**Example:**
```swift
// Source: Swift with Majid "Mastering Charts in SwiftUI: Selection" (verified against iOS 17 docs)
Chart(frames, id: \.timestamp) { frame in
    LineMark(
        x: .value("Time", frame.timestamp),
        y: .value("Carve Pressure", frame.filteredAccelZ)
    )
    .foregroundStyle(Color.cyan)

    if let selected = selectedTimestamp {
        RuleMark(x: .value("Selected", selected))
            .foregroundStyle(.white.opacity(0.4))
            .annotation(position: .top) {
                MetricSnapshotView(frame: frameAt(selected))
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
    }
}
.chartXSelection(value: $selectedTimestamp)
.chartXAxis {
    AxisMarks(values: .automatic(desiredCount: 5)) { value in
        AxisGridLine().foregroundStyle(.white.opacity(0.1))
        AxisValueLabel().foregroundStyle(.white.opacity(0.5))
    }
}
```

### Pattern 3: LiveViewModel Bridging

**What:** `LiveViewModel` is an `@Observable @MainActor` class that subscribes to `StreamBroadcaster.makeStream()` and maintains a fixed-size `waveformSnapshot: [Double]` array for Canvas consumption. This is the same HUD polling pattern used by `AppModel`, adapted for 100Hz data rate.

**When to use:** Bridging actor-isolated sensor data to SwiftUI at a rate Canvas can consume.

**Example:**
```swift
// Source: AppModel.startHUDPolling() pattern, extended for 100Hz intake
@Observable
@MainActor
final class LiveViewModel {
    private(set) var waveformSnapshot: [Double] = []
    private(set) var pitch: Double = 0
    private(set) var roll: Double = 0
    private(set) var gForce: Double = 0
    private(set) var gpsSpeed: Double = -1

    private var streamTask: Task<Void, Never>?
    private let windowSize = 1000  // 10s at 100Hz

    func startConsuming(broadcaster: StreamBroadcaster) {
        let stream = await broadcaster.makeStream()
        streamTask = Task { @MainActor [weak self] in
            for await frame in stream {
                guard let self else { return }
                // Update waveform buffer
                waveformSnapshot.append(frame.filteredAccelZ)
                if waveformSnapshot.count > windowSize {
                    waveformSnapshot.removeFirst()
                }
                // Update HUD metrics
                pitch = frame.pitch
                roll = frame.roll
                gForce = hypot(frame.userAccelX, hypot(frame.userAccelY, frame.userAccelZ))
            }
        }
    }

    func stopConsuming() {
        streamTask?.cancel()
        streamTask = nil
        waveformSnapshot = []
    }
}
```

**Key: GPS speed is NOT in FilteredFrame.** GPS arrives on GPSManager's stream at a lower rate (~1Hz). `LiveViewModel` needs to either subscribe to a second GPS stream from `GPSManager.makeStream()` or piggyback on `AppModel.lastGPSSpeed` (already polled at 10Hz). The HUD cards update at 10Hz which is sufficient for a speed display.

### Pattern 4: SwiftData Pagination for History

**What:** `FetchDescriptor` with `fetchLimit` and `fetchOffset` fetches pages of `RunRecord` objects sorted by `startTimestamp` descending. The List triggers the next page fetch via `onAppear` on the last visible row.

**When to use:** HIST-01 — browsing a full season of runs without blocking the main thread.

**Example:**
```swift
// Source: Hacking with Swift SwiftData pagination example (verified pattern)
func fetchNextPage() async {
    let descriptor = FetchDescriptor<RunRecord>(
        sortBy: [SortDescriptor(\.startTimestamp, order: .reverse)]
    )
    descriptor.fetchOffset = loadedRuns.count
    descriptor.fetchLimit = 50

    // Fetch on @ModelActor (PersistenceService)
    let newRuns = try await persistenceService.fetchRunRecords(descriptor: descriptor)
    loadedRuns.append(contentsOf: newRuns)
}
```

### Pattern 5: Run End Signal to AppModel

**What:** `ActivityClassifier` transitions from `.skiing` to `.chairlift` or `.idle` inside `confirmChairliftTransition()`. Currently it only calls `persistence.finalizeRunRecord(...)`. Phase 3 needs to also signal `AppModel` so `PostRunAnalysisView` auto-presents. The cleanest mechanism is a closure callback on `ActivityClassifier` (matching the existing NSNotification pattern in AppModel for lifecycle), or adding a `@Observable`-compatible published `lastFinalizedRunID: UUID?` property to AppModel that the Today tab observes.

**Recommended approach:** Add `var lastFinalizedRunID: UUID?` to `AppModel`. The HUD polling loop (already running at 10Hz) reads `await classifier.currentRunID` and detects the transition to nil to capture the just-finalized run ID. This requires no protocol changes to `ActivityClassifier`.

### Pattern 6: Waveform Ring Buffer Snapshot

**What:** LiveViewModel holds a `[Double]` of `filteredAccelZ` values. Rather than reading from `RingBuffer` (which is a separate actor), it builds its own snapshot by appending each incoming frame from the broadcaster stream. This avoids actor hops inside the draw closure and is entirely `@MainActor` safe.

**Key:** The ring buffer in `MotionManager`/`RingBuffer` is for persistence batching. `LiveViewModel`'s array is purely for display.

### Anti-Patterns to Avoid

- **Calling `await` inside a Canvas draw closure:** Canvas closures are synchronous. All data must be pre-fetched into `@MainActor` state before the draw fires.
- **Creating per-sample SwiftUI views in the waveform:** One `ForEach` of 1000 `Rectangle` views will stall the render tree. Use Canvas exclusively.
- **Fetching FrameRecords for post-run on the main thread:** `PersistenceService` is a `@ModelActor`. All fetches must be `async` — initiate from a Task in PostRunViewModel, never synchronously block MainActor.
- **Passing RunRecord SwiftData model objects across actor boundaries:** `RunRecord` is not `Sendable`. Pass `PersistentIdentifier` or extract primitive values into a `Sendable` struct before crossing actor boundaries.
- **Geocoding on every list refresh:** Cache geocoded resort names in `HistoryViewModel` keyed by the run's coordinate, or persist the result in `RunRecord`. CLGeocoder has a rate limit (one request at a time; 50 requests/minute approximate guideline).
- **Blocking the main thread with schema migration:** SwiftData runs migrations at `ModelContainer` init time, which already happens in `AppModel.init()` using a `try!` pattern. A failed migration will crash — ensure optional-only additions and test migration on a copy of a v1 database.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| 120fps frame timing | Custom CADisplayLink wrapper | `TimelineView(.animation)` | TimelineView is already linked to ProMotion; CADisplayLink requires bridging to SwiftUI state, re-implements what TimelineView provides |
| Interactive chart scrubber | DragGesture + manual coordinate math | `chartXSelection(value:)` (iOS 17+) | Handles tap and drag, maps to chart axis values automatically, integrates with RuleMark |
| Chart x-axis date formatting | Custom DateFormatter in chart content | `AxisMarks(values:)` with `AxisValueLabel` | Built-in, adapts to locale |
| Reverse geocoding async bridge | Manual callback-to-async pattern | `CLGeocoder.reverseGeocodeLocation` with `withCheckedThrowingContinuation` | One-time ~10 line wrapper needed; already the canonical pattern per Apple docs |
| Schema migration SQL | Manual CoreData migration | `VersionedSchema` + `.lightweight` migration stage | SwiftData handles optional property additions automatically with lightweight migration |
| History list pagination | Manual offset tracking | `FetchDescriptor.fetchOffset` + `fetchLimit` | Built into SwiftData; no custom paging logic |

**Key insight:** The entire phase is "connecting existing Apple APIs to existing project infrastructure." Every new capability (waveform, charts, geocoding, pagination) has a first-party solution with minimal boilerplate. The complexity lies in wiring, not building.

---

## Common Pitfalls

### Pitfall 1: Canvas Draw Closure Capturing Mutable State Unsafely

**What goes wrong:** Canvas closure captures `liveViewModel.waveformSnapshot` — a mutable array on `@MainActor`. Under SWIFT_STRICT_CONCURRENCY = complete, the compiler may complain if the closure is considered non-isolated.

**Why it happens:** `Canvas { context, size in ... }` closures are `@Sendable` in some configurations.

**How to avoid:** Capture a local immutable copy before the Canvas call: `let samples = liveViewModel.waveformSnapshot`. Pass it in via `Canvas` environment or capture in the outer `TimelineView` closure where isolation is clear.

**Warning signs:** Compiler errors about `@MainActor`-isolated property access in a non-isolated context.

### Pitfall 2: Post-Run Sheet Presented Before PersistenceService Finishes Writing

**What goes wrong:** The run ends, `PostRunAnalysisView` presents, but the final batch of frames hasn't been flushed from `RingBuffer` to SwiftData yet. Charts appear truncated.

**Why it happens:** `confirmChairliftTransition()` fires `finalizeRunRecord(...)` but the periodic flush task hasn't run yet. The ring buffer may hold up to ~200 frames (~2 seconds of data).

**How to avoid:** `PostRunViewModel.loadData(runID:)` must trigger an `emergencyFlush` (or wait for the in-flight flush) before querying `FrameRecords`. The simplest pattern: `PostRunViewModel.load()` calls `persistenceService.emergencyFlush(ringBuffer:)` as its first step, then fetches.

**Warning signs:** Post-run chart ends 1-3 seconds before the displayed run duration.

### Pitfall 3: CLGeocoder Rate Limiting Stalls History List

**What goes wrong:** Geocoding every row in `onAppear` hits CLGeocoder's rate limit (~50/min); requests queue up and the list loads slowly or returns `kCLErrorGeocodeFoundNoResult`.

**Why it happens:** CLGeocoder only allows one in-flight request at a time per instance; issuing a second before the first completes throws.

**How to avoid:**
1. Cache geocoded resort names in memory in `HistoryViewModel` keyed by `runID`.
2. Better: Persist the geocoded name in `RunRecord.resortName: String?` the first time a run is geocoded (geocode once at run end via AppModel, store it).
3. Use a single shared `CLGeocoder` instance, not a new one per row.

**Warning signs:** Console logs with `CLError.network` or history list hanging on initial load.

### Pitfall 4: RunRecord Schema Extension Crashing on First Launch

**What goes wrong:** Phase 2 shipped `RunRecord` without `topSpeed` etc. Phase 3 adds new stored properties. If `VersionedSchema` migration plan is missing or incorrectly ordered, SwiftData throws a fatal error on container init.

**Why it happens:** SwiftData detects a mismatch between the compiled model and the on-disk store.

**How to avoid:**
- All new `RunRecord` and `FrameRecord` properties MUST be `Optional` (e.g., `var topSpeed: Double?`).
- Create `SchemaV1` (wrapping current schema) and `SchemaV2` (with new properties).
- Use `.lightweight` migration stage — optional property additions qualify.
- Wire `migrationPlan:` into `ModelConfiguration`.
- Test by building against a device/simulator with existing Phase 2 data before shipping.

**Warning signs:** `try!` on `ModelContainer` crashes at launch.

### Pitfall 5: LiveViewModel Subscribing After Broadcaster.stop()

**What goes wrong:** User ends day, then starts a new day. `LiveViewModel` holds a stale stream that has been `finish()`-ed by `broadcaster.stop()`. The waveform shows no data.

**Why it happens:** `LiveViewModel.startConsuming()` is not called again on new day start.

**How to avoid:** `LiveViewModel.startConsuming()` is called from AppModel's `startDay()` flow (or from the Today tab's `.onChange(of: appModel.isDayActive)`). Symmetrically, `stopConsuming()` is called on `endDay`. Each day start creates a fresh stream.

### Pitfall 6: GPS Speed Not in FilteredFrame

**What goes wrong:** Planner assumes `gpsSpeed` is available on `FilteredFrame` — it is not. GPS is on a separate stream arriving at ~1Hz.

**Why it happens:** `FilteredFrame` is purely IMU. GPS is `GPSReading` from `GPSManager.makeStream()`.

**How to avoid:**
- For the **live HUD** metric card: read `appModel.lastGPSSpeed` (already polled at 10Hz). No second stream needed.
- For **post-run charts and stats** (speed vs time, top speed): GPS speed must be stored per-frame. Two options:
  1. Add `gpsSpeed: Double?` to `FrameRecord` and populate it in a join step during the persistence flush (AppModel knows the latest GPS from `lastGPSSpeed` at flush time).
  2. Store `GPSRecord` separately and join on timestamp in PostRunViewModel queries.
  Option 1 is simpler and matches the existing "everything in FrameRecord" pattern. Go with Option 1.

---

## Code Examples

Verified patterns from official sources and confirmed project patterns:

### TabView Root Restructure

```swift
// ArcticEdgeApp.swift — wrap WindowGroup content in TabView
// Source: iOS 18 TabView new API (WWDC24)
WindowGroup {
    TabView {
        Tab("Today", systemImage: "mountain.2.fill") {
            TodayTabView()
        }
        Tab("History", systemImage: "clock.fill") {
            RunHistoryView()
        }
    }
    .tint(Color(red: 0.12, green: 0.56, blue: 1.0))  // Arctic blue accent
    .modelContainer(appModel.container)
    .environment(appModel)
    .task { await appModel.setupPipelineAsync() }
}
```

### Live View Auto-Presentation

```swift
// TodayTabView.swift — observe classifier state, auto-present live view
// Uses fullScreenCover driven by appModel.classifierStateLabel
struct TodayTabView: View {
    @Environment(AppModel.self) private var appModel
    @State private var showLive = false

    var body: some View {
        ContentView()
            .fullScreenCover(isPresented: $showLive) {
                LiveTelemetryView()
            }
            .onChange(of: appModel.classifierStateLabel) { _, new in
                showLive = (new == "SKIING")
            }
    }
}
```

### CLGeocoder Async Wrapper

```swift
// Source: withCheckedThrowingContinuation pattern (Hacking with Swift concurrency guide)
extension CLGeocoder {
    func reverseGeocode(location: CLLocation) async throws -> CLPlacemark? {
        try await withCheckedThrowingContinuation { continuation in
            reverseGeocodeLocation(location) { placemarks, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: placemarks?.first)
                }
            }
        }
    }
}

// Usage — prefer .name (point of interest name) then .locality (city)
func resortName(for location: CLLocation) async -> String {
    let placemark = try? await geocoder.reverseGeocode(location: location)
    return placemark?.name ?? placemark?.locality ?? "Unknown Resort"
}
```

### SwiftData Schema Migration (V1 -> V2)

```swift
// Source: Hacking with Swift SwiftData migration tutorial
// SchemaV2.swift

enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [FrameRecord.self, RunRecord.self] }
    // V1 RunRecord: runID, startTimestamp, endTimestamp, isOrphaned
}

enum SchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] { [FrameRecord.self, RunRecord.self] }
    // V2 adds: topSpeed, avgSpeed, verticalDrop, distanceMeters, resortName to RunRecord
    // V2 adds: gpsSpeed to FrameRecord
    // ALL new properties MUST be Optional for lightweight migration
}

enum ArcticEdgeMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [SchemaV1.self, SchemaV2.self] }
    static let v1ToV2 = MigrationStage.lightweight(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self
    )
    static var stages: [MigrationStage] { [v1ToV2] }
}

// In AppModel.init(), update ModelContainer:
let config = ModelConfiguration(schema: Schema([FrameRecord.self, RunRecord.self]))
let c = try! ModelContainer(
    for: Schema([FrameRecord.self, RunRecord.self]),
    migrationPlan: ArcticEdgeMigrationPlan.self,
    configurations: config
)
```

### Post-Run Stats Computation

```swift
// PostRunViewModel.swift — compute per-run stats from FrameRecord array
// Source: project pattern; no external library needed
func computeStats(from frames: [FrameRecord]) -> RunStats {
    let speeds = frames.compactMap { $0.gpsSpeed }.filter { $0 > 0 }
    let topSpeed = speeds.max() ?? 0
    let avgSpeed = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)

    // Vertical drop: integrate GPS speed * sin(pitch) over time
    // This is an approximation; Phase 4 will calibrate
    let verticalDrop = zip(frames, frames.dropFirst()).reduce(0.0) { acc, pair in
        let dt = pair.1.timestamp - pair.0.timestamp
        let speed = pair.0.gpsSpeed ?? 0
        let pitch = pair.0.pitch
        return acc + abs(speed * sin(pitch) * dt)
    }

    let distanceMeters = zip(frames, frames.dropFirst()).reduce(0.0) { acc, pair in
        let dt = pair.1.timestamp - pair.0.timestamp
        let speed = pair.0.gpsSpeed ?? 0
        return acc + speed * dt
    }

    return RunStats(topSpeed: topSpeed, avgSpeed: avgSpeed,
                    verticalDrop: verticalDrop, distanceMeters: distanceMeters)
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| CADisplayLink + UIKit custom view for waveforms | `TimelineView(.animation)` + `Canvas` | iOS 15 (WWDC21) | Pure SwiftUI, zero UIKit bridging needed |
| `chartOverlay` + DragGesture for chart scrubber | `chartXSelection(value:)` modifier | iOS 17 (WWDC23) | Single modifier replaces ~20 lines of gesture math |
| `NavigationView` for nav stack | `NavigationStack` | iOS 16 (WWDC22) | `NavigationView` deprecated; `NavigationStack` is current |
| Custom pagination state machine | `FetchDescriptor.fetchOffset + fetchLimit` | iOS 17 | Built-in to SwiftData; no custom tracking logic |
| CoreData `NSMigratePersistentStoresAutomatically` | `VersionedSchema` + `SchemaMigrationPlan` | iOS 17 | Explicit, type-safe migration plan |
| TabView with integer tag selection | `Tab` struct with `value:` binding | iOS 18 (WWDC24) | Compile-time safety on tab selection |

**Deprecated/outdated:**
- `NavigationView`: Deprecated iOS 16+ — do not use; `NavigationStack` is the replacement.
- `chartOverlay` for selection: Still works but `chartXSelection` is the modern API (iOS 17+) — use `chartXSelection` since this project targets current iOS.
- Completion-handler `CLGeocoder.reverseGeocodeLocation(_:completionHandler:)`: Still available but wrap in `withCheckedThrowingContinuation` for Swift 6 concurrency compliance.

---

## Open Questions

1. **GPS speed storage strategy: FrameRecord vs GPSRecord**
   - What we know: `FrameRecord` has no `gpsSpeed` field; `FilteredFrame` has no GPS speed either; GPS arrives at ~1Hz on a separate stream.
   - What's unclear: The "nearest GPS sample" join at flush time requires AppModel to track the latest GPSReading alongside the ring buffer drain. Is this clean enough, or does a `GPSRecord` table give better post-run time alignment?
   - Recommendation: Add `gpsSpeed: Double?` to `FrameRecord` with the latest GPS value stamped at flush time (~2 second granularity). This is sufficient for phase 3 stats and charts; Phase 4 field validation can refine if needed.

2. **Vertical drop calculation accuracy**
   - What we know: True vertical drop requires integrating the vertical component of velocity over time. GPS speed gives horizontal+vertical magnitude; `pitch` gives approximate slope angle. The formula `speed * sin(pitch) * dt` is an approximation.
   - What's unclear: iPhone pitch at phone-in-pocket is not slope angle — it's the phone's orientation relative to gravity, which varies with how the skier holds/positions the phone.
   - Recommendation: Implement the approximation and mark `verticalDrop` as "estimated." Phase 4 field validation will calibrate. Document the limitation in code comments.

3. **Resort name from CLGeocoder: reliability**
   - What we know: `CLPlacemark.name` returns a point-of-interest name for major locations; `CLPlacemark.locality` returns the city name. Apple developer forums confirm `areasOfInterest` is unreliable for anything smaller than airports and major landmarks.
   - What's unclear: Whether major ski resorts (Whistler, Vail, etc.) appear in `CLPlacemark.name` at their summit/run coordinates.
   - Recommendation: Use `CLPlacemark.name` if non-nil and non-numeric (addresses return numeric names), else fall back to `CLPlacemark.locality`. Cache in `RunRecord.resortName` on first geocode. If both are nil or unhelpful, show "Mountain Resort" as fallback.

4. **Run-end signal to trigger post-run sheet**
   - What we know: `ActivityClassifier.confirmChairliftTransition()` is the source of truth. `AppModel.hudPollingTask` polls `classifier.classifierStateLabel` and `classifier.currentRunID` at 10Hz.
   - What's unclear: The polling loop can detect when `currentRunID` transitions from non-nil to nil, but that happens up to 100ms after the transition. Is 100ms acceptable?
   - Recommendation: 100ms is imperceptible for a sheet presentation. No additional notification mechanism needed. `AppModel` captures the last seen `currentRunID` and when it becomes nil, records it as `lastFinalizedRunID`.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Swift Testing (`import Testing`) — already in use for all project tests |
| Config file | None — Xcode discovers tests automatically |
| Quick run command | `xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:ArcticEdgeTests/LiveViewModelTests 2>&1 \| grep -E "(Test|FAIL|PASS)"` |
| Full suite command | `xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 16 Pro' 2>&1 \| grep -E "(Test|FAIL|PASS)"` |

### Phase Requirements to Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| LIVE-01 | Waveform ring buffer snapshot builds correctly from FilteredFrame stream | unit | `...only-testing:ArcticEdgeTests/LiveViewModelTests/testWaveformSnapshotBuilds` | Wave 0 |
| LIVE-02 | Metric values (pitch, roll, gForce) update from incoming FilteredFrame | unit | `...only-testing:ArcticEdgeTests/LiveViewModelTests/testMetricValuesUpdate` | Wave 0 |
| LIVE-03 | Waveform snapshot never exceeds windowSize (1000 samples) | unit | `...only-testing:ArcticEdgeTests/LiveViewModelTests/testSnapshotDoesNotExceedWindowSize` | Wave 0 |
| ANLYS-01 | PostRunViewModel loads correct FrameRecords for a given runID | unit | `...only-testing:ArcticEdgeTests/PostRunViewModelTests/testFrameRecordLoading` | Wave 0 |
| ANLYS-02 | Stats computation: topSpeed, avgSpeed, verticalDrop, distanceMeters are accurate | unit | `...only-testing:ArcticEdgeTests/PostRunViewModelTests/testStatsComputation` | Wave 0 |
| ANLYS-03 | Session aggregates: total vertical and run count across multiple RunRecords | unit | `...only-testing:ArcticEdgeTests/PostRunViewModelTests/testSessionAggregates` | Wave 0 |
| ANLYS-04 | Scrubber frame lookup: correct FrameRecord returned for selected timestamp | unit | `...only-testing:ArcticEdgeTests/PostRunViewModelTests/testScrubberFrameLookup` | Wave 0 |
| HIST-01 | HistoryViewModel pagination: fetchNextPage advances offset correctly | unit | `...only-testing:ArcticEdgeTests/HistoryViewModelTests/testPaginationOffsetAdvances` | Wave 0 |
| HIST-02 | History row resort name: falls back to locality when name is nil | unit | `...only-testing:ArcticEdgeTests/HistoryViewModelTests/testResortNameFallback` | Wave 0 |

*Note: LIVE-03 (120fps fluidity) and UI layout are manual verify checkpoints — not automatable in unit tests.*

### Sampling Rate
- **Per task commit:** Run ViewModel tests for the ViewModel modified in that task
- **Per wave merge:** Full suite green
- **Phase gate:** Full suite green before `/gsd:verify-work`

### Wave 0 Gaps
- [ ] `ArcticEdgeTests/Live/LiveViewModelTests.swift` — covers LIVE-01, LIVE-02, LIVE-03
- [ ] `ArcticEdgeTests/PostRun/PostRunViewModelTests.swift` — covers ANLYS-01, ANLYS-02, ANLYS-03, ANLYS-04
- [ ] `ArcticEdgeTests/History/HistoryViewModelTests.swift` — covers HIST-01, HIST-02
- [ ] `ArcticEdgeTests/Helpers/MockPersistenceService.swift` — extend existing MockPersistenceService with `fetchRunRecords` and `fetchFrameRecords` methods for ViewModel tests

---

## Sources

### Primary (HIGH confidence)
- Apple Developer Documentation: TimelineView — `.animation` schedule behavior, context.date usage
- Apple Developer Documentation: Swift Charts — LineMark, chartXSelection (iOS 17+), RuleMark, AxisMarks
- Hacking with Swift — SwiftData FetchDescriptor: fetchLimit, fetchOffset, sortBy pagination patterns
- Hacking with Swift — TimelineView + Canvas: draw closure, context.date, animation schedule
- Hacking with Swift — VersionedSchema migration: lightweight migration for optional property additions
- Existing project codebase: FilteredFrame, StreamBroadcaster, AppModel.startHUDPolling(), StatCard patterns

### Secondary (MEDIUM confidence)
- Swift with Majid "Mastering Charts in SwiftUI: Selection" — chartXSelection pattern with RuleMark + annotation (verified against iOS 17 release notes)
- Swift with Majid "Mastering Charts in SwiftUI: Interactions" — chartOverlay fallback for < iOS 17
- createwithswift.com "Programmatic navigation with Tab View in SwiftUI" — iOS 18 Tab struct syntax
- Apple Developer Forums thread 113568 — CLGeocoder areasOfInterest limitations confirmed

### Tertiary (LOW confidence — flag for validation)
- Resort name from `CLPlacemark.name` at ski mountain coordinates: untested on actual mountain GPS coordinates. Validate against Whistler/Vail/etc. coordinates in unit test or manual test before shipping HIST-02.
- Vertical drop approximation formula (`speed * sin(pitch) * dt`): biomechanically motivated starting hypothesis — requires on-mountain validation in Phase 4.

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all APIs are first-party, well-documented, already in use in the project or confirmed via Hacking with Swift examples
- Architecture: HIGH — patterns are direct extensions of established project patterns (AppModel polling, @Observable @MainActor, actor bridging)
- Pitfalls: HIGH — GPS speed gap, schema migration crash risk, post-run flush race condition are code-verified based on reading actual source files; geocoder rate limit is well-documented community knowledge
- Stats computation: MEDIUM — vertical drop formula is an approximation; distanceMeters integration is standard physics

**Research date:** 2026-03-10
**Valid until:** 2026-04-10 (stable APIs; Swift Charts chartXSelection is iOS 17+ and project targets current iOS)
