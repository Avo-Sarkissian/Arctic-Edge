# Phase 2: Activity Detection & Run Management - Context

**Gathered:** 2026-03-09
**Status:** Ready for planning

<domain>
## Phase Boundary

Automatic segmentation of skiing vs chairlift rides, creating clean per-run RunRecord entries without user input. The user arms the classifier with a single 'Start Day' tap; from there, all run boundaries are owned by ActivityClassifier. No manual run splitting, no per-run start/stop. 'End Day' tears down all capture cleanly.

</domain>

<decisions>
## Implementation Decisions

### Session automation model
- User taps 'Start Day' to arm the classifier — one deliberate action at the trailhead starts GPS + IMU + classifier
- Once armed, ActivityClassifier fully owns run start and end boundaries — no user action per run
- User taps 'End Day' to stop all capture immediately: finalizes any open RunRecord, stops GPS + IMU
- No manual run splitting or boundary override — classifier owns all boundaries (v2 consideration if needed post on-mountain testing)

### Hysteresis philosophy
- Conservative bias: prefer missing the first frame of a run over recording chairlift data inside a run record
- Asymmetric windows: longer confirmation required for SKIING onset (e.g., 3 sec) than for run END (e.g., 2 sec) — specific values are Claude's calibration targets
- RunRecord is NOT created until the full skiing hysteresis window elapses (no provisional records)
- Frames captured during the hysteresis window are held in memory and attributed to the run once confirmed

### Chairlift detection logic
- All three signals required to confirm CHAIRLIFT: automotive CMMotionActivity + GPS speed in lift range + low g-force variance
- Two of three is insufficient — prevents false chairlift detection on slow traverses
- Brief stops (stationary mid-run) do not end a run — only the full chairlift signature does
- During GPS blackout (gondola tunnel, enclosed cabin): if already in CHAIRLIFT state, remain in CHAIRLIFT — do not flip back to skiing due to missing GPS; rely on IMU + motion activity to sustain the state

### Debug overlay
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

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `StreamBroadcaster.makeStream()`: ActivityClassifier subscribes here for FilteredFrame — no second CMMotionManager start needed
- `PersistenceService.createRunRecord()` / `finalizeRunRecord()`: Already implemented — ActivityClassifier drives these rather than manual AppModel calls
- `RunRecord`: Schema already has runID, startTimestamp, endTimestamp, isOrphaned — no schema changes needed for Phase 2
- `FilteredFrame`: Contains pitch, roll, yaw, userAccelX/Y/Z, filteredAccelZ — g-force variance computed from these

### Established Patterns
- Actor pattern: ActivityClassifier should be an `actor` following MotionManager/StreamBroadcaster/PersistenceService precedent
- SWIFT_STRICT_CONCURRENCY = complete: all new actors and types must be Sendable-clean
- Swift Testing (`import Testing`): all classifier logic must have tests — no XCTest for new logic
- AppModel @Observable class: new session control (startDay/endDay) will be methods on AppModel

### Integration Points
- `AppModel.startSession()` / `endSession()` currently manual — Phase 2 replaces these with `startDay()` / `endDay()` that arm/disarm ActivityClassifier
- ActivityClassifier drives `PersistenceService.createRunRecord()` and `finalizeRunRecord()` autonomously
- CLLocationManager needs to be added — likely a new GPS actor or integrated into AppModel setup
- ContentView needs 'Start Day' / 'End Day' controls (replaces or augments existing session buttons)

</code_context>

<specifics>
## Specific Ideas

- The debug HUD should show hysteresis progress visually (e.g., a progress bar filling toward threshold) so on-mountain testing can validate timing
- "Automotive" CMMotionActivity is the key chairlift signal — noted in STATE.md as a logical heuristic, not Apple-documented; treat as hypothesis requiring on-mountain validation
- CMMotionActivityManager is separate from CMMotionManager — needs its own query path

</specifics>

<deferred>
## Deferred Ideas

- Manual run splitting / bookmark drops — v2 feature if classifier misses boundaries in real-world testing
- Auto-end session after prolonged inactivity — considered and deferred; user prefers explicit End Day
- On-mountain test harness / labeling pass for filter and hysteresis calibration — Phase 4 (Field Validation)

</deferred>

---

*Phase: 02-activity-detection-run-management*
*Context gathered: 2026-03-09*
