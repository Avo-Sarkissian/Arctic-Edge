// ContentView.swift
// ArcticEdge
//
// Session control screen — Arctic Dark redesign.
// Start Day arms the full capture pipeline; End Day finalizes and tears down.
// Design language: full-bleed dark gradient, frosted glass capsules, SF Pro Black wordmark.

import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings
    @State private var errorMessage: String? = nil

    // Wordmark breathing animation state — active when day is running.
    @State private var wordmarkGlowOpacity: Double = 0.0
    @State private var wordmarkScale: Double = 1.0

    var body: some View {
        ZStack {
            // Full-bleed background: deep slate gradient
            backgroundLayer

            // Low-opacity topographic texture — drawn with Canvas, no assets
            topoOverlay

            // Main content column
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 80)

                // Wordmark
                wordmark

                Spacer()
                    .frame(height: 48)

                // Frosted status pill
                statusPill

                Spacer()
                    .frame(height: 48)

                // Stats row (visible when day is active)
                if appModel.isDayActive {
                    statsRow
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    Spacer()
                        .frame(height: 40)
                }

                // Primary CTA button
                actionButton

                // Capture health: authorization refusals, GPS loss, and missing
                // background session are stated plainly rather than left silent.
                if !appModel.captureWarnings.isEmpty {
                    VStack(spacing: Theme.Spacing.xs) {
                        ForEach(appModel.captureWarnings, id: \.self) { warning in
                            noticeRow(warning, tint: Theme.Palette.caution)
                        }
                    }
                    .padding(.top, Theme.Spacing.m)
                }

                if let captureError = appModel.lastCaptureError {
                    noticeRow(captureError, tint: Theme.Palette.alarm)
                        .padding(.top, Theme.Spacing.s)
                }

                // Error label
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                }

                Spacer()
            }
            .padding(.horizontal, 24)

            // DEBUG HUD — compiled out of release builds
            #if DEBUG
            ClassifierDebugHUD()
                .allowsHitTesting(false)
            #endif
        }
        .animation(.easeInOut(duration: 0.4), value: appModel.isDayActive)
        .onAppear { syncWordmarkAnimation() }
        .onChange(of: appModel.isDayActive) { _, _ in syncWordmarkAnimation() }
    }

    // MARK: - Background layers

    private var backgroundLayer: some View {
        Theme.Gradients.slate.ignoresSafeArea()
    }

    // Subtle topographic contour lines drawn via Canvas — zero asset dependencies.
    private var topoOverlay: some View {
        Canvas { context, size in
            let lineCount = 12
            let amplitude: CGFloat = 28
            let opacity: CGFloat = 0.035

            for i in 0..<lineCount {
                let yBase = size.height * CGFloat(i + 1) / CGFloat(lineCount + 1)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: yBase))

                let segments = 24
                for s in 0...segments {
                    let x = size.width * CGFloat(s) / CGFloat(segments)
                    // Two sine waves at different frequencies create organic contour feel
                    let wave1 = sin(CGFloat(s) * 0.52 + CGFloat(i) * 1.1) * amplitude
                    let wave2 = sin(CGFloat(s) * 0.27 + CGFloat(i) * 0.7) * (amplitude * 0.4)
                    path.addLine(to: CGPoint(x: x, y: yBase + wave1 + wave2))
                }

                context.stroke(
                    path,
                    with: .color(.white.opacity(opacity)),
                    lineWidth: 0.5
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Wordmark

    private var wordmark: some View {
        ZStack {
            // Glow layer — animates opacity when day is active
            if appModel.isDayActive {
                Text("ARCTICEDGE")
                    .font(.system(size: 28, weight: .black, design: .default))
                    .tracking(28 * 0.15)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.Palette.arctic, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blur(radius: 12)
                    .opacity(wordmarkGlowOpacity)
                    .scaleEffect(wordmarkScale)
            }

            // Foreground wordmark
            Text("ARCTICEDGE")
                .font(.system(size: 28, weight: .black, design: .default))
                .tracking(28 * 0.15)
                .foregroundStyle(.white)
                .scaleEffect(wordmarkScale)
        }
    }

    // MARK: - Status pill

    private var statusPill: some View {
        HStack(spacing: 8) {
            // Colored indicator dot
            Circle()
                .fill(appModel.isDayActive ? Theme.Palette.arctic : Theme.Palette.textFaint)
                .frame(width: 7, height: 7)
                .shadow(
                    color: appModel.isDayActive ? Theme.Palette.arctic.opacity(0.8) : .clear,
                    radius: 4
                )

            Text(appModel.isDayActive ? "Active" : "Ready")
                .font(.system(size: 13, weight: .medium, design: .default))
                .tracking(1.5)
                .foregroundStyle(appModel.isDayActive ? Theme.Palette.arctic : Theme.Palette.textSecondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    appModel.isDayActive ? Theme.Palette.arctic.opacity(0.35) : Theme.Palette.hairline,
                    lineWidth: Theme.hairlineWidth
                )
        )
    }

    // MARK: - Stats row

    // Live day summary. These three cards rendered hardcoded dashes: the label
    // "RUNS" over a literal em dash, forever. They now read the day's real
    // totals, with the average carving score leading because that is the number
    // the app is for.
    private var statsRow: some View {
        HStack(spacing: 12) {
            StatCard(
                label: "AVG SCORE",
                value: MetricFormatter.score(appModel.daySummary.averageScore),
                tint: ScoreBand.color(for: appModel.daySummary.averageScore)
            )
            StatCard(label: "RUNS", value: "\(appModel.daySummary.runCount)")
            StatCard(label: "VERT", value: MetricFormatter.altitudeWithUnit(appModel.daySummary.totalVertical, units: settings.unitSystem))
        }
    }

    // MARK: - Action button

    private var actionButton: some View {
        Button {
            Task {
                do {
                    if appModel.isDayActive {
                        try await appModel.endDay()
                    } else {
                        try await appModel.startDay()
                    }
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } label: {
            Group {
                if appModel.isDayActive {
                    // End Day — outlined red style
                    Text("END DAY")
                        .font(.system(size: 15, weight: .semibold, design: .default))
                        .tracking(3)
                        .foregroundStyle(Theme.Palette.alarm)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.action, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.action, style: .continuous)
                                .strokeBorder(Theme.Palette.alarm.opacity(0.6), lineWidth: 1)
                        )
                } else {
                    // Start Day — vibrant blue gradient fill
                    Text("START DAY")
                        .font(.system(size: 15, weight: .semibold, design: .default))
                        .tracking(3)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(Theme.Gradients.primaryAction)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: Theme.Palette.arctic.opacity(0.35), radius: 16, x: 0, y: 8)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Notices

    private func noticeRow(_ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(tint.opacity(0.30), lineWidth: 0.5)
        )
    }

    // MARK: - Helpers

    private func syncWordmarkAnimation() {
        if appModel.isDayActive {
            withAnimation(
                .easeInOut(duration: 2.4)
                .repeatForever(autoreverses: true)
            ) {
                wordmarkGlowOpacity = 0.75
                wordmarkScale = 1.012
            }
        } else {
            withAnimation(.easeOut(duration: 0.6)) {
                wordmarkGlowOpacity = 0.0
                wordmarkScale = 1.0
            }
        }
    }
}

// MARK: - StatCard

private struct StatCard: View {
    let label: String
    let value: String
    var tint: Color = Theme.Palette.textPrimary

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(value)
                .font(Theme.Typography.metric)
                .foregroundStyle(tint)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .tracking(2)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.m)
        .arcticCard(radius: 12)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(AppModel())
        .environment(AppSettings())
}
