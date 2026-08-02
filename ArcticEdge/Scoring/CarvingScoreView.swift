// CarvingScoreView.swift
// ArcticEdge
//
// The carving score, as the skier sees it.
//
// Design notes:
//
// The obvious treatment for a 0 to 100 score is a big number inside a circular
// progress ring with three coloured bars underneath. Every fitness app does it,
// and a ring says nothing about skiing. This screen instead pairs a hairline
// numeral with a turn ledger: one mark per detected turn, placed at the time it
// actually happened, above the line for a left turn and below for a right.
//
// The ledger is the signature and it is information, not decoration. Even
// spacing is real cadence regularity. A balanced split above and below the line
// is real left-to-right symmetry. Those are precisely the two quantities the
// Rhythm and Symmetry pillar is computed from, so the picture and the number are
// the same claim made twice. Nothing here is drawn from data the app did not
// measure.
//
// Honesty rules enforced in this file:
// - No score renders as "not enough data", never as 0.
// - The provisional tag sits next to the number whenever the model version says so.
// - Nothing is called edge angle, and no per-ski quantity appears anywhere.
// - Carving Intensity is absent, not zero, when GPS could not support it.

import SwiftUI

// MARK: - CarvingScoreView

struct CarvingScoreView: View {
    let score: CarvingScore

    /// Drives the count-up on appear. The number settles rather than snapping,
    /// which suits an instrument taking a reading.
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            if let overall = score.overall, score.dataQuality.sufficientData {
                heroBlock(overall)
                TurnLedger(turns: score.turns, tint: ScoreBand(score: overall).color)
                pillarBlock
                subMetricBlock
            } else {
                insufficientDataBlock
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 0.8)) { revealed = true } }
    }

    // MARK: Hero

    private func heroBlock(_ overall: Double) -> some View {
        let band = ScoreBand(score: overall)
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.s) {
                Text("CARVING SCORE").arcticLabel()
                if score.isProvisional { provisionalTag }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(MetricFormatter.score(revealed ? overall : 0))
                    .font(Theme.Typography.hero())
                    .tracking(Theme.Tracking.hero)
                    .monospacedDigit()
                    .foregroundStyle(band.color)
                    .contentTransition(.numericText())
                Text("/100")
                    .font(Theme.Typography.metricSmall)
                    .foregroundStyle(Theme.Palette.textFaint)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Carving score")
            .accessibilityValue("\(MetricFormatter.score(overall)) out of 100, \(band.label)")

            HStack(spacing: Theme.Spacing.s) {
                Text(band.label)
                    .font(Theme.Typography.title)
                    .foregroundStyle(band.color)
                Text("·")
                    .foregroundStyle(Theme.Palette.textFaint)
                Text("\(score.turnCount) turns")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .monospacedDigit()
            }
        }
    }

    private var provisionalTag: some View {
        Text("PROVISIONAL")
            .font(Theme.Typography.microLabel)
            .tracking(Theme.Tracking.microLabel)
            .foregroundStyle(Theme.Palette.caution)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.Palette.caution.opacity(0.12))
            .clipShape(Capsule())
            .accessibilityLabel("Provisional score, not yet calibrated against real runs")
    }

    // MARK: Pillars

    private var pillarBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("BREAKDOWN").arcticLabel()
            PillarRow(name: "Control", detail: "Smoothness through the turn",
                      value: score.pillars.controlSmoothness, tint: Theme.Palette.arctic)
            PillarRow(name: "Rhythm", detail: "Cadence and left-right balance",
                      value: score.pillars.rhythmSymmetry, tint: Theme.Palette.mint)
            PillarRow(name: "Carving", detail: score.pillars.carvingIntensity == nil
                        ? "Needs GPS: not available for this run"
                        : "How much the turn was carved, not skidded",
                      value: score.pillars.carvingIntensity, tint: Theme.Palette.amber)
        }
    }

    // MARK: Sub metrics

    private var subMetricBlock: some View {
        Group {
            if !score.subMetrics.isEmpty {
                DisclosureGroup {
                    VStack(spacing: Theme.Spacing.xs) {
                        ForEach(score.subMetrics, id: \.id) { metric in
                            HStack {
                                Text(metric.label)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.textSecondary)
                                Spacer()
                                Text(MetricFormatter.score(metric.normalized))
                                    .font(Theme.Typography.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.Palette.textPrimary)
                            }
                        }
                    }
                    .padding(.top, Theme.Spacing.s)
                } label: {
                    Text("DETAIL").arcticLabel()
                }
                .tint(Theme.Palette.textTertiary)
            }
        }
    }

    // MARK: Insufficient data

    private var insufficientDataBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("CARVING SCORE").arcticLabel()
            Text("Not enough data")
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Palette.textSecondary)
            Text(shortfallExplanation)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.m)
        .arcticCard()
    }

    /// Says which gate the run missed. A bare "not enough data" leaves the skier
    /// guessing whether the app is broken or the run was simply too short.
    private var shortfallExplanation: String {
        let quality = score.dataQuality
        if quality.turnCount < 8 {
            return "This run had \(quality.turnCount) detected \(quality.turnCount == 1 ? "turn" : "turns"). Scoring needs at least 8."
        }
        if quality.durationSeconds < 4 {
            return "This run lasted \(MetricFormatter.duration(quality.durationSeconds)). Scoring needs at least 4 seconds."
        }
        return "This run did not capture enough motion data to score honestly."
    }
}

