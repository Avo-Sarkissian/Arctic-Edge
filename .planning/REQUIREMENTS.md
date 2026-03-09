# Requirements: ArcticEdge

**Defined:** 2026-03-08
**Core Value:** Every carving frame captured, every run segmented automatically — no data lost, no manual intervention required on the mountain.

## v1 Requirements

### Motion Engine

- [ ] **MOTN-01**: App captures CMDeviceMotion at 100Hz via MotionManager actor using Swift 7 AsyncStream
- [ ] **MOTN-02**: High-pass biquad filter (Accelerate/vDSP) isolates carve-pressure signal — preserve >2Hz, reject <0.5Hz
- [ ] **MOTN-03**: In-memory ring buffer stores last ~10 seconds of filtered frames (1000 samples) with synchronous, transactional drain (no awaits inside drain)
- [ ] **MOTN-04**: StreamBroadcaster actor fans out the sensor stream to LiveViewModel and ActivityClassifier simultaneously without calling CMMotionManager start twice
- [ ] **MOTN-05**: Thermal-aware throttling gracefully degrades sample rate (100Hz to 50Hz to 25Hz) when ProcessInfo.thermalState reaches critical

### Session Management

- [ ] **SESS-01**: HKWorkoutSession provides background CPU budget, keeping sensor capture active when screen locks mid-run
- [ ] **SESS-02**: SwiftData persists sensor frames in batches via background ModelContext — never per-frame; flush every 200-500 samples
- [ ] **SESS-03**: SwiftData schema defines FrameRecord (timestamp, runID, filtered values) with #Index on timestamp and runID for fast post-run queries
- [ ] **SESS-04**: App performs emergency data flush on applicationDidEnterBackground and applicationWillTerminate to prevent data loss
- [ ] **SESS-05**: App detects and recovers orphaned HKWorkoutSession on launch (UserDefaults sentinel pattern)

### Activity Detection

- [ ] **DETC-01**: ActivityClassifier distinguishes active skiing from chairlift rides using fused GPS velocity, g-force variance, and motion activity signature
- [ ] **DETC-02**: Classifier applies hysteresis — requires N consecutive seconds of consistent state before triggering run start or end (prevents false transitions on slow skiing or brief stops)
- [ ] **DETC-03**: Each detected skiing segment is automatically stored as a distinct RunRecord with start timestamp, end timestamp, and runID

### Live Telemetry

- [ ] **LIVE-01**: Live Telemetry view renders scrolling carve-pressure waveform at 120Hz using Canvas + TimelineView (ProMotion-native, no per-sample SwiftUI nodes)
- [ ] **LIVE-02**: Live Telemetry view overlays frosted glass metric cards (ultraThinMaterial) showing real-time pitch, roll, g-force, and GPS speed
- [ ] **LIVE-03**: Live Telemetry view remains fluid at 120fps without frame drops during active 100Hz data ingestion

### Post-Run Analysis

- [ ] **ANLYS-01**: Post-Run Analysis view displays time-series charts (Swift Charts) for speed, g-force, and carve-pressure across the full run
- [ ] **ANLYS-02**: Post-Run Analysis view shows per-run stats summary: top speed, average speed, vertical drop, run duration, distance
- [ ] **ANLYS-03**: Post-Run Analysis view shows session-level aggregates: total vertical, total run count, total time skiing vs riding
- [ ] **ANLYS-04**: Post-Run Analysis view provides segmented waveform replay — IMU data time-aligned with GPS speed profile, tappable to inspect any moment

### Run History

- [ ] **HIST-01**: Run history browser lists all runs grouped by day, paginated via SwiftData FetchDescriptor (lazy loading for long season history)
- [ ] **HIST-02**: Each run entry shows date, mountain/resort name (CoreLocation reverse geocode), top speed, and total vertical

## v2 Requirements

### Carving Intelligence

- **CRVG-01**: Carving quality score per run — single 0-100 score summarizing carve purity (requires real-world data calibration before implementation)
- **CRVG-02**: Turn count and turn frequency per run — carve-pressure peak detection for turns-per-vertical-meter
- **CRVG-03**: Edge engagement classification per turn — carve vs skid vs mixed technique

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
| MOTN-01 | Phase 1 | Pending |
| MOTN-02 | Phase 1 | Pending |
| MOTN-03 | Phase 1 | Pending |
| MOTN-04 | Phase 1 | Pending |
| MOTN-05 | Phase 1 | Pending |
| SESS-01 | Phase 1 | Pending |
| SESS-02 | Phase 1 | Pending |
| SESS-03 | Phase 1 | Pending |
| SESS-04 | Phase 1 | Pending |
| SESS-05 | Phase 1 | Pending |
| DETC-01 | Phase 2 | Pending |
| DETC-02 | Phase 2 | Pending |
| DETC-03 | Phase 2 | Pending |
| LIVE-01 | Phase 3 | Pending |
| LIVE-02 | Phase 3 | Pending |
| LIVE-03 | Phase 3 | Pending |
| ANLYS-01 | Phase 3 | Pending |
| ANLYS-02 | Phase 3 | Pending |
| ANLYS-03 | Phase 3 | Pending |
| ANLYS-04 | Phase 3 | Pending |
| HIST-01 | Phase 3 | Pending |
| HIST-02 | Phase 3 | Pending |

**Coverage:**
- v1 requirements: 22 total
- Mapped to phases: 22
- Unmapped: 0 ✓

---
*Requirements defined: 2026-03-08*
*Last updated: 2026-03-08 after initial definition*
