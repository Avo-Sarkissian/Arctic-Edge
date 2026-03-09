# Feature Landscape

**Domain:** iOS skiing telemetry and performance tracking
**Researched:** 2026-03-08
**Confidence note:** WebSearch and WebFetch tools were unavailable during this session. All findings derive from training knowledge (cutoff August 2025) of the competitive landscape: Slopes, SkiTracks, Carv, Alpine Replay, and Ski Tracks Pro. Confidence levels reflect this.

---

## Table Stakes

Features users expect in any skiing tracking app. Missing = product feels incomplete and users leave for Slopes on day one.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Automatic run detection (skiing vs chairlift) | Core promise of every skiing app since SkiTracks. Manual start/stop is unacceptable on the mountain | High | Classification must be reliable in edge cases: gondola, T-bar, poma, magic carpet, traverses. False positives (chairlift labeled as run) destroy post-session stats. |
| Per-run stats summary | Speed (top, average), vertical drop, run duration, distance | Low | Users compare runs immediately after each descent. These must appear within 2-3 seconds of run end. |
| Session-level aggregate stats | Total vertical, total runs, total time skiing vs riding, total distance | Low | Shown on the day summary. Users screenshot and share. |
| Top speed display (live and recorded) | Every skiing app shows this. It is the most emotionally resonant single metric for skiers | Low | GPS-derived. Must be filtered -- GPS spikes produce false top speeds if unfiltered. |
| Speed over time graph | Baseline post-run visualization. Users expect to see the speed profile of each run | Medium | GPS at 1Hz is too coarse for meaningful intra-turn resolution. 100Hz IMU-derived speed proxy is a differentiator. |
| Persistent run history | All runs from all sessions, browsable by day | Medium | SwiftData or equivalent. Users want to compare today to last season. |
| Background sensor capture | App must keep recording when phone goes to sleep / screen locks | High | HKWorkoutSession is the correct mechanism for iOS background CPU budget. Without this, the app is useless the moment a user pockets their phone. |
| Battery efficiency during session | 4-8 hour ski days. Excessive drain is a 1-star review | High | 100Hz IMU is power-hungry. Sensor fusion pipeline design must account for this from day one. |
| Altitude / vertical tracking | Vertical feet per run and per day. Skiers set goals like "10,000 vertical feet today" | Low | Barometric altimeter (CMAltimeter) is more accurate than GPS altitude in mountains due to GDOP. |
| Mountain / resort identification | Users want their log to show which mountain they skied, not just coordinates | Low | Reverse geocode or resort database lookup. |

---

## Differentiators

Features that set a product apart. Not universally expected yet, but create loyalty and word-of-mouth among serious skiers.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| 100Hz IMU carve-pressure waveform | No competitor (including Carv hardware) shows raw edge-engagement dynamics in real time from an iPhone IMU alone. This is ArcticEdge's core identity | High | Requires the high-pass filter design (>2Hz pass, <0.5Hz reject) already specified in PROJECT.md. The waveform scrolls live during the run, not just post-run. |
| Live telemetry dashboard during run | Slopes shows live speed. No app shows live pitch, roll, and g-force with a scrolling waveform simultaneously | High | Requires ProMotion 120Hz display (iPhone 16 Pro target) to render fluidly at 100Hz data ingestion. Frosted glass metric cards alongside waveform is the ArcticEdge aesthetic lock-in. |
| Edge engagement classification per turn | Identify clean carve vs skid vs mixed technique from IMU data | Very High | Requires a classifier trained or heuristically defined on carving dynamics. Phase 2 or later. Carv hardware does this; ArcticEdge can approximate it with software alone. |
| Per-run segmented waveform replay | After a run, scroll back through the IMU waveform aligned to the speed profile. Click a spike to see that moment's g-force / pitch / roll | High | Requires time-aligned data storage. This is the "video replay for skiers" without a camera. |
| Carving quality score per run | Single number (0-100) summarizing carve purity for that run. Directly comparable run-to-run | Very High | Abstraction over the waveform. Needs robust scoring function calibrated to real skiing data. Flag as needing phase-specific research when tackling. |
| Automatic run start / end with zero latency | Most apps have a 2-5 second lag detecting run start/end from GPS. IMU can detect the transition from stationary to carving pressure in under 500ms | High | Hybrid detection: IMU for fast response, GPS for ground-truth confirmation. |
| Turn count and turn frequency analysis | How many turns per run, turns per vertical meter. Advanced users (racers, coaches) want this | High | Requires turn-segmentation in the waveform. Each carve pressure spike pair = one turn. |
| Thermal-aware sensor throttling | iPhone 16 Pro has the best thermal headroom of any iPhone, but sustained 100Hz capture will trigger thermal mitigation. Graceful degradation (100Hz -> 50Hz -> 25Hz) with user notification | Medium | This is a technical differentiator that users never see but that prevents app crashes. Competitors do not advertise this. |
| Slope gradient estimation per run segment | Steepness of the terrain at each point, derived from pitch sensor + speed | High | Useful context: "that aggressive carve spike happened on the 42-degree pitch at the top of the run." |

---

## Anti-Features

