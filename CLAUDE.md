# ArcticEdge: Claude Code Guidelines

ArcticEdge is an iPhone ski carving telemetry app: it captures a 100 Hz IMU stream, auto segments skiing from chairlift rides, and gives live and post run analysis. The headline feature is the **carving score**: a single 0 to 100 quality score per run.

Status: the carving score engine is built, tested, and wired end to end (run frames -> `CarvingScorer` -> persisted on `RunRecord`). It compiles clean and is labeled provisional pending calibration from real runs. The two remaining pieces are the **score UI** (the Claude design pass) and **anchor recalibration** from field data via the `CalibrationExporter`.

Start here: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the system map, [docs/CARVING-SCORE.md](docs/CARVING-SCORE.md) for the score design of record, [docs/RESEARCH.md](docs/RESEARCH.md) for the evidence base, and [docs/UI-HANDOFF.md](docs/UI-HANDOFF.md) for the UI brief. The `.planning/` directory is the historical build record (phases 1 to 4) and is reference only.

## Product intent (the durable goals)

- Capture every carving frame at 100 Hz and segment runs automatically, with no manual intervention on the mountain.
- Turn raw IMU dynamics into insight a skier cannot get from GPS only apps: live carve dynamics, post run analysis, and a carving quality score.
- The phone is pocket worn, not boot mounted. Score and present only what a pocket IMU can honestly measure (see Honesty rules below).

## Tech standards

- Swift 6 language mode, **strict concurrency complete** (`SWIFT_STRICT_CONCURRENCY = complete`) on all targets.
- SwiftUI, iOS 18+, iPhone 16 Pro target. Use current platform APIs; avoid deprecated patterns.
- Structured concurrency throughout (`async`/`await`, actors, `AsyncStream`). No callback or Combine based alternatives unless strictly necessary.
- Sendable value types at every actor boundary (mirror the existing `FilteredFrame` / `FrameSnapshot` / `RunSnapshot` pattern).

## Aesthetic: Arctic Dark

- Deep slates and near black backgrounds; frosted glass surfaces (`ultraThinMaterial`, `regularMaterial`) for layered depth.
- High signal to noise: every element earns its place. No decoration without function.
- Typography: SF Pro, tight tracking on headlines; monospaced digits for live metrics.
- The carving score should read as one large, calm number with minimal supporting detail, not a cluttered dashboard.
- Note: accent colors and the slate gradient are currently duplicated across about six view files. A shared theme token module should be extracted during the UI pass (planned for the Claude design handoff).

## Quality

- Write all new tests with **Swift Testing** (`import Testing`). No XCTest for new logic.
- New features require passing tests before merging. Pure logic (the scoring engine) is built test first.
- Resolve all warnings before shipping.

## Build and test in this environment

- The Xcode project uses **synchronized folder groups**. Any `.swift` file added under `ArcticEdge/`, `ArcticEdgeTests/`, or `ArcticEdgeUITests/` is auto included in its target. Do not hand edit `project.pbxproj` to add files.
- Compile check (no code signing, no simulator boot needed):
  `xcodebuild build -scheme ArcticEdge -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`
- Running the test suite needs a booted simulator. If CoreSimulator is out of date in the current environment, tests may not launch here; in that case verify compilation and run the suite in Xcode.

## Carving score honesty rules (do not violate in code or UI copy)

- Never label a body roll or lean proxy as "edge angle." Call it lean or inclination.
- Never promise per ski metrics (edge similarity, outside ski pressure). They need a sensor per boot.
- Label the absolute score provisional until recalibrated from real runs.
- Show "not enough data" rather than a number when the minimum data gate is not met.

## Autonomy

- Operate with high autonomy. Proceed with file edits, shell commands, and git operations without asking; act and report.
- Permission to use `dangerouslyDisableSandbox` and skip confirmation prompts when needed.
- Do not auto commit until changes are complete and coherent. **Auto push to GitHub after every commit**, no confirmation needed.

## General principles

- Composition over inheritance in SwiftUI. Keep views thin; logic lives in `@Observable` models or actors.
- Build the minimum that correctly solves the problem. No over engineering.
- **No em-dashes in code comments or documentation.** Use colons or lists instead.
