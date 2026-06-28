# ArcticEdge Architecture (Current State)

**Captured:** 2026-06-28, from a full codebase analysis.

ArcticEdge is an iPhone ski telemetry app (iOS 18+, iPhone 16 Pro target). It captures a 100 Hz IMU stream, auto segments skiing from chairlift rides, and presents live and post run analysis. All four original build phases are complete. The code is disciplined Swift 6 strict concurrency throughout (actors plus AsyncStream, no Combine), with roughly 62 Swift Testing cases.

## Data pipeline

```
CMDeviceMotion (100 Hz, background queue)
  -> MotionManager (actor): extract primitives, high pass filter userAccel.z, build FilteredFrame
       -> RingBuffer (actor): last ~10 s, drop oldest, synchronous atomic drain
       -> StreamBroadcaster (actor): fan out to N AsyncStream consumers
            -> LiveViewModel (live waveform + metric tiles)
            -> ActivityClassifier (ski vs chairlift segmentation)
  -> PersistenceService (@ModelActor): batched SwiftData writes (>= 200 frames / 2 s), GPS stamped at flush
```

Run lifecycle: `ActivityClassifier` is a hysteresis state machine (idle / chairlift / skiing) fusing GPS speed, g force variance, and `CMMotionActivity`. A confirmed skiing onset creates a `RunRecord`; a confirmed end finalizes it. `WorkoutSessionManager` holds an `HKWorkoutSession` for background CPU budget and crash recovery via a UserDefaults sentinel.

## Captured signal (per FrameRecord, the raw material for any score)

attitude pitch/roll/yaw (rad), userAccel x/y/z (g), gravity x/y/z (g), rotationRate x/y/z (rad/s), filteredAccelZ (high pass of raw userAccel.z), gpsSpeed (m/s, optional, stamped ~1 Hz, sparser in Power Saver), timestamp, runID.

## Source layout (`ArcticEdge/`)

| Folder | Responsibility |
|--------|----------------|
| `Motion/` | Sensor capture, high pass filter, ring buffer, stream fan out |
| `Activity/` | Ski vs chairlift classifier, motion activity bridge |
| `Location/` | GPS manager (CLLocationUpdate live updates) |
| `Session/` | HKWorkoutSession lifecycle, SwiftData persistence actor |
| `Schema/` | SwiftData models (FrameRecord, RunRecord) and Sendable snapshots |
| `Live/` | Live telemetry dashboard (Canvas + TimelineView) |
| `PostRun/` | Post run analysis (Swift Charts) and stats computation |
| `History/` | Paginated run history, day grouping, resort geocoding |
| `Today/` | Today tab shell, session controls |
| `Diagnostics/` | CalibrationExporter, MetricKit subscriber |
| `Debug/` | Classifier debug HUD (DEBUG only) |
| `Scoring/` | Carving score engine (new, see CARVING-SCORE.md) |

The Xcode project uses synchronized folder groups: any `.swift` file under `ArcticEdge/`, `ArcticEdgeTests/`, or `ArcticEdgeUITests/` is auto included in its target. No `project.pbxproj` edits are needed to add files.

## Strengths

- Clean layering: thin views, `@Observable @MainActor` view models, `@ModelActor` persistence, sensor logic in actors.
- Sendable value types (`FilteredFrame`, `FrameSnapshot`, `RunSnapshot`) at every actor boundary.
- Good test coverage on motion, classification, persistence, and view models.
- Consistent Arctic Dark styling.

## Known issues (detail in CARVING-SCORE.md section 5)

Fixed in the carving score work:

1. **Per run frame tagging (FIXED, verify on device).** `MotionManager.ingest` now stamps the active run id, pushed from the classifier via the AppModel HUD poll. `FrameRecord.runID` matches `RunRecord.runID`. Known limitation: ~3 s onset window not tagged.
2. **CalibrationExporter gyro/gravity (FIXED).** `FrameSnapshot`, `CalibrationFrame`, and the persistence projection now carry gravity and rotationRate. Exporter still has no UI trigger.

Still open:

3. **`filteredAccelZ` is the wrong axis** (raw device frame, not gravity vertical) and its filter cutoff drifts when the sample rate throttles (the biquad is built once at 100 Hz and never rebuilt). The carving score sidesteps this (it recomputes vertical from raw `userAccel` on gravity), but the live waveform still uses `filteredAccelZ`. Fix separately.
4. **No shared theme tokens**: accent colors and the slate gradient are re declared across about six view files. Extract a theme module during the UI pass (see UI-HANDOFF.md).
5. **Diagnostics has no test coverage** (CalibrationExporter, MetricKitSubscriber).
6. **`ContentView` stats row is a dead placeholder** (RUNS / DISTANCE / ELAPSED render as dashes): a ready slot for a day level carving score.
7. **verticalDrop uses phone pitch as a slope proxy** (flagged as a calibration concern), so vertical and distance are rough estimates.
