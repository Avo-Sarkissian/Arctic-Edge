# ArcticEdge Carving Score: Design Spec

**Status:** Approved design, engine-first build in progress
**Date:** 2026-06-28
**Decision:** Hybrid scale (provisional absolute 0 to 100 plus personal trend), engine built and tested before UI handoff to Claude design.

This document is the design of record for CRVG-01: a single 0 to 100 carving quality score per run. It is grounded in a codebase analysis and a four-stream research pass (biomechanics, IMU turn detection, commercial benchmarks, composite-score methodology) plus an adversarial computability review. Sources are listed in [RESEARCH.md](RESEARCH.md).

---

## 1. The governing constraint: a pocket-worn phone is not a boot sensor

ArcticEdge captures motion from an iPhone carried in a pocket (thigh or hip), not a sensor bolted to the boot like Carv. This single fact decides what the score can honestly measure:

- Phone attitude reflects body and pocket orientation, not ski edge angle. The pocket pose is arbitrary and can shift mid run.
- There is no per ski data (one IMU, not one per boot), so per ski edge angle, plantar pressure, and outside vs inside ski weighting are impossible.
- The only per frame orientation anchor that is always trustworthy is the gravity vector.

Consequence: metrics that depend on true edge angle, fore aft balance, or edge roll rate are boot sensor fantasies in pocket mode. We do not ship them as if they were real. We score what survives a pocket phone.

### The linchpin: gravity projection

Every axis specific computation first projects device frame signals onto a gravity aligned frame, making them orientation robust. Per frame, with gravity vector `g`:

- `u = g / |g|` (unit vector pointing down)
- Vertical acceleration: `a_v = userAccel . u` (orientation robust scalar)
- Horizontal acceleration vector: `a_h = userAccel - (userAccel . u) u`, magnitude `|a_h|` (orientation robust in magnitude, not in azimuth)
- Yaw rate about vertical: `omega_v = rotationRate . u` (orientation robust turn rate)
- Total angular speed: `|omega| = |rotationRate|` (rotation invariant by construction)

This projection needs gravity and rotationRate only. It does not use attitude (the least trustworthy field in a pocket) and does not need GPS. What it cannot do: split the horizontal plane into "lateral vs fore aft" without a heading reference, which we do not have. That limitation is why several research proposed metrics are rejected below.

---

## 2. What is computable (the metric cull)

From the adversarial computability review of the exact captured fields. "Robust" means orientation robust and computable from captured data on a pocket phone.

### Keep (robust, no GPS needed)
- Turn segmentation from low pass `omega_v` zero crossings (foundation for everything else)
- Yaw rate smoothness (single peak, low std `omega_v` profile per turn)
- Edge transition smoothness: SPARC on `|rotationRate|` per turn
- Linkage smoothness: LDLJ-A (log dimensionless jerk) on gravity vertical `a_v`
- Chatter penalty: RMS of high frequency energy on re filtered `a_v`
- Cadence regularity: coefficient of variation of turn durations
- Left/right turn symmetry: group turns by sign of `omega_v`, compare per turn metrics
- Transition cleanness: duration of the low energy window between turns

### Keep but quarantine (real, but GPS gated and calibration sensitive)
- Carve purity: agreement between measured `|a_h|` and `v * omega_v`; divergence indicates skidding
- Turn shape consistency: winsorized stability of `R = v / omega_v`
- Speed retention: GPS entry vs exit speed (display as context, not folded into the score; too sparse to be fair per turn)

### Reject (no orientation robust axis exists in pocket mode)
- Edge roll rate (no known roll axis in a pocket)
- Body lean as "edge angle" and edge build progressiveness (lean is not edge angle, and is confounded by centripetal force). Allowed only as a floor weighted, clearly labeled proxy, or omitted in v1.
- Fore aft stability (no fore aft axis without heading)

---

## 3. The score model

Carv style: one motivating headline number plus drill down sub metrics, grouped into a small number of non redundant pillars. Three pillars, with the fragile GPS dependent metrics quarantined into one capped pillar so they cannot dominate.

