# Requirements: ArcticEdge

**Defined:** 2026-03-08
**Core Value:** Every carving frame captured, every run segmented automatically — no data lost, no manual intervention required on the mountain.

## v1 Requirements

### Motion Engine

- [x] **MOTN-01**: App captures CMDeviceMotion at 100Hz via MotionManager actor using Swift 7 AsyncStream
- [x] **MOTN-02**: High-pass biquad filter (Accelerate/vDSP) isolates carve-pressure signal — preserve >2Hz, reject <0.5Hz
- [x] **MOTN-03**: In-memory ring buffer stores last ~10 seconds of filtered frames (1000 samples) with synchronous, transactional drain (no awaits inside drain)
- [x] **MOTN-04**: StreamBroadcaster actor fans out the sensor stream to LiveViewModel and ActivityClassifier simultaneously without calling CMMotionManager start twice
- [x] **MOTN-05**: Thermal-aware throttling gracefully degrades sample rate (100Hz to 50Hz to 25Hz) when ProcessInfo.thermalState reaches critical

### Session Management

- [x] **SESS-01**: HKWorkoutSession provides background CPU budget, keeping sensor capture active when screen locks mid-run
- [x] **SESS-02**: SwiftData persists sensor frames in batches via background ModelContext — never per-frame; flush every 200-500 samples
- [x] **SESS-03**: SwiftData schema defines FrameRecord (timestamp, runID, filtered values) with #Index on timestamp and runID for fast post-run queries
- [x] **SESS-04**: App performs emergency data flush on applicationDidEnterBackground and applicationWillTerminate to prevent data loss
- [x] **SESS-05**: App detects and recovers orphaned HKWorkoutSession on launch (UserDefaults sentinel pattern)
  - *Was partial until 2026-08-01:* recovery cleared the sentinel but never touched the RunRecords left open by the crash. Open runs are now closed at their last captured frame and scored, or marked orphaned when no frames remain.

### Activity Detection

- [x] **DETC-01**: ActivityClassifier distinguishes active skiing from chairlift rides using fused GPS velocity, g-force variance, and motion activity signature
- [x] **DETC-02**: Classifier applies hysteresis — requires N consecutive seconds of consistent state before triggering run start or end (prevents false transitions on slow skiing or brief stops)
- [x] **DETC-03**: Each detected skiing segment is automatically stored as a distinct RunRecord with start timestamp, end timestamp, and runID

### Live Telemetry

- [x] **LIVE-01**: Live Telemetry view renders scrolling carve-pressure waveform at 120Hz using Canvas + TimelineView (ProMotion-native, no per-sample SwiftUI nodes)
- [x] **LIVE-02**: Live Telemetry view overlays frosted glass metric cards (ultraThinMaterial) showing real-time speed, g-force, and lateral load
  - *Amended 2026-08-01:* pitch and roll were removed. For a pocket-worn phone they measure the phone's orientation, not the skier's, so presenting them violated the honesty rules. Replaced with gravity-referenced lateral load.
- [x] **LIVE-03**: Live Telemetry view remains fluid at 120fps without frame drops during active 100Hz data ingestion

### Post-Run Analysis

- [x] **ANLYS-01**: Post-Run Analysis view displays time-series charts (Swift Charts) for speed, g-force, and carve-pressure across the full run
- [x] **ANLYS-02**: Post-Run Analysis view shows per-run stats summary: top speed, average speed, vertical drop, run duration, distance
  - *Amended 2026-08-01:* stats are computed and persisted at run finalization, not at view load, and each is Optional so an unmeasured value shows a dash. Vertical drop requires a barometer.
- [x] **ANLYS-03**: Post-Run Analysis view shows session-level aggregates: total vertical, total run count, total time skiing vs riding
- [x] **ANLYS-04**: Post-Run Analysis view provides segmented waveform replay — IMU data time-aligned with GPS speed profile, tappable to inspect any moment

### Run History

