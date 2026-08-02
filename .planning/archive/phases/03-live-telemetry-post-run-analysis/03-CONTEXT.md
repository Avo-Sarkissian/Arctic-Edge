# Phase 3: Live Telemetry & Post-Run Analysis - Context

**Gathered:** 2026-03-10
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 3 delivers three new screens that surface the data the pipeline already captures: a Live Telemetry view (during an active run), a Post-Run Analysis view (immediately after a run ends and accessible from history), and a Run History browser (full season, grouped by day). ContentView remains the session control home. No new sensor capture logic — all data comes from StreamBroadcaster (live) and SwiftData (post-run / history).

</domain>

<decisions>
## Implementation Decisions

### Navigation model
- Tab bar with two tabs: **Today** (ContentView + live telemetry) and **History** (run browser)
- Live Telemetry appears automatically — when the classifier transitions to `.skiing` (run starts), the live view comes up without any user tap
- Live view presents over or within the Today tab context; dismisses when run ends (classifier transitions out of `.skiing`)
- History is a persistent dedicated tab — accessible from anywhere, always one tap away

### Live waveform layout
- Waveform is the hero: takes ~60–70% of screen height (full-bleed feel)
- Metric cards (pitch, roll, g-force, GPS speed) float as a HUD overlay on the lower portion of the waveform — instrument-panel style, not below the waveform
- Right-side fixed cursor line marks "now" — waveform scrolls left into it (classic oscilloscope/EKG)
- Time window: ~10 seconds visible at once (matches ring buffer; shows a full carving rhythm)
- Arctic Dark: waveform line on dark background, metric card values in white/blue against ultraThinMaterial

### Post-run trigger + layout
- Post-run analysis sheet auto-presents the moment a run ends (classifier fires `.skiing` → `.chairlift` or `.idle` transition)
- Screen hierarchy: stats summary at top (top speed, avg speed, vertical drop, duration, distance), time-series charts below
- Segmented waveform replay (ANLYS-04): scrubber interaction — tap or drag on the chart to show a metric snapshot (pitch, roll, g-force, speed) at that exact timestamp
- Session aggregates (ANLYS-03) appear in the post-run view alongside per-run stats — user sees both "this run" and "today so far" context in one place
- Post-run view is also the destination when tapping a run in history (same PostRunAnalysisView, same layout)

### Run history browser
- Compact rows: each run entry shows run number, top speed, vertical drop, and duration — scannable at a glance
- Day headers show: date + resort name (CoreLocation reverse geocode) + day totals (run count + total vertical) — e.g. "March 9 — Whistler Blackcomb — 8 runs, 4,200m"
- No per-run sparklines or visual bars — text only, consistent with Arctic Dark high signal-to-noise philosophy
- Tapping a run navigates to PostRunAnalysisView — transition style (push vs sheet) at Claude's discretion based on chosen navigation model

### Claude's Discretion
- Navigation transition from history row to PostRunAnalysisView (push vs sheet vs fullScreenCover)
- Waveform signal color (single accent color vs multi-signal coloring)
- Exact metric card sizing and position within the HUD overlay
- Loading skeleton / empty state design for history list
- How Live Telemetry view presents within the Today tab (full-screen cover, NavigationStack push, or ZStack overlay)
- Chart type selection for post-run (Swift Charts `LineMark` for time-series; layout details)
- How RunRecord schema is extended to persist vertical drop and distance (needed for ANLYS-02, ANLYS-03, HIST-02)

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- `StatCard` (ContentView.swift): frosted glass rounded rect with `ultraThinMaterial` + white 0.07 border stroke — reuse directly for metric HUD cards in live view
- `ContentView` background layers (`backgroundLayer`, `topoOverlay`): same gradient + topo texture should carry through live and post-run screens for visual continuity
- `StreamBroadcaster.makeStream()`: LiveViewModel subscribes here for live `FilteredFrame` — no second CMMotionManager start needed
- `PersistenceService` + `FetchDescriptor`: SwiftData queries for post-run frames and history list pagination (HIST-01 lazy loading)
- `AppModel.isDayActive`, `classifierStateLabel`, HUD polling pattern: live view can piggyback on existing 10Hz polling rather than re-implementing

### Established Patterns
- `@Observable` + `@MainActor` class pattern (AppModel): LiveViewModel and PostRunViewModel should follow same pattern
- HUD polling (`Task { @MainActor [weak self] }` at 10Hz): LiveViewModel bridges actor state to `@Observable` the same way AppModel does for the debug HUD
- `#if DEBUG` compilation guard: keep ClassifierDebugHUD overlay pattern for any new debug-only views
- SWIFT_STRICT_CONCURRENCY = complete: all new ViewModels and data types must be Sendable-clean
- Swift Testing (`import Testing`): ViewModel logic (stat computation, history grouping, scrubber math) needs tests — no XCTest

### Integration Points
- `AppModel` is the source of truth for session state — LiveViewModel and the tab bar both read `appModel.isDayActive` to know when to show live view
- `ActivityClassifier` fires run start/end — AppModel (or a new notification mechanism) needs to signal PostRunAnalysisView to auto-present
- `RunRecord` currently stores only `runID`, `startTimestamp`, `endTimestamp`, `isOrphaned` — Phase 3 needs to add `topSpeed`, `avgSpeed`, `verticalDrop`, `distanceMeters` for ANLYS-02 / HIST-02
- `FrameRecord` has all signals needed for charts: `pitch`, `roll`, `filteredAccelZ` (carve pressure), plus GPS speed must be associated — may need a `GPSRecord` or attaching speed to `FrameRecord`/`RunRecord`
- Tab bar root is a new structural change — ArcticEdgeApp.swift WindowGroup currently puts ContentView directly; Phase 3 wraps it in a TabView

</code_context>

<specifics>
## Specific Ideas

- Live view should feel like looking at a vital-signs monitor on the mountain — waveform is always moving, HUD cards give instant glanceable values, nothing requires interaction
- Post-run auto-sheet should feel like Garmin/Strava's end-of-workout summary — natural reward after completing a run, no hunting through menus
- History day headers with resort name from reverse geocode are important — the user wants to know "where I was" not just "when"
- The 10-second waveform window is tied to the existing ring buffer depth — keeps live data source and display in sync

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 03-live-telemetry-post-run-analysis*
*Context gathered: 2026-03-10*