| Pillar | Weight (v1, frozen) | Sub-metrics | Needs GPS |
|--------|---------------------|-------------|-----------|
| **A. Control and Smoothness** | 0.45 | Edge transition SPARC, yaw rate smoothness, linkage jerk (LDLJ-A), chatter penalty | No |
| **B. Rhythm and Symmetry** | 0.30 | Cadence regularity, left/right symmetry, transition cleanness | No |
| **C. Carving Intensity** | 0.25 | Carve purity, turn shape consistency | Yes (gated) |

Pillars A and B work with zero GPS. That is what makes the score usable on a real mountain where GPS drops under chairlifts, trees, and in Power Saver mode.

### Aggregation
- Within a pillar: weighted arithmetic mean of normalized sub metrics (sub metrics within a pillar are correlated and partly substitutable).
- Across pillars: **geometric mean**. `Score = 100 * (A^wA * B^wB * C^wC)^(1 / sum(w))`. Geometric aggregation limits compensability: you cannot bury a terrible pillar under two good ones, so gaming the score by maxing one easy dimension (for example metronomic rhythm with zero carving) fails.

### Normalization (per sub metric)
- Winsorize each raw sub metric to its 5th and 95th percentile band (from the calibration corpus, not per run) so a single GPS glitch or pocket jolt cannot dominate.
- Saturating min max to [0, 1] against frozen calibration anchors (p5 maps to 0, p95 maps to 1), clamped. Preferred over per run percentile so a sloppy run cannot look good by being graded on its own curve.
- Orient so higher is better (invert penalties: chatter, CoV, skid residual).
- Per turn sub metrics aggregate to per run via trimmed mean (drop top and bottom 10 percent) to resist a few hero turns.

### Missing data and gates
- If a pillar or sub metric is unavailable (poor GPS, Power Saver, too few turns), drop it and re normalize the remaining weights to sum to 1. Never substitute 0; that would punish bad GPS, not bad skiing.
- Minimum data gate: require at least 8 valid turns and a minimum skiing duration before emitting any score. Below that, show "not enough data," not a misleading number.
- Spectral metrics (chatter, vertical release) only contribute from turns captured at 40 Hz or higher; otherwise dropped and the pillar re normalized.

### Hybrid scale (the chosen approach)
- Provisional absolute 0 to 100 using literature anchored, frozen bounds, labeled provisional in the UI until recalibrated.
- Personal trend overlay: an exponential moving average of the user's own run scores, so the number is motivating even before the absolute scale is validated.
- Recalibrate the anchors from real runs gathered via the CalibrationExporter; bump the score model version when anchors or weights change.

### Versioning
- A frozen `CarvingScoreModel` version pins: calibration anchors (p5/p95 per sub metric), pillar weights, gates, and the gravity projection and resampling spec.
- Every computed score stores its model version so historical runs stay comparable and re scoring is auditable. Anchors and weights change only with a version bump.

---

## 4. Preprocessing pipeline (applies before any pillar)

1. **Recover dt and resample.** Compute per frame dt from consecutive `timestamp` deltas (device uptime, monotonic). Resample every channel onto a fixed analysis grid (target 50 Hz, clamped to the run's achievable rate). Record the run's median true rate; flag turns whose frames were captured below 40 Hz for spectral metrics.
2. **Gravity projection.** Compute `a_v`, `|a_h|`, `omega_v`, `|omega|` per frame as in section 1.
3. **Re derive filtering from raw.** Do not consume the stored `filteredAccelZ` (it is the wrong axis and its cutoff drifts with throttle, see section 5). Apply zero lag (forward backward) Butterworth band pass on resampled `a_v` and `|userAccel|` with explicit, rate correct cutoffs.
4. **Segment turns.** Low pass `omega_v` at about 0.5 Hz (zero lag), detect zero crossings as edge changes, gate turns to a plausible duration band (roughly 0.3 to 5.0 s) and a minimum `|omega_v|` peak to reject straight line noise.
5. **GPS freshness gate.** Tag each turn with its GPS sample count and max gap; turns failing freshness contribute to GPS dependent metrics as missing, not zero.

---

## 5. Blocking bugs found during analysis (status)

1. **Per run frame tagging (FIXED, pending on-device verification).** Frames were stamped with a single day level UUID while `ActivityClassifier` minted a separate per run UUID for each `RunRecord`, so `fetchFrameDataForRun(runID:)` returned zero frames (this also broke post run charts). Fix: `MotionManager.ingest` now stamps the currently active run id, updated live via `MotionManager.setActiveRunID`. The AppModel HUD polling loop pushes the classifier's `currentRunID` into the motion pipeline on each run start (the run's id) and end (a throwaway id so lift frames do not pollute the run). Unit tested in `MotionManagerTests.testIngestUsesActiveRunID`. Known limitation: the ~3 s skiing onset window plus ~100 ms poll latency means the first few seconds of a run are not tagged with the run id, so a run's frame set starts shortly after true onset. A precise fix would have the classifier drive `setActiveRunID` directly from `confirmSkiingTransition`. Verify on device.