// MARK: - TurnLedger

/// The run's turns, in time order, above and below a centreline.
///
/// Horizontal position is the turn's real start time within the run and mark
/// width is its real duration, so the gaps between marks are the cadence the
/// rhythm score measures. Left turns sit above the line, right turns below, so
/// an unbalanced skier sees the imbalance directly.
private struct TurnLedger: View {
    let turns: [TurnMark]
    let tint: Color

    private let height: CGFloat = 68

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("TURN RHYTHM").arcticLabel()
                Spacer()
                Text("L / R")
                    .font(Theme.Typography.microLabel)
                    .tracking(Theme.Tracking.microLabel)
                    .foregroundStyle(Theme.Palette.textFaint)
            }

            Canvas { context, size in
                let midY = size.height / 2

                // Centreline: the axis turns alternate across.
                var axis = Path()
                axis.move(to: CGPoint(x: 0, y: midY))
                axis.addLine(to: CGPoint(x: size.width, y: midY))
                context.stroke(axis, with: .color(Theme.Palette.hairline), lineWidth: 1)

                guard let last = turns.last else { return }
                let span = max(last.startTime + last.duration, 0.001)
                let maxMarkHeight = midY - 6

                for turn in turns {
                    let x = CGFloat(turn.startTime / span) * size.width
                    let width = max(CGFloat(turn.duration / span) * size.width, 2)
                    // Longer turns reach further from the axis, so a run of long
                    // arcing turns looks different from a run of quick scrubs.
                    let reach = min(maxMarkHeight, 14 + CGFloat(turn.duration) * 16)
                    let rect = CGRect(
                        x: x,
                        y: turn.isLeft ? midY - reach : midY,
                        width: min(width, size.width - x),
                        height: reach
                    )
                    let shape = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0), cornerRadius: 1.5)
                    context.fill(shape, with: .color(tint.opacity(turn.isLeft ? 0.85 : 0.5)))
                }
            }
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Turn rhythm")
            .accessibilityValue(accessibilitySummary)

            Text("Each mark is one detected turn, placed when it happened. Even spacing is steady rhythm; a balanced split is even left and right.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilitySummary: String {
        let left = turns.filter(\.isLeft).count
        return "\(turns.count) turns: \(left) left, \(turns.count - left) right"
    }
}

// MARK: - PillarRow

private struct PillarRow: View {
    let name: String
    let detail: String
    let value: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                    .font(Theme.Typography.title)
                    .foregroundStyle(value == nil ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
                Spacer()
                Text(MetricFormatter.score(value))
                    .font(Theme.Typography.metricSmall)
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? Theme.Palette.textFaint : tint)
            }

            // A hairline track with a filled span. No rounded pill: this reads as
            // a gauge on an instrument rather than a game progress bar.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.Palette.hairline)
                        .frame(height: 2)
                    if let value {
                        Rectangle()
                            .fill(tint)
                            .frame(width: geo.size.width * CGFloat(value / 100), height: 2)
                    }
                }
            }
            .frame(height: 2)

            Text(detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(value.map { "\(MetricFormatter.score($0)) out of 100" } ?? "not available")
    }
}

// MARK: - CarvingScoreBadge

/// Compact score for history rows. Shows a dash when the run was not scored.
struct CarvingScoreBadge: View {
    let score: Double?

    var body: some View {
        Text(MetricFormatter.score(score))
            .font(Theme.Typography.metricSmall)
            .monospacedDigit()
            .foregroundStyle(ScoreBand.color(for: score))
            .frame(minWidth: 34)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(ScoreBand.color(for: score).opacity(score == nil ? 0.06 : 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityLabel("Carving score")
            .accessibilityValue(score.map { MetricFormatter.score($0) } ?? "not scored")
    }
}

// MARK: - Preview

private func previewScore() -> CarvingScore {
    let turns: [TurnMark] = (0..<14).map { index in
        let jitter = Double(index % 3) * 0.15
        return TurnMark(
            id: index,
            startTime: Double(index) * 1.8 + jitter,
            duration: 1.1 + Double(index % 4) * 0.2,
            isLeft: index % 2 == 0
        )
    }
    let pillars = PillarScores(controlSmoothness: 78, rhythmSymmetry: 69, carvingIntensity: nil)
    let subMetrics = [
        SubMetricValue(id: "edge", label: "Edge Smoothness", normalized: 81, raw: 0),
        SubMetricValue(id: "rhythm", label: "Rhythm", normalized: 66, raw: 0)
    ]
    let quality = DataQuality(
        turnCount: turns.count, durationSeconds: 27,
        medianSampleRate: 100, gpsCoverage: 0.2, sufficientData: true
    )
    return CarvingScore(
        overall: 72.4,
        pillars: pillars,
        subMetrics: subMetrics,
        turnCount: turns.count,
        turns: turns,
        dataQuality: quality,
        modelVersion: "v1-provisional"
    )
}

#Preview("Scored run") {
    ScrollView {
        CarvingScoreView(score: previewScore())
            .padding(Theme.Spacing.l)
    }
    .arcticBackground()
}

#Preview("Not enough data") {
    CarvingScoreView(score: .insufficient(
        version: "v1-provisional",
        quality: DataQuality(turnCount: 3, durationSeconds: 9,
                             medianSampleRate: 100, gpsCoverage: 0, sufficientData: false)
    ))
    .padding(Theme.Spacing.l)
    .arcticBackground()
}
