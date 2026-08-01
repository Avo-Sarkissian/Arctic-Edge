// LiveTelemetryView.swift
// ArcticEdge
//
// Full-screen live telemetry dashboard. Three stacked live graph channels:
//   1. VERTICAL LOAD  — gravity-referenced vertical accel, centered ±1g, arctic blue
//   2. G-FORCE        — userAccel magnitude, 0–3.5g, mint green
//   3. GPS SPEED      — 0–40 m/s (144 km/h), amber
//
// All graphs: glow stroke (3-pass) + area fill + grid lines at key levels.
// Pocket-safe metrics: KM/H, G-FORCE magnitude, G² VARIANCE (no roll/pitch).
// Post-run sheet handled here so it can appear over the live view mid-session.

import SwiftUI

struct LiveTelemetryView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings
    @State private var liveViewModel = LiveViewModel()
    @State private var elapsedSeconds: Int = 0
    @State private var isEndingDay = false
    @State private var presentedRunID: UUID? = nil
    @State private var dismissedRunIDs: Set<UUID> = []

    private let arcticBlue = Theme.Palette.arctic
    private let mintGreen  = Theme.Palette.mint
    private let speedAmber = Theme.Palette.amber
    // Brighter variants for the waveform strokes, which sit on near-black and
    // need more lift than a label does.
    private let arcticStroke = Color(red: 0.30, green: 0.75, blue: 1.0)
    private let mintStroke   = Color(red: 0.25, green: 0.95, blue: 0.65)
    private let amberStroke  = Color(red: 1.0,  green: 0.80, blue: 0.25)

    // MARK: - Derived

    private var elapsedLabel: String {
        let h = elapsedSeconds / 3600
        let m = (elapsedSeconds % 3600) / 60
        let s = elapsedSeconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private var stateColor: Color {
        switch appModel.classifierStateLabel {
        case "SKIING":    return Theme.Palette.mint
        case "CHAIRLIFT": return Theme.Palette.caution
        default:          return Theme.Palette.textTertiary
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            backgroundLayer

            VStack(spacing: 0) {
                topBar

                // Three equal-height live graph channels
                verticalLoadGraph
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                channelDivider
                gForceGraph
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                channelDivider
                gpsSpeedGraph
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomPanel
            }
        }
        .sheet(isPresented: Binding(
            get: { presentedRunID != nil },
            set: { if !$0 { clearPresentedRun() } }
        )) {
            if let runID = presentedRunID {
                PostRunAnalysisView(runID: runID)
                    .environment(appModel)
                    .environment(settings)
                    .onDisappear { clearPresentedRun() }
            }
        }
        .onChange(of: appModel.lastFinalizedRunID) { _, newID in
            guard let id = newID, !dismissedRunIDs.contains(id) else { return }
            presentedRunID = id
        }
        .onChange(of: appModel.lastGPSSpeed) { _, speed in
            guard speed >= 0 else { return }
            liveViewModel.appendGPSSpeed(speed)
        }
        .task {
            liveViewModel.startConsuming(broadcaster: appModel.broadcaster)
            defer { liveViewModel.stopConsuming() }
            var tick = 0
            while !Task.isCancelled {
                elapsedSeconds = tick
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        Theme.Gradients.slate.ignoresSafeArea()
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle()
                    .fill(arcticBlue)
                    .frame(width: 7, height: 7)
                    .shadow(color: arcticBlue.opacity(0.9), radius: 5)
                Text("LIVE")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(2.5)
                    .foregroundStyle(arcticBlue)
            }

            Spacer()

            Text(appModel.classifierStateLabel)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(stateColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(stateColor.opacity(0.15))
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(stateColor.opacity(0.35), lineWidth: 0.5))

            Spacer()

            Text(elapsedLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.50))
        }
        .padding(.horizontal, 24)
        .frame(height: 52)
        .background(.ultraThinMaterial)
    }

    // MARK: - Channel divider

    private var channelDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 0.5)
    }

    // MARK: - Graph 1: Vertical load (gravity-projected accel, centered ±1g)

    private var verticalLoadGraph: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.22)

            TimelineView(.animation) { _ in
                let samples = liveViewModel.waveformSnapshot
                Canvas { ctx, size in
                    let midY  = size.height * 0.5
                    let scale = size.height * 0.40   // ±1g → ±40% height

                    // Grid: ±0.5g, ±0.25g, zero
                    for (v, isZero) in [(-0.5, false), (-0.25, false), (0.0, true),
                                        (0.25, false), (0.5, false)] as [(Double, Bool)] {
                        let y = midY - CGFloat(v) * scale
                        var l = Path()
                        l.move(to: CGPoint(x: 0, y: y))
                        l.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(l,
                                   with: .color(Color.white.opacity(isZero ? 0.14 : 0.05)),
                                   lineWidth: isZero ? 0.75 : 0.5)
                    }

                    guard samples.count > 1 else { return }
                    let xStep = size.width / CGFloat(samples.count - 1)

                    // Area fill between zero line and waveform
                    var fill = Path()
                    fill.move(to: CGPoint(x: 0, y: midY))
                    fill.addLine(to: CGPoint(x: 0, y: midY - CGFloat(samples[0]) * scale))
                    for (i, s) in samples.dropFirst().enumerated() {
                        fill.addLine(to: CGPoint(x: CGFloat(i + 1) * xStep,
                                                 y: midY - CGFloat(s) * scale))
                    }
                    fill.addLine(to: CGPoint(x: size.width, y: midY))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .color(arcticBlue.opacity(0.18)))

                    // Waveform line: 3-pass glow
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: midY - CGFloat(samples[0]) * scale))
                    for (i, s) in samples.dropFirst().enumerated() {
                        path.addLine(to: CGPoint(x: CGFloat(i + 1) * xStep,
                                                 y: midY - CGFloat(s) * scale))
                    }
                    ctx.stroke(path, with: .color(arcticBlue.opacity(0.18)), lineWidth: 12)
                    ctx.stroke(path, with: .color(arcticStroke.opacity(0.38)), lineWidth: 5)
                    ctx.stroke(path, with: .color(arcticStroke), lineWidth: 2.0)

                    // Right-edge "now" cursor
                    var cur = Path()
                    cur.move(to: CGPoint(x: size.width - 2, y: 0))
                    cur.addLine(to: CGPoint(x: size.width - 2, y: size.height))
                    ctx.stroke(cur, with: .color(.white.opacity(0.18)), lineWidth: 1)
                }
            }

            Text("VERTICAL LOAD")
                .font(.system(size: 8, weight: .medium))
                .tracking(2.5)
                .foregroundStyle(arcticStroke.opacity(0.55))
                .padding(.leading, 12)
                .padding(.top, 8)
        }
    }

    // MARK: - Graph 2: G-Force magnitude (0–3.5g, bottom-anchored)

    private var gForceGraph: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.18)

            TimelineView(.animation) { _ in
                let samples = liveViewModel.gForceSnapshot
                Canvas { ctx, size in
                    let base:  CGFloat = size.height * 0.90
                    let maxG:  CGFloat = 3.5
                    let scale: CGFloat = (size.height * 0.85) / maxG

                    // Baseline
                    var bl = Path()
                    bl.move(to: CGPoint(x: 0, y: base))
                    bl.addLine(to: CGPoint(x: size.width, y: base))
                    ctx.stroke(bl, with: .color(Color.white.opacity(0.12)), lineWidth: 0.75)

                    // Grid at 1g, 2g, 3g with labels
                    for g in [1.0, 2.0, 3.0] as [Double] {
                        let y = base - CGFloat(g) * scale
                        var l = Path()
                        l.move(to: CGPoint(x: 0, y: y))
                        l.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(l, with: .color(Color.white.opacity(0.06)), lineWidth: 0.5)
                        ctx.draw(
                            Text("\(Int(g))g")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.25)),
                            at: CGPoint(x: size.width - 6, y: y - 10),
                            anchor: .topTrailing
                        )
                    }

                    guard samples.count > 1 else { return }
                    let xStep = size.width / CGFloat(samples.count - 1)

                    // Area fill
                    var fill = Path()
                    fill.move(to: CGPoint(x: 0, y: base))
                    fill.addLine(to: CGPoint(x: 0, y: base - CGFloat(samples[0]) * scale))
                    for (i, s) in samples.dropFirst().enumerated() {
                        fill.addLine(to: CGPoint(x: CGFloat(i + 1) * xStep,
                                                 y: base - CGFloat(s) * scale))
                    }
                    fill.addLine(to: CGPoint(x: size.width, y: base))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .color(mintGreen.opacity(0.18)))

                    // Line: 3-pass glow
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: base - CGFloat(samples[0]) * scale))
                    for (i, s) in samples.dropFirst().enumerated() {
                        path.addLine(to: CGPoint(x: CGFloat(i + 1) * xStep,
                                                 y: base - CGFloat(s) * scale))
                    }
                    ctx.stroke(path, with: .color(mintGreen.opacity(0.18)), lineWidth: 12)
                    ctx.stroke(path, with: .color(mintStroke.opacity(0.38)), lineWidth: 5)
                    ctx.stroke(path, with: .color(mintStroke), lineWidth: 2.0)

                    // Cursor
                    var cur = Path()
                    cur.move(to: CGPoint(x: size.width - 2, y: 0))
                    cur.addLine(to: CGPoint(x: size.width - 2, y: size.height))
                    ctx.stroke(cur, with: .color(.white.opacity(0.18)), lineWidth: 1)
                }
            }

            Text("G-FORCE")
                .font(.system(size: 8, weight: .medium))
                .tracking(2.5)
                .foregroundStyle(mintStroke.opacity(0.55))
                .padding(.leading, 12)
                .padding(.top, 8)
        }
    }

    // MARK: - Graph 3: GPS Speed (0–40 m/s, bottom-anchored)

    private var gpsSpeedGraph: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.14)

            TimelineView(.animation) { _ in
                let samples = liveViewModel.gpsSnapshot
                Canvas { ctx, size in
                    let base:   CGFloat = size.height * 0.90
                    let maxSpd: CGFloat = 40.0   // m/s ≈ 144 km/h
                    let scale:  CGFloat = (size.height * 0.85) / maxSpd

                    // Baseline
                    var bl = Path()
                    bl.move(to: CGPoint(x: 0, y: base))
                    bl.addLine(to: CGPoint(x: size.width, y: base))
                    ctx.stroke(bl, with: .color(Color.white.opacity(0.12)), lineWidth: 0.75)

                    // Grid: 10, 20, 30 m/s with km/h labels
                    for (mps, label) in [(10.0, "36"), (20.0, "72"), (30.0, "108")] as [(Double, String)] {
                        let y = base - CGFloat(mps) * scale
                        var l = Path()
                        l.move(to: CGPoint(x: 0, y: y))
                        l.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(l, with: .color(Color.white.opacity(0.06)), lineWidth: 0.5)
                        ctx.draw(
                            Text("\(label)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.25)),
                            at: CGPoint(x: size.width - 6, y: y - 10),
                            anchor: .topTrailing
                        )
                    }

                    guard samples.count > 1 else { return }
                    let xStep = size.width / CGFloat(samples.count - 1)

                    // Area fill
                    var fill = Path()
                    fill.move(to: CGPoint(x: 0, y: base))
                    fill.addLine(to: CGPoint(x: 0, y: base - CGFloat(samples[0]) * scale))
                    for (i, s) in samples.dropFirst().enumerated() {
                        fill.addLine(to: CGPoint(x: CGFloat(i + 1) * xStep,
                                                 y: base - CGFloat(s) * scale))
                    }
                    fill.addLine(to: CGPoint(x: size.width, y: base))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .color(speedAmber.opacity(0.18)))

                    // Line: 3-pass glow
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: base - CGFloat(samples[0]) * scale))
                    for (i, s) in samples.dropFirst().enumerated() {
                        path.addLine(to: CGPoint(x: CGFloat(i + 1) * xStep,
                                                 y: base - CGFloat(s) * scale))
                    }
                    ctx.stroke(path, with: .color(speedAmber.opacity(0.18)), lineWidth: 12)
                    ctx.stroke(path, with: .color(amberStroke.opacity(0.38)), lineWidth: 5)
                    ctx.stroke(path, with: .color(amberStroke), lineWidth: 2.0)

                    // Cursor
                    var cur = Path()
                    cur.move(to: CGPoint(x: size.width - 2, y: 0))
                    cur.addLine(to: CGPoint(x: size.width - 2, y: size.height))
                    ctx.stroke(cur, with: .color(.white.opacity(0.18)), lineWidth: 1)
                }
            }

            Text("GPS SPEED")
                .font(.system(size: 8, weight: .medium))
                .tracking(2.5)
                .foregroundStyle(amberStroke.opacity(0.55))
                .padding(.leading, 12)
                .padding(.top, 8)

            // No-fix indicator — shown only until first GPS reading arrives
            if liveViewModel.gpsSnapshot.isEmpty {
                Text("NO GPS FIX")
                    .font(.system(size: 10, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(Color.white.opacity(0.28))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 0.5)

            // Current-value metric tiles (all pocket-safe / orientation-independent)
            HStack(spacing: 0) {
                metricTile(
                    label: settings.unitSystem.speedSuffix.uppercased(),
                    value: MetricFormatter.speed(
                        appModel.lastGPSSpeed >= 0 ? appModel.lastGPSSpeed : nil,
                        units: settings.unitSystem
                    ),
                    accent: speedAmber
                )
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.5, height: 36)
                metricTile(
                    label: "G-FORCE",
                    value: String(format: "%.2fg", liveViewModel.gForce),
                    accent: mintGreen
                )
                Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.5, height: 36)
                // Lateral load, gravity-referenced. Replaced a raw g-variance
                // readout, which was an internal classifier number with no
                // meaning to a skier.
                metricTile(
                    label: "LATERAL",
                    value: String(format: "%.2fg", liveViewModel.horizontalLoad),
                    accent: arcticBlue
                )
            }
            .padding(.vertical, 14)

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 0.5)

            // End Day
            Button {
                isEndingDay = true
                Task {
                    try? await appModel.endDay()
                    isEndingDay = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isEndingDay {
                        ProgressView()
                            .tint(Color.white.opacity(0.55))
                            .scaleEffect(0.75)
                    }
                    Text(isEndingDay ? "ENDING SESSION…" : "END DAY")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(2)
                }
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
            }
            .disabled(isEndingDay)
        }
        .background(.ultraThinMaterial)
    }

    private func metricTile(label: String, value: String, accent: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .tracking(2)
                .foregroundStyle(accent.opacity(0.65))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Post-run sheet helpers

    private func clearPresentedRun() {
        if let id = presentedRunID { dismissedRunIDs.insert(id) }
        presentedRunID = nil
    }
}