2. **`filteredAccelZ` is the wrong axis and the filter cutoff drifts (worked around in scoring; source bug remains).** `filteredAccelZ` is the high pass of raw device frame `userAccelZ`, not a gravity vertical, and the biquad is built once at 100 Hz and never rebuilt when the rate throttles. The carving score does NOT consume `filteredAccelZ`; it recomputes vertical from raw `userAccel` projected on gravity. The underlying `MotionManager` filter bug (used by the live waveform) is still open and should be fixed separately.

3. **CalibrationExporter gyro/gravity (FIXED).** `FrameSnapshot`, the exporter payload (`CalibrationFrame`), and the persistence projection now carry `gravityX/Y/Z` and `rotationRateX/Y/Z`, the signals the robust metrics need. The exporter still has no UI trigger; add one (a debug control or post-run hook) before a field calibration pass.

---

## 6. Implementation plan (engine first)

Built with test driven development using Swift Testing. New engine lives in `ArcticEdge/Scoring/` (auto included by the synchronized Xcode folder).

**Step B: Foundation fixes and schema**
- Fix run tagging (bug 1): thread per run runID into `StreamBroadcaster` / `MotionManager`.
- Extend `FrameSnapshot` with gravity and rotationRate; update `PersistenceService` projection.
- Extend `CalibrationExporter` payload with gyro and gravity; add an export trigger.
- Add `carvingScore: Double?` and a small sub score breakdown to `RunRecord` (Optional, no init change, lightweight migration only; do not wire a `SchemaMigrationPlan`, see analysis note).
- Mirror new fields in `RunSnapshot` and `RunStats`.

**Step C: Scoring engine (pure, tested)**
- Gravity projection helpers and a fixed grid resampler.
- Zero lag Butterworth (filtfilt) and turn segmentation.
- Sub metrics: SPARC, LDLJ-A, yaw rate smoothness, chatter, cadence CoV, symmetry, transition cleanness, carve purity, turn shape consistency.
- Normalization (winsorize plus saturating min max) and a versioned `CarvingScoreModel` config with frozen anchors and weights.
- Composite assembly (geometric mean across pillars, missing data re normalization, min data gate).
- Each piece gets a focused Swift Testing suite with synthetic signals (clean carve, skid, straight line) asserting expected ordering.

**Step D: Wire into post run and persist**
- `PostRunViewModel` computes the score from per run frames and persists it via a new persistence writer (mirroring `updateResortName`).
- Surface the score and pillars in `RunStats`, history `RunRow`, and session aggregates.

**Step E: UI handoff**
- With the engine producing real sub metrics and a 0 to 100 number, hand off to Claude design for the score surfaces plus extraction of a shared Arctic Dark theme system (accent tokens are currently duplicated across about six view files).

---

## 7. Honesty rules (do not violate in UI copy)

- Never label a body roll proxy as "edge angle." Call it lean or inclination.
- Never promise per ski metrics (edge similarity, outside ski pressure). They require a sensor per boot.
- Label the absolute score provisional until recalibrated from real runs.
- Show "not enough data" rather than a number when the minimum data gate is not met.