- [x] **HIST-01**: Run history browser lists all runs grouped by day, paginated via SwiftData FetchDescriptor (lazy loading for long season history)
- [x] **HIST-02**: Each run entry shows date, mountain/resort name (MapKit reverse geocode), carving score, top speed, and total vertical
  - *Was dead until 2026-08-01:* `geocodeIfNeeded` had no callers and no run coordinate was ever persisted, so every row read a placeholder. Runs now record their start coordinate and rows resolve on appear.

## v2 Requirements

### Carving Intelligence

- [x] **CRVG-01**: Carving quality score per run — single 0-100 score. Built, tested, persisted at finalization, and surfaced on post-run, history, and Today. **Provisional** until anchors are recalibrated from labelled runs; export lives in Settings.
- [x] **CRVG-02**: Turn count and turn frequency per run — `TurnSegmenter` detects turns from gravity-referenced yaw rate; count and per-turn marks are exposed on `CarvingScore` and drawn as the turn ledger.
- **CRVG-03**: Edge engagement classification per turn — carve vs skid vs mixed technique. Not built. `carvePurity` is the closest proxy and is GPS gated.

### Extended Metrics

- **EXTD-01**: Slope gradient estimation per run segment — derived from pitch sensor and speed
- **EXTD-02**: Apple Watch companion — coarse stats display during run (IMU via iPhone, display on Watch)

## Out of Scope

| Feature | Reason |
|---------|--------|
| Social sharing / leaderboards | Slopes and Strava own this space; scope dilution without telemetry benefit |
| Real-time audio coaching | Requires validated carving classifier; false coaching worse than none in v1 |
| Trail / piste map overlays | Licensing burden; GPS accuracy (~5m) insufficient for reliable trail attribution |
| Video recording or overlay | Thermal and battery problem when combined with 100Hz IMU |
| Weather integration | Out of telemetry scope; WeatherKit available later as a one-line add |
| Subscription monetization | Premature before product-market fit |
| Mountain resort database | CoreLocation reverse geocoding is sufficient for v1 resort identification |
| CMBatchedSensorManager | Delivers 1-second batches; incompatible with live 100Hz dashboard requirement |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| MOTN-01 | Phase 1 | Complete |
| MOTN-02 | Phase 1 | Complete |
| MOTN-03 | Phase 1 | Complete |
| MOTN-04 | Phase 1 | Complete |
| MOTN-05 | Phase 1 | Complete |
| SESS-01 | Phase 1 | Complete |
| SESS-02 | Phase 1 | Complete |
| SESS-03 | Phase 1 | Complete |
| SESS-04 | Phase 1 | Complete |
| SESS-05 | Phase 1 | Complete |
| DETC-01 | Phase 2 | Complete |
| DETC-02 | Phase 2 | Complete |
| DETC-03 | Phase 2 | Complete |
| LIVE-01 | Phase 3 | Complete |
| LIVE-02 | Phase 3 | Complete |
| LIVE-03 | Phase 3 | Complete |
| ANLYS-01 | Phase 3 | Complete |
| ANLYS-02 | Phase 3 | Complete |
| ANLYS-03 | Phase 3 | Complete |
| ANLYS-04 | Phase 3 | Complete |
| HIST-01 | Phase 3 | Complete |
| HIST-02 | Phase 3 | Complete |

**Coverage:**
- v1 requirements: 22 total
- Mapped to phases: 22
- Unmapped: 0 (verified against ROADMAP.md)
- Phase 4 note: Hardening and field validation phase — produces calibration data and power management; no discrete pre-defined requirement IDs

**2026-08-01 audit note.** Three requirements were marked Complete while being functionally dead in the shipped app (HIST-02 geocoding, SESS-05 orphan recovery, and the ContentView stats row). A requirement is not complete until something calls it and a user can see the result. Amendments above record what changed.

---
*Requirements defined: 2026-03-08*
*Last updated: 2026-08-01 after the capture, data spine, metric honesty, UI, and calibration passes*
