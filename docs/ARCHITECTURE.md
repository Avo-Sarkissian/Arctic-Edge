# ArcticEdge Architecture (Current State)

**Captured:** 2026-06-28. **Updated:** 2026-08-01 after the capture, data spine, metric honesty, UI, and calibration passes.

ArcticEdge is an iPhone ski telemetry app (iOS 18+, iPhone 16 Pro target). It captures a 100 Hz IMU stream, auto segments skiing from chairlift rides, and presents live and post run analysis. All four original build phases are complete, and the carving score engine (`Scoring/`) is built, tested, and wired through to persistence. The code is disciplined Swift 6 strict concurrency throughout (actors plus AsyncStream, no Combine), with roughly 80 Swift Testing cases (about 25 covering the scoring engine).

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

## Known issues

Resolved in the 2026-08-01 passes:

1. **Background capture.** `UIBackgroundModes = location` is declared and `LocationAuthorization` requests when-in-use before GPS starts. Still needs on-device confirmation with the screen locked.
2. **Clock domain.** Run start is wall clock, matching the end stamp. `UptimeClock` bridges CMDeviceMotion uptime to dates.
3. **Ordered ingest.** Samples arrive on a serial queue through one AsyncStream, drained by a single task, so the biquad sees them in order. The filter is rebuilt when the rate throttles.
4. **Score and stats coverage.** `RunFinalizer` scores and stats every run at finalization, independent of any view.
5. **Metric honesty.** The live and post run channel is gravity projected vertical load, not device frame z. Vertical drop is barometric or nil. Speed is accuracy gated and reported at the 95th percentile.
6. **Theme tokens.** `Support/Theme.swift` is the single source; views no longer carry literals.
7. **Dead features.** Resort geocoding, orphan run recovery, and calibration export all have callers now.
8. **Retention.** Raw frames expire after 30 days and orphaned frames are dropped; runs and scores are kept.

## Open limitations

These are known and unfixed. They are listed so nobody has to rediscover them.

**1. Nothing is validated on snow.** Every claim in this document is verified in a simulator. Background capture with the screen locked, run segmentation against real chairlifts, and battery behaviour in the cold are all unproven. See [FIELD-VALIDATION.md](FIELD-VALIDATION.md) for the protocol that would settle it.

**2. The score's absolute scale is provisional.** `CarvingScoreModel.v1` anchors come from published research ranges, not from labelled skiing. The version string carries a `-provisional` suffix and the UI shows it. Use the score to compare your own runs, not as a grade. Export from Settings is the path to fixing it.

**3. Scores are not comparable between people or devices.** There is no per-device or per-pocket normalisation. A phone in a snug pants pocket and one in a loose jacket pocket see different signal amplitudes from identical skiing. Gravity projection makes the channels orientation-robust, which handles *rotation*, but not differences in coupling, damping, or how much the phone moves independently of the skier. Until that is characterised, treat cross-user comparison as meaningless. This is the main thing standing between the current app and any leaderboard or sharing feature.

**4. Surface lifts are unclassified.** The classifier's chairlift detection leans on `CMMotionActivity` reporting automotive. A T-bar or poma drags a standing rider on skis: moderate speed, real IMU variance, and possibly no automotive signal. That can inject a phantom uphill run. Unproven either way.

**5. Air time and re-pocketing corrupt their windows.** Gravity projection assumes a valid gravity estimate. During a jump, CoreMotion's gravity direction degrades and every projected channel is meaningless for that window. Pulling the phone out mid-run and putting it back produces a large transient that the smoothness and chatter metrics will read as terrible technique. Neither case is detected or excluded.

**6. GPS speed is one scalar per flush batch.** `flushWithGPS` stamps a single fix onto every frame in the batch, so at 100 Hz that is one speed value across roughly two seconds. Accuracy gating now rejects bad fixes, but the temporal resolution of the speed channel is still much coarser than the metrics that consume it.

**7. The UI test suite is quarantined and the reason is not understood.** All eight cases have passed on CI, and one real bug was caught by them (a `confirmationDialog` attached to a `Section` rather than the `Form`, so the confirmation guarding "delete every run" could fail to present). But one or two cases intermittently time out with "process main thread busy for 30.0s", always whichever runs first in a class, occasionally taking over 600 seconds before giving up. What is ruled out: it is not SwiftData store creation, since a measured cold launch after a fresh install reaches the same point in ~1.5s as a warm one; and it is not simply a bad runner, since it recurs across runners and machines and survives retries. What is not ruled out: something in the app keeps the main run loop from going idle for accessibility snapshotting under specific first-launch conditions. Until this is understood, the suite runs non-blocking in CI and build plus 143 unit tests are the gate. A case that fails consistently across runs should be treated as real, not as this.

**8. Cold shutdown is not modelled.** Power Saver is a battery-percentage threshold plus a thermal throttle. iPhones can shut down abruptly in the cold at a nominally healthy charge. There is no cold-specific behaviour and no "the phone died mid-run" recovery beyond generic orphan handling.
