# Roadmap: ArcticEdge

## Overview

ArcticEdge ships in four phases driven by hard technical dependencies. Phase 1 builds the sensor pipeline and persistence foundation that everything else runs on. Phase 2 adds the activity classifier that turns raw frames into meaningful run segments. Phase 3 delivers the live dashboard and post-run analysis views that are the visible product. Phase 4 closes the gap between lab correctness and mountain reality through hardening, power management, and field calibration.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Motion Engine & Session Foundation** - Sensor pipeline, filtering, ring buffer, persistence, and background execution (completed 2026-03-09)
- [x] **Phase 2: Activity Detection & Run Management** - Skiing vs. chairlift classification, run segmentation, resilience (completed 2026-03-10)
- [ ] **Phase 3: Live Telemetry & Post-Run Analysis** - Live waveform dashboard, post-run charts, run history
- [ ] **Phase 4: Hardening & Field Validation** - Power management, filter calibration, classifier tuning from real mountain data

## Phase Details

### Phase 1: Motion Engine & Session Foundation
**Goal**: The full sensor pipeline runs correctly under strict concurrency, with no data loss and no main-thread interference
**Depends on**: Nothing (first phase)
**Requirements**: MOTN-01, MOTN-02, MOTN-03, MOTN-04, MOTN-05, SESS-01, SESS-02, SESS-03, SESS-04, SESS-05
**Success Criteria** (what must be TRUE):
  1. App reads CMDeviceMotion at 100Hz and the stream reaches downstream consumers without any Sendable violations at build time
  2. The high-pass filter isolates carve-pressure signal from body sway with no frame drops in the ring buffer during sustained 100Hz ingestion
  3. Sensor frames are persisted in batches to SwiftData with no main-thread blocking observable as lag or hangs
  4. Sensor capture remains active when the screen locks, verified by confirming frames are recorded during a screen-off period
  5. App detects and recovers an orphaned HKWorkoutSession on relaunch, restoring capture state without user intervention
**Plans**: 2 plans

