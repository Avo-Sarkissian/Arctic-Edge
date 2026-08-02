# ArcticEdge

## What This Is

ArcticEdge is a high-performance skiing telemetry app for iPhone 16 Pro. It captures, processes, and analyzes downhill carving dynamics using a 100Hz sensor stream, giving skiers real-time performance feedback during runs and detailed graphed analysis after each run. The app automatically distinguishes skiing from chairlift rides to cleanly segment run data.

## Core Value

Every carving frame captured, every run segmented automatically — no data lost, no manual intervention required on the mountain.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] MotionManager actor using Swift 7 structured concurrency (Task, AsyncStream) reading CMDeviceMotion at 100Hz
- [ ] High-pass filter isolating carve pressure from vibration: preserve >2Hz signals, reject <0.5Hz body sway
- [ ] Hybrid data buffer: in-memory ring buffer for real-time processing + periodic SwiftData flush for persistence
- [ ] Live Telemetry Dashboard: scrolling carve-pressure waveform with frosted glass metric cards (pitch, roll, g-force)
- [ ] Post-Run Analysis Dashboard: graphed run data with per-segment breakdown
- [ ] Activity auto-detection: classify skiing vs. chairlift to automatically segment runs
- [ ] Background execution via HKWorkoutSession for uninterrupted capture when screen locks

### Out of Scope

- Apple Watch standalone app — iPhone-first, watch integration possible in v2
- Real-time coaching/alerts — analysis is post-run for v1
- Social/sharing features — not core to telemetry value

## Context

- Starting with the Motion Engine as the foundational layer; UI and analysis dashboards build on top
- iPhone 16 Pro targeted for its thermal headroom and ProMotion display
- Arctic Dark aesthetic throughout: deep slates, frosted glass (`ultraThinMaterial`/`regularMaterial`), high signal-to-noise
- HKWorkoutSession chosen over location-anchoring for legitimate background CPU budget and future watch integration
- Tight filter cutoff chosen based on carving biomechanics: edge engagement spikes are fast (>2Hz), postural lean is slow (<0.5Hz)
- No em-dashes in any code comments or documentation — use colons or lists instead

## Constraints

- **Platform**: iPhone 16 Pro, iOS 18+
- **Language**: Swift 7, SwiftUI 6, strict concurrency (complete mode)
- **Testing**: Swift Testing (`import Testing`) for all sensor fusion logic — no XCTest for new logic
- **Aesthetic**: Arctic Dark minimalist — every UI element must earn its place
- **Code style**: No em-dashes in comments or docs (use colons or lists)
- **Git**: Auto-push to GitHub after every commit

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Hybrid ring buffer + SwiftData | Real-time performance with crash-safe persistence | - Pending |
| HKWorkoutSession for background | Legitimate CPU budget, HealthKit integration path | - Pending |
| Tight filter cutoff (>2Hz / <0.5Hz) | Matches carving biomechanics; calibrate post-launch with real data | - Pending |
| Layered telemetry UI | Waveform + frosted glass cards gives real-time and glanceable data simultaneously | - Pending |
| Auto-push policy | User override: push after every commit, no confirmation needed | - Pending |

---
*Last updated: 2026-03-08 after initialization*
