# Carving Score Research Synthesis

**Date:** 2026-06-28. Four parallel web research streams plus an adversarial computability review. This is the evidence base for [CARVING-SCORE.md](CARVING-SCORE.md).

## Key conclusions

1. **Carved vs skidded turn (the core distinction).** In a carved turn the ski tracks on edge so the tail follows the tip (a clean line), lateral sliding is near zero, friction is low, and speed is preserved. A skidded turn slides sideways, scrubs speed, and chatters. For a pocket IMU this maps to low yaw rate scrubbing, smooth single peak force and rotation profiles, and maintained speed.

2. **Pocket phone vs boot sensor (the hard limit).** Boot and insole systems (Carv: 36 pressure sensors plus an IMU per boot) measure true per ski edge angle, plantar pressure, and outside vs inside ski loading. A single pocket phone cannot. It measures body and hip motion. Body lean correlates with but is not equal to ski edge angle (skiers angulate at hip and knee). Per ski metrics are impossible with one IMU. What a pocket phone can recover: turn rhythm, rotational and translational smoothness, whole body turn G magnitude, left vs right turn symmetry, and (with GPS) coarse carve vs skid purity.

3. **Orientation invariance is mandatory.** Raw per axis accel and gyro are unreliable at most body locations; published pocket and thigh studies rotate signals into a gravity aligned or skier fixed frame before any peak or zero crossing logic. The gravity vector is the robust anchor. This is the single biggest correctness factor for a pocket app.

4. **Top validated discriminators that a pocket phone can use.**
   - Turn segmentation from low pass (about 0.5 Hz) roll or yaw rate zero crossings; turns gated to roughly 0.3 to 5.0 s. Short carved turns about 1 s, long about 3 s.
   - Speed and gyroscope statistics separate carve from skid (gradient boosted trees reached 95.3 percent on boot data): max speed per turn, std dev of yaw axis angular velocity (lower for carving), max roll axis angular velocity.
   - Carving is measurably smoother (lower jerk) than skidded turns. Use LDLJ-A (log dimensionless jerk on acceleration) for translation and SPARC on gyroscope magnitude for rotation; both avoid the integration drift that breaks velocity reconstructed smoothness metrics.
   - Lateral or centripetal acceleration is the strongest single carve quality proxy and correlates closely with Carv Ski:IQ. Estimate it two ways and cross check: gravity removed horizontal accel, and `v * yaw_rate`. Divergence indicates skidding.

5. **Commercial benchmark (Carv Ski:IQ).** A single 0 to 200 score that is a weighted average of about 10 to 12 sub metrics grouped into four skill areas (Balance, Edging, Rotary, Pressure). Weights are context aware (ability, slope pitch, snow). Carv deliberately keeps the metric set small and non redundant and removes confusing or overlapping metrics between seasons. Lessons adopted: headline number plus drill down pillars, small non redundant metric set, frozen and versioned weights, terrain awareness as a future refinement.

6. **Composite score methodology (OECD handbook and sports science).** Winsorize noisy sub metrics before normalizing; prefer percentile or saturating min max for a bounded outlier robust 0 to 100; use geometric aggregation across pillars to limit gameability; handle missing data by re normalizing weights rather than imputing zero; freeze weights and anchors across releases for run to run comparability; validate against labeled data rather than assuming correctness.

## Adversarial computability review (against the exact captured fields)

The reviewer confirmed which proposed metrics survive a pocket phone, and surfaced two additional code issues now recorded in CARVING-SCORE.md section 5 (wrong filter axis plus drifting cutoff; CalibrationExporter missing gyro and gravity). The resulting three pillar model uses only gravity projected, gyro about gravity, magnitude, and timing based metrics for the GPS free core (pillars A and B), with GPS dependent intensity metrics quarantined into a capped pillar C.

## Primary sources

Biomechanics and coaching:
- getcarv.com/blog/how-to-carve-on-skis
- toptierskiing.com/advanced-skiing-10-key-tips-to-help-you-achieve-higher-edge-angles
- skiracing.com/edge-angle-a-crucial-concept-for-fast-ski-racing
- skierlab.com/science-friction-formula/skill-development/turn-phases
- skimag.com/performance/instruction/how-to-carve

Peer reviewed IMU and turn analysis:
- PMC7435691 (carve vs drift classification, GNSS plus IMU, 95.3 percent)
- PMC7739568 (gyroscope roll rate turn detection, 0.5 Hz decision signal)
- PMC9371385 (smartphone thigh pocket alpine skiing recognition)
- PMC12031278 (orientation invariant sensing, Skier Fixed Reference Frame)
- PMC8199039 (Connected Skiing motion quality, jerk and smoothness)
- PMC8038258 (low drift on ski IMU, AHRS quaternion fusion)
- arXiv physics/0310086 (the ideal carving equation, R = Rsc / cos(angle))

Commercial benchmarks:
- getcarv.com/blog/skiiq, getcarv.com/analysis, getcarv.com/blog/skiiq-24-nevado
- getcarv.com/blog/how-carv-turns-your-skiing-into-data
- getcarv.com/blog/introducing-g-force

Composite score methodology:
- OECD Handbook on Constructing Composite Indicators (Nardo et al.)
- Frontiers fbioe 2020.558771 and PubMed 33520949 (LDLJ-A and SPARC for IMU smoothness)
- en.wikipedia.org/wiki/Winsorizing
