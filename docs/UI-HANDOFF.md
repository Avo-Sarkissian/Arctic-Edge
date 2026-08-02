# Carving Score UI Handoff (DELIVERED 2026-08-01)

> **Status: complete.** This brief was executed. The score is live on the post run
> screen, in history rows and day headers, and on the Today tab. Theme tokens were
> extracted to `ArcticEdge/Support/Theme.swift` first, as the brief asked.
>
> What was built beyond the brief:
> - **Turn ledger.** The brief did not specify a visual treatment beyond "one large
>   calm number". The chosen signature is a ledger of the run's actual turns, drawn
>   at the time each happened, left above the centreline and right below, width
>   from real duration. Even spacing is measured cadence and a balanced split is
>   measured symmetry: the same two quantities the Rhythm pillar scores. A circular
>   progress ring was rejected as saying nothing about skiing.
> - **Day aggregate.** `AppModel.daySummary` averages today's scored runs, filling
>   the dead ContentView stats row the brief flagged.
> - **Shortfall copy.** The "not enough data" state names the gate the run missed
>   rather than stating the fact alone.
> - **Score bands** use a cold ramp (slate, arctic, glacier, lit snow) instead of
>   red to green. A skier working on technique is not in a failure state.
>
> The section below is the original brief, kept for the record.

---

# Carving Score UI Handoff

The carving score engine is built, tested, and wired into the data model. This is the brief for the UI pass (the Claude design step): what data is available, where to surface it, the theme work to do first, and the honesty rules that constrain the copy.

## What exists (no more engine work needed to start the UI)

- `CarvingScorer.score(frames:)` returns a `CarvingScore` (see `ArcticEdge/Scoring/CarvingScore.swift`):
  - `overall: Double?` (0...100, nil when below the data gate)
  - `pillars: PillarScores` (`controlSmoothness`, `rhythmSymmetry`, `carvingIntensity`, each `Double?` 0...100)
  - `subMetrics: [SubMetricValue]` (`id`, `label`, `normalized` 0...100, `raw`) for drill down
  - `turnCount: Int`
  - `dataQuality: DataQuality` (`turnCount`, `durationSeconds`, `medianSampleRate`, `gpsCoverage`, `sufficientData`)
  - `modelVersion: String`
- `PostRunViewModel.carvingScore: CarvingScore?` is populated on `loadData(...)`. The post run view can read it directly.
- `RunRecord.carvingScore` / `RunSnapshot.carvingScore` are persisted, so history can show a per run number without recomputing.

## Surfaces to design (priority order)

1. **Post run analysis (`PostRunAnalysisView`):** the primary home. A hero score block (one large numeral, calm), then the three pillars, then sub metric drill down. The view model already exposes `carvingScore`.
2. **Today tab (`ContentView`):** the stats row currently renders dead placeholders (RUNS / DISTANCE / ELAPSED as dashes). A latest run or day level carving score card fits here. Note: a day level aggregate score is not yet computed; either show the latest run's score or add a simple aggregate (average of the day's run scores) in `PostRunViewModel`/AppModel.
3. **History (`RunHistoryView`):** a per run score badge on each row, and optionally a day average in the section header. `RunSnapshot.carvingScore` is available; `HistoryViewModel.RunRow` would need the field threaded through.
4. **Live (`LiveTelemetryView`):** OPTIONAL and out of v1 engine scope. A live score needs a streaming scorer (the current engine is per run, post hoc). Do not promise a live score until that exists.

## Do this first: extract a theme module

Accent colors and the slate gradient are re declared across about six view files (arctic blue `Color(red: 0.12, green: 0.56, blue: 1.0)`, mint, amber, the slate gradient stops). Before adding score visuals, extract a single `Theme` (colors, gradients, typography tokens, the frosted card style) so the new surfaces stay on palette and the existing screens can adopt it. This is the highest leverage UI cleanup.

## Arctic Dark constraints (from CLAUDE.md)

Deep slate / near black backgrounds; `ultraThinMaterial` / `regularMaterial` frosted surfaces; SF Pro with tight tracking; monospaced digits for numbers; high signal to noise. The score should read as one large, quiet number with restrained supporting detail, not a busy dashboard.

## Honesty rules (must hold in copy)

- Label the absolute score **provisional** (the model version is `*-provisional` until anchors are recalibrated from real runs). Consider a small "provisional" tag near the number.
- Never call a body lean proxy "edge angle." Use "lean" or "inclination."
- Never present per ski metrics (edge similarity, outside ski pressure). A single pocket phone cannot measure them.
- When `overall == nil` (or `dataQuality.sufficientData == false`), show a clear "not enough data for a score" state, not a zero.
- Sub metric labels are already user friendly (`Edge Smoothness`, `Rhythm`, `Symmetry`, `Carve Purity`, etc.). Carving Intensity (pillar C) is nil when GPS was unavailable; design for that.

## Suggested (provisional) score bands

Purely for color/label treatment, clearly provisional until calibrated: under 40 developing, 40 to 60 solid, 60 to 80 strong, 80 plus expert. Do not present these as authoritative.
