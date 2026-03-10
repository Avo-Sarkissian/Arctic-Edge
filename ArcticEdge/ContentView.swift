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
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.051, green: 0.067, blue: 0.090), location: 0),
                .init(color: Color(red: 0.024, green: 0.039, blue: 0.059), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
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
                            colors: [Color(red: 0.12, green: 0.56, blue: 1.0), .clear],
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
                .fill(appModel.isDayActive
                    ? Color(red: 0.12, green: 0.56, blue: 1.0)
                    : Color.white.opacity(0.25))
                .frame(width: 7, height: 7)
                .shadow(
                    color: appModel.isDayActive
                        ? Color(red: 0.12, green: 0.56, blue: 1.0).opacity(0.8)
                        : .clear,
                    radius: 4
                )

            Text(appModel.isDayActive ? "Active" : "Ready")
                .font(.system(size: 13, weight: .medium, design: .default))
                .tracking(1.5)
                .foregroundStyle(
                    appModel.isDayActive
                        ? Color(red: 0.12, green: 0.56, blue: 1.0)
                        : Color.white.opacity(0.55)
                )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    appModel.isDayActive
                        ? Color(red: 0.12, green: 0.56, blue: 1.0).opacity(0.35)
                        : Color.white.opacity(0.08),
                    lineWidth: 0.5
                )
        )
    }

    // MARK: - Stats row

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatCard(label: "RUNS", value: "—")
            StatCard(label: "DISTANCE", value: "—")
            StatCard(label: "ELAPSED", value: elapsedTime)
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
                        .foregroundStyle(Color(red: 1.0, green: 0.28, blue: 0.28))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    Color(red: 1.0, green: 0.28, blue: 0.28).opacity(0.6),
                                    lineWidth: 1
                                )
                        )
                } else {
                    // Start Day — vibrant blue gradient fill
                    Text("START DAY")
                        .font(.system(size: 15, weight: .semibold, design: .default))
                        .tracking(3)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.118, green: 0.565, blue: 1.0),
                                    Color(red: 0.0, green: 0.40, blue: 0.80)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(
                            color: Color(red: 0.118, green: 0.565, blue: 1.0).opacity(0.35),
                            radius: 16, x: 0, y: 8
                        )
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    // Placeholder elapsed time — AppModel does not yet track a start timestamp,
    // so display a dash until that property is wired in a future plan.
    private var elapsedTime: String { "—" }

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

    var body: some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .default))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .default))
                .tracking(2)
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
        )
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(AppModel())
}
