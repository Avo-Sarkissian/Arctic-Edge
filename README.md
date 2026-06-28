# ArcticEdge

A high performance ski carving telemetry app for iPhone 16 Pro. ArcticEdge captures downhill carving dynamics from a 100 Hz IMU stream, automatically distinguishes skiing from chairlift rides, and gives real time feedback during runs plus detailed analysis after each run. The phone is carried in a pocket, with no extra hardware.

## What it does

- **Automatic run segmentation:** fuses GPS speed, g force variance, and motion activity to record each ski run as a clean segment, ignoring chairlift rides.
- **Live telemetry:** a scrolling carve pressure waveform and frosted glass metric cards during the run.
- **Post run analysis:** speed, g force, and carve pressure charts with a scrubber, plus per run and per day stats.
- **Run history:** browsable by day, with resort names from reverse geocoding.
- **Carving score (in progress):** a single 0 to 100 quality score per run. See [docs/CARVING-SCORE.md](docs/CARVING-SCORE.md).

## Tech

Swift 6 (strict concurrency complete), SwiftUI, SwiftData, CoreMotion, CoreLocation, HealthKit, Accelerate, Swift Charts. iOS 18+. Zero third party dependencies. Tests use Swift Testing.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): current system map, data pipeline, source layout, known issues.
- [docs/CARVING-SCORE.md](docs/CARVING-SCORE.md): the carving score design spec and implementation plan.
- [docs/RESEARCH.md](docs/RESEARCH.md): the research synthesis and source list behind the score.
- [CLAUDE.md](CLAUDE.md): working guidelines for this repo.
- `.planning/`: historical build record (phases 1 to 4), reference only.

## Build

Open `ArcticEdge.xcodeproj` in Xcode and run on an iPhone 16 Pro (simulator or device). The project uses Xcode synchronized folders, so new source files are picked up automatically.

Command line compile check:

```
xcodebuild build -scheme ArcticEdge -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```
