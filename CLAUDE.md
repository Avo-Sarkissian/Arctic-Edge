# ArcticEdge — Claude Code Guidelines

## Tech Standards
- Target **Swift 7** and **SwiftUI 6** patterns for **iPhone 16 Pro**.
- Use the latest platform APIs; avoid deprecated patterns.
- Adopt structured concurrency (`async`/`await`, `Actor`) throughout — no callback-based or Combine-based alternatives unless strictly necessary.

## Aesthetic: Arctic Dark
- Maintain a consistent **Arctic Dark** minimalist theme:
  - Deep slates and near-black backgrounds.
  - Frosted glass surfaces (`ultraThinMaterial`, `regularMaterial`) for layered depth.
  - High signal-to-noise ratio — every UI element must earn its place.
- Avoid visual clutter. No decorative elements without functional purpose.
- Typography: favor SF Pro with tracked, tight spacing on headlines.

## Quality
- Enable **Strict Concurrency Checking** (`SWIFT_STRICT_CONCURRENCY = complete`) for all targets.
- Write all tests using **Swift Testing** (`import Testing`) — no XCTest for new logic.
- New features require passing tests before merging.
- Resolve all warnings before shipping.

## Autonomy
- Claude operates with **high autonomy** on this project.
- Permission to use `dangerouslyDisableSandbox` and skip confirmation prompts when needed.
- Proceed with file edits, shell commands, and git operations without asking for approval — act and report.

## General Principles
- Prefer composition over inheritance in SwiftUI views.
- Keep views thin — business logic belongs in `@Observable` models or actors.
- No over-engineering: build the minimum that correctly solves the problem.
- Do not auto-commit unless changes are complete and coherent.
- **Auto-push to GitHub after every commit** — no confirmation needed.
