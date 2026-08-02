# ArcticEdge

A ski carving telemetry app for iPhone. ArcticEdge captures downhill carving dynamics from a 100 Hz IMU stream, automatically distinguishes skiing from chairlift rides, and gives live feedback during runs plus a scored analysis after each one. The phone rides in a pocket, with no extra hardware.

## What it does

- **Automatic run segmentation:** fuses GPS speed, g force variance, and motion activity to record each ski run as a clean segment, ignoring chairlift rides. No buttons on the mountain.
- **Carving score:** a single 0 to 100 quality score per run, computed and stored for every run at the moment it ends. Three pillars: control and smoothness, rhythm and symmetry, and carving intensity. See [docs/CARVING-SCORE.md](docs/CARVING-SCORE.md).
- **Turn ledger:** the run's turns drawn at the time they happened, left above the line and right below, so cadence and left-right balance are visible directly rather than only as a number.
- **Live telemetry:** gravity referenced vertical load, g force, and speed, at 120 fps.
- **Post run analysis:** charts with a scrubber, per run stats, and the day so far.
- **Run history:** browsable by day, with a score badge per run, day averages, and resort names from reverse geocoding.

## What it will not claim

A single phone in a pocket cannot measure everything a skier might want, and the app is built to say so rather than to guess:

- No **edge angle**, and no per ski metrics like edge similarity or outside ski pressure. Those need a sensor on each boot.
- **Vertical drop** comes from the barometer or it is shown as a dash. Phone pitch is not slope angle.
- Any metric that was not measured renders as a dash, never as a zero.
- A run below the minimum data gate says so, and says which gate it missed, instead of showing a number.
- The absolute score is labelled **provisional**: its scale comes from published research rather than from labelled skiing. Use it to compare your own runs. Exporting runs from Settings is what will eventually move it.

## Tech

Swift 6 (strict concurrency complete), SwiftUI, SwiftData, CoreMotion, CoreLocation, HealthKit, MapKit, Accelerate, Swift Charts. iOS 26.2+, iPhone only. Zero third party dependencies. Tests use Swift Testing.

The deployment target is deliberately recent: the app uses current APIs such as `MKReverseGeocodingRequest` rather than their deprecated predecessors. Lowering it is possible but means reverting those, which is a reach-versus-correctness tradeoff worth making consciously.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): system map, data pipeline, source layout, open issues.
- [docs/CARVING-SCORE.md](docs/CARVING-SCORE.md): the carving score design of record.
- [docs/RESEARCH.md](docs/RESEARCH.md): the research synthesis and source list behind the score.
- [docs/AUDIT.md](docs/AUDIT.md): the 2026-07 ski-metric audit that drove the current round of work.
- [CLAUDE.md](CLAUDE.md): working guidelines for this repo, including the honesty rules above.
- `.planning/`: historical build record (phases 1 to 4), reference only.

## Build

Open `ArcticEdge.xcodeproj` in Xcode and run on an iPhone (simulator or device). The project uses Xcode synchronized folders, so new source files are picked up automatically.

Command line compile check, no simulator needed:

```bash
xcodebuild build -scheme ArcticEdge -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Unit tests:

```bash
xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:ArcticEdgeTests
```

UI tests (slower: each case relaunches the app):

```bash
xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:ArcticEdgeUITests
```

CI runs all three on every push (`.github/workflows/ci.yml`) and fails on new build warnings.

## Status

Feature complete and warning free, but **not yet validated on snow**. Background capture, chairlift versus surface lift classification, cold weather battery behaviour, and the score's anchors all need a real ski day before any of them should be trusted.