Features to explicitly NOT build in v1, and why. These are often the correct choice even if users occasionally request them.

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| Social sharing / leaderboards | Slopes and Strava already own this space. Competing here means building a social graph, moderation, and infrastructure that dilutes the telemetry focus | Provide export (GPX, CSV of waveform data) so users can share via Strava if they want |
| Real-time coaching / audio cues | Requires robust carving classifier trained on real data. Premature in v1 before scoring function is validated. False coaching is worse than no coaching | Build the waveform and scoring foundation in v1; coaching is a v2 overlay |
| Apple Watch standalone app | Adds Watch sensor pipeline, Watch UI, phone-watch sync complexity. Watch IMU is 50Hz max and lower quality than iPhone 16 Pro | Note as v2 path in PROJECT.md. HKWorkoutSession already creates the integration seam. |
| Trail / piste mapping overlays | Requires licensing or scraping resort maps. Legal and maintenance burden. GPS accuracy on mountain terrain is only ~5m, which makes trail attribution unreliable in tight tree runs | Show altitude profile and speed profile instead. Resort name via geocoding is sufficient. |
| Weather integration | Nice-to-have that many apps include. Adds API dependency, cost, and scope. Not related to the core carving telemetry value | Out of scope v1. Could be a one-line add later via WeatherKit (no third-party API needed on iOS). |
| Video recording or overlay | Camera + 100Hz IMU simultaneously is a thermal and battery problem. Video sync to sensor data adds significant complexity | The scrolling waveform IS the replay. Users do not need video if the data tells the story. |
| Subscription monetization | Forces feature gating decisions that compromise product integrity at launch. Premature before product-market fit is established | Build the core product first. Pricing model is a post-launch decision. |
| Mountain resort database | Maintaining a database of 2000+ resorts worldwide is a continuous data operations burden | Use CoreLocation reverse geocoding for mountain name. Good enough for v1. |

---

## Feature Dependencies

```
Background capture (HKWorkoutSession)
    --> All live telemetry features (cannot capture without background execution)
    --> All post-run analysis features (no data to analyze without capture)

100Hz IMU stream (MotionManager actor)
    --> High-pass carve-pressure filter
        --> Live scrolling waveform
        --> Per-run waveform storage
            --> Segmented waveform replay (post-run)
            --> Turn count / turn frequency
            --> Carving quality score

Activity auto-detection (skiing vs chairlift)
    --> Per-run stats (need clean run boundaries)
    --> Session aggregates (vertical, runs count)
    --> Per-run waveform segmentation

GPS + barometric altitude
    --> Speed profile (GPS-derived)
    --> Vertical drop per run
    --> Top speed (GPS, filtered)
    --> Slope gradient estimation

Per-run stats summary
    --> Run history / persistent storage (SwiftData)
        --> Session history browser

Live telemetry dashboard
    --> (no hard dependencies, but requires IMU stream + background capture first)
```

---

## MVP Recommendation

Prioritize (in order):

1. Background IMU capture at 100Hz with HKWorkoutSession -- the entire product is impossible without this
2. Activity auto-detection (skiing vs chairlift) -- run segmentation is the table-stakes behavior users judge in the first session
3. Per-run stats (speed, vertical, duration) -- required for the app to feel like it "worked"
4. Live telemetry dashboard (scrolling waveform + frosted glass metric cards) -- this is the visual identity and the differentiator that no competitor has; it must ship in v1 to establish the product
5. Post-run waveform replay per run -- deepens the value of the live dashboard; users will want to review what they saw live

Defer to v2 or later:

- Carving quality score: requires real-world data calibration before the scoring function is meaningful
- Turn count / turn frequency: useful but not load-bearing for first user session
- Edge engagement classification (carve vs skid vs mixed): needs a classifier; high research risk
- Slope gradient estimation: interesting context but not core to the carving story
- Apple Watch integration: already planned as v2 in PROJECT.md

---

## Competitive Context

**Slopes** (highest market share iOS skiing app as of 2025): GPS-based. Shows live speed, top speed, altitude, vertical. Post-run stats with map overlay. Resort detection. No IMU waveform, no pitch/roll/g-force. Background via background location.

**SkiTracks**: Similar to Slopes, GPS-dominant. Long-established, lower polish. Good chairlift detection via speed + altitude heuristics.

**Carv** (hardware insole + app): The only competitor doing real-time edge pressure data -- but requires $200+ hardware insoles. App shows balance, edge angle, pressure distribution. Limited to Carv hardware owners. ArcticEdge's positioning: Carv-class insight without the hardware.

**Alpine Replay**: Camera-based replay sync. Different category -- video-first rather than telemetry-first.

**Gap ArcticEdge fills**: No app delivers real-time IMU carving dynamics (pitch, roll, g-force waveform) from the iPhone itself, without additional hardware. That gap is the product.

---

## Phase-Specific Research Flags

| Phase Topic | Likely Needs Research | Reason |
|-------------|----------------------|--------|
| Activity auto-detection | Yes | Chairlift vs skiing classification edge cases (gondola, T-bar, magic carpet) require empirical testing with real data. Heuristic design is non-trivial. |
| Carving quality score | Yes | No established algorithm for this from iPhone IMU alone. Will need real skiing data and iteration. |
| Turn segmentation | Yes | Peak detection on a noisy 100Hz signal with variable terrain is an engineering research problem. |
| Thermal throttling policy | Maybe | iPhone 16 Pro thermal behavior at 100Hz sustained is not publicly documented. Need empirical measurement. |
| High-pass filter cutoffs | Maybe | The 2Hz / 0.5Hz cutoffs in PROJECT.md are biomechanically motivated but need real-data validation. |
| Background execution budget | No | HKWorkoutSession is well-documented; CPU budget behavior is known from HealthKit apps. |
| SwiftData persistence | No | Standard pattern; no unusual research needed. |

---

## Sources

- Training knowledge of Slopes, SkiTracks, Carv, and Alpine Replay apps (cutoff August 2025) -- MEDIUM confidence
- PROJECT.md biomechanical rationale for filter cutoffs (>2Hz carve, <0.5Hz body sway) -- HIGH confidence (project-defined)
- iOS HKWorkoutSession background execution behavior -- HIGH confidence (well-documented Apple API)
- WebSearch and WebFetch unavailable during this session -- findings not externally verified; validate against current App Store listings before finalizing
