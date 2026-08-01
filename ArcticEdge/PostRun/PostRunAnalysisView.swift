// PostRunAnalysisView.swift
// ArcticEdge
//
// Post-run analysis sheet presenting per-run stats, session aggregates,
// and three interactive Swift Charts (vertical load, g-force, GPS speed).
// chartXSelection drives the scrubber for ANLYS-04.
//
// Presented as a .sheet from TodayTabView (plan 03-06) on run end.
// Also used as NavigationStack push destination from RunHistoryView.

import SwiftUI
import Charts

struct PostRunAnalysisView: View {
    let runID: UUID
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = PostRunViewModel()
    @State private var selectedTimestamp: TimeInterval? = nil

    var body: some View {
        ZStack {
            Theme.Gradients.slate.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    headerSection

                    if viewModel.isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 60)
                    } else {
                        // The carving score leads: it is the reason this screen
                        // exists, and the stats below are supporting context.
                        if let score = viewModel.carvingScore {
                            CarvingScoreView(score: score)
                            Divider().overlay(Theme.Palette.hairline)
                        }

                        // Per-run stats
                        statsSection

                        // Session aggregates
                        sessionAggregatesSection

                        // Charts
                        if !viewModel.snapshots.isEmpty {
                            chartSection
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .task {
            guard let service = appModel.persistenceService else { return }
            await viewModel.loadData(
                runID: runID,
                persistenceService: service,
                ringBuffer: appModel.ringBuffer
            )
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("RUN COMPLETE")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(2.5)
                    .foregroundStyle(Color(red: 0.12, green: 0.56, blue: 1.0))
                Text("Analysis")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    // MARK: - Per-run stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("THIS RUN")
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 10
            ) {
                PostRunStatCard(label: "TOP SPEED",
                               value: MetricFormatter.speed(viewModel.stats.topSpeed))
                PostRunStatCard(label: "AVG SPEED",
                               value: MetricFormatter.speed(viewModel.stats.avgSpeed))
                PostRunStatCard(label: "VERTICAL",
                               value: MetricFormatter.altitudeWithUnit(viewModel.stats.verticalDrop))
                PostRunStatCard(label: "DISTANCE",
                               value: MetricFormatter.distanceWithUnit(viewModel.stats.distanceMeters))
                PostRunStatCard(label: "DURATION",
                               value: MetricFormatter.duration(viewModel.stats.duration))
            }
        }
    }

    // MARK: - Session aggregates

    private var sessionAggregatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("TODAY SO FAR")
            HStack(spacing: 10) {
                PostRunStatCard(label: "RUNS",
                               value: "\(viewModel.sessionAggregates.runCount)")
                PostRunStatCard(label: "TOTAL VERT",
                               value: MetricFormatter.altitudeWithUnit(viewModel.sessionAggregates.totalVertical))
                PostRunStatCard(label: "SKI TIME",
                               value: MetricFormatter.duration(viewModel.sessionAggregates.totalSkiingTime))
            }
        }
    }

    // MARK: - Charts (ANLYS-01, ANLYS-04)

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("TELEMETRY")

            // Vertical load: acceleration along gravity, high-pass filtered.
            // Not "carve pressure": a single pocket phone cannot measure the
            // pressure on either ski. This is whole-body vertical loading.
            chartView(
                title: "VERTICAL LOAD",
                data: viewModel.snapshots.compactMap { snap in
                    snap.filteredVerticalAccel.map { (snap.timestamp, $0) }
                },
                color: Color(red: 0.12, green: 0.56, blue: 1.0)
            )

            // G-force
            chartView(
                title: "G-FORCE",
                data: viewModel.snapshots.map { snap in
                    (snap.timestamp,
                     hypot(snap.userAccelX, hypot(snap.userAccelY, snap.userAccelZ)))
                },
                color: Color(red: 0.4, green: 0.9, blue: 0.6)
            )

            // GPS speed (only snapshots with a reading)
            chartView(
                title: "SPEED (KM/H)",
                data: viewModel.snapshots.compactMap { snap in
                    guard let s = snap.gpsSpeed else { return nil }
                    return (snap.timestamp, s * 3.6)
                },
                color: Color(red: 1.0, green: 0.7, blue: 0.3)
            )
        }
    }

    // Reusable LineMark chart with chartXSelection scrubber
    private func chartView(title: String, data: [(TimeInterval, Double)], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.5))

            Chart {
                ForEach(Array(data.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.0),
                        y: .value("Value", point.1)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }

                if let selected = selectedTimestamp {
                    RuleMark(x: .value("Selected", selected))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 2]))
                        .annotation(position: .top, alignment: .leading) {
                            scrubberAnnotation(at: selected)
                        }
                }
            }
            .chartXSelection(value: $selectedTimestamp)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel()
                        .foregroundStyle(.white.opacity(0.35))
                        .font(.system(size: 9))
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(.white.opacity(0.08))
                    AxisValueLabel()
                        .foregroundStyle(.white.opacity(0.35))
                        .font(.system(size: 9))
                }
            }
            .frame(height: 120)
            .background(Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // Scrubber annotation at the selected timestamp.
    //
    // Device pitch and roll used to be shown here in degrees. For a pocket-worn
    // phone those are the orientation of the phone in the pocket, not the skier's
    // body angle, so they were presented as insight while measuring nothing.
    // Replaced with the gravity-referenced channels the scoring engine trusts.
    private func scrubberAnnotation(at timestamp: TimeInterval) -> some View {
        let frame = viewModel.selectSnapshot(at: timestamp)
        return VStack(alignment: .leading, spacing: 3) {
            if let f = frame {
                Text(String(format: "G: %.2fg   LAT: %@",
                            hypot(f.userAccelX, hypot(f.userAccelY, f.userAccelZ)),
                            f.horizontalAccelMagnitude.map { String(format: "%.2fg", $0) } ?? "—"))
                Text("\(MetricFormatter.speedWithUnit(f.gpsSpeed))")
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(6)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .tracking(2.5)
            .foregroundStyle(.white.opacity(0.4))
    }

    private func formatSpeed(_ ms: Double) -> String {
        ms > 0 ? String(format: "%.0f km/h", ms * 3.6) : "--"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - PostRunStatCard

private struct PostRunStatCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .default))
                .foregroundStyle(.white)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 8, weight: .medium, design: .default))
                .tracking(1.5)
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
        )
    }
}