Plans:
- [ ] 01-01-PLAN.md — Motion actors: FilteredFrame struct, BiquadHighPassFilter (vDSP), RingBuffer, MotionManager, StreamBroadcaster; build settings (SWIFT_STRICT_CONCURRENCY = complete); test stubs + implementation
- [ ] 01-02-PLAN.md — Session layer: SwiftData schema (FrameRecord + RunRecord with #Index), PersistenceService (@ModelActor, batched flush), WorkoutSessionManager (HKWorkoutSession, sentinel), emergency flush, orphan recovery, app pipeline wiring

### Phase 2: Activity Detection & Run Management
**Goal**: The app automatically segments skiing from chairlift rides, creating clean per-run records without user input
**Depends on**: Phase 1
**Requirements**: DETC-01, DETC-02, DETC-03
**Success Criteria** (what must be TRUE):
  1. A chairlift ride is not recorded as a ski run: run records contain only downhill segments
  2. A new run record is created automatically at the start of each detected skiing segment, with no user action required
  3. Brief stops mid-run (slow traversal, flat section) do not prematurely end the current run segment
  4. GPS speed, g-force variance, and motion activity are all contributing to classification decisions (verifiable via debug overlay)
**Plans**: 3 plans

Plans:
- [ ] 02-01-PLAN.md — GPSManager actor (CLLocationUpdate.liveUpdates), ActivityManager actor (CMMotionActivityManager bridge), injectable mock protocols, Wave 0 test stubs (11 ActivityClassifierTests, red)
- [ ] 02-02-PLAN.md — ActivityClassifier actor: hysteresis state machine (TDD red->green), three-signal fusion, RunRecord lifecycle (DETC-01, DETC-02, DETC-03)
- [ ] 02-03-PLAN.md — AppModel refactor (startDay/endDay), ContentView Arctic Dark session controls, ClassifierDebugHUD (#if DEBUG), human verify checkpoint

### Phase 3: Live Telemetry & Post-Run Analysis
**Goal**: Skiers see real-time carving dynamics during a run and full graphed analysis after, with browsable history across the season
**Depends on**: Phase 2
**Requirements**: LIVE-01, LIVE-02, LIVE-03, ANLYS-01, ANLYS-02, ANLYS-03, ANLYS-04, HIST-01, HIST-02
**Success Criteria** (what must be TRUE):
  1. The live waveform scrolls continuously at 120fps during active 100Hz data ingestion with no visible frame drops on iPhone 16 Pro
  2. Frosted glass metric cards display real-time pitch, roll, g-force, and GPS speed updating each frame during a run
  3. Post-run analysis charts (speed, g-force, carve-pressure) are visible within 2 seconds of a run ending
  4. Per-run stats (top speed, average speed, vertical, duration, distance) and session aggregates (total vertical, run count, time skiing vs. riding) are accurate and match recorded data
  5. Run history lists all runs grouped by day, with resort name from reverse geocode, and loads without blocking the UI for a season of data
**Plans**: 6 plans

Plans:
- [ ] 03-01-PLAN.md — Wave 0 test stubs: LiveViewModelTests (3 stubs), PostRunViewModelTests (4 stubs), HistoryViewModelTests (2 stubs), extended MockPersistenceService
- [ ] 03-02-PLAN.md — Schema migration (SchemaV2, ArcticEdgeMigrationPlan), RunRecord extension (topSpeed, avgSpeed, verticalDrop, distanceMeters, resortName), FrameRecord.gpsSpeed, PersistenceService fetch methods + flushWithGPS
- [ ] 03-03-PLAN.md — LiveViewModel (@Observable @MainActor, 1000-sample waveform buffer), LiveTelemetryView (Canvas + TimelineView waveform, four frosted glass HUD metric cards)
- [ ] 03-04-PLAN.md — PostRunViewModel (emergencyFlush-before-query, stats computation, session aggregates, scrubber), PostRunAnalysisView (three Swift Charts LineMark, chartXSelection, stats grid)
- [ ] 03-05-PLAN.md — HistoryViewModel (FetchDescriptor pagination, DayGroup, CLGeocoder resort name cache), RunHistoryView (NavigationStack, grouped list, day headers, compact run rows)
- [ ] 03-06-PLAN.md — AppModel wiring (lastFinalizedRunID, GPS-stamped flush), TodayTabView (fullScreenCover live view + post-run sheet), ArcticEdgeApp TabView root, human verify

### Phase 4: Hardening & Field Validation
**Goal**: ArcticEdge survives a full ski day in cold weather, under thermal pressure, across all chairlift types, with calibrated filter and classifier
**Depends on**: Phase 3
**Requirements**: (None pre-defined — this phase produces calibration from real-world data and closes empirical gaps identified in research)
**Success Criteria** (what must be TRUE):
  1. App records a full 6-hour ski day session without data loss, crash, or battery exhaustion at typical cold-weather (0 to -15C) battery capacity
  2. Power Saver mode activates automatically below 30% battery and reduces sensor load without stopping capture
  3. Filter coefficients and classifier thresholds are updated from labeled beta run data, and the classifier produces no false ski/chairlift transitions in a labeled test set
  4. The debug overlay (sample rate, thermal state, GPS accuracy, classifier state) correctly reflects live system state at all times
**Plans**: TBD

Plans:
- [ ] 04-01: Power Saver mode (60Hz UI, GPS duty-cycling), debug overlay, MetricKit battery profiling, filter and classifier calibration from beta data

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Motion Engine & Session Foundation | 3/3 | Complete    | 2026-03-09 |
| 2. Activity Detection & Run Management | 3/3 | Complete   | 2026-03-10 |
| 3. Live Telemetry & Post-Run Analysis | 0/6 | Not started | - |
| 4. Hardening & Field Validation | 0/1 | Not started | - |
