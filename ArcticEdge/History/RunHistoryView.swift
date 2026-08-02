// RunHistoryView.swift
// ArcticEdge
//
// Run history browser: paginated list of all runs grouped by day.
// Day headers: date, resort name, run count, day average carving score.
// Run rows: run number (within day), score badge, top speed, vertical, duration.
// Text only, no sparklines or bars (Arctic Dark high signal-to-noise).
//
// The score badge leads each row: it is the metric the app exists to report, and
// scanning a season by score is the reason to keep history at all.
//
// NavigationStack push to PostRunAnalysisView on row tap.

import SwiftUI

struct RunHistoryView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings
    @State private var viewModel = HistoryViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Gradients.slate.ignoresSafeArea()

                if viewModel.dayGroups.isEmpty && !viewModel.isLoading {
                    emptyState
                } else {
                    List {
                        ForEach(viewModel.dayGroups) { group in
                            Section {
                                ForEach(Array(group.runs.enumerated()), id: \.element.id) { index, run in
                                    NavigationLink(destination:
                                        PostRunAnalysisView(runID: run.runID, isLiveRun: false)
                                            .environment(appModel)
                                            .environment(settings)
                                    ) {
                                        RunRowView(run: run, runNumber: index + 1, units: settings.unitSystem)
                                    }
                                    .listRowBackground(Color.white.opacity(0.04))
                                    .listRowSeparatorTint(.white.opacity(0.08))
                                    .onAppear {
                                        Task {
                                            guard let service = appModel.persistenceService else { return }
                                            // Resolve the resort name for rows as they
                                            // scroll into view. Cached after the first hit.
                                            await viewModel.geocodeIfNeeded(
                                                runRow: run, persistenceService: service
                                            )
                                            // Pagination trigger on last visible row
                                            if run.id == viewModel.dayGroups.last?.runs.last?.id {
                                                await viewModel.fetchNextPage(persistenceService: service)
                                            }
                                        }
                                    }
                                }
                            } header: {
                                DayHeaderView(group: group, units: settings.unitSystem)
                            }
                        }

                        if viewModel.isLoading {
                            HStack {
                                Spacer()
                                ProgressView().tint(.white.opacity(0.5))
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task {
            guard let service = appModel.persistenceService else { return }
            await viewModel.fetchNextPage(persistenceService: service)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.s) {
            Text("No runs yet")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.textSecondary)
                .accessibilityIdentifier("history.emptyState")
            Text("Start a day and ArcticEdge will record and score each run automatically.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Theme.Spacing.xl)
    }
}

// MARK: - DayHeaderView

private struct DayHeaderView: View {
    let group: DayGroup
    let units: UnitSystem

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text(group.resortName.uppercased())
                    .font(Theme.Typography.label)
                    .tracking(Theme.Tracking.microLabel)
                    .foregroundStyle(Theme.Palette.arctic.opacity(0.8))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 5) {
                    Text("AVG")
                        .font(Theme.Typography.microLabel)
                        .tracking(Theme.Tracking.microLabel)
                        .foregroundStyle(Theme.Palette.textFaint)
                    Text(MetricFormatter.score(group.averageScore))
                        .font(Theme.Typography.metricSmall)
                        .monospacedDigit()
                        .foregroundStyle(ScoreBand.color(for: group.averageScore))
                }
                Text("\(group.runCount) \(group.runCount == 1 ? "run" : "runs") · \(MetricFormatter.altitudeWithUnit(group.totalVertical, units: units)) vert")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - RunRowView

private struct RunRowView: View {
    let run: RunRow
    let runNumber: Int
    let units: UnitSystem

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            CarvingScoreBadge(score: run.carvingScore)

            Text("Run \(runNumber)")
                .font(Theme.Typography.metricSmall)
                .foregroundStyle(Theme.Palette.textPrimary.opacity(0.85))

            Spacer(minLength: 0)

            metricColumn(value: MetricFormatter.speed(run.topSpeed, units: units), label: units.speedSuffix)
            metricColumn(value: MetricFormatter.altitude(run.verticalDrop, units: units), label: "\(units.altitudeSuffix) vert")
            metricColumn(value: MetricFormatter.duration(run.duration), label: "time")
        }
        .padding(.vertical, 6)
    }

    private func metricColumn(value: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(Theme.Typography.metricSmall)
                .foregroundStyle(Theme.Palette.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.Palette.textFaint)
        }
        .frame(width: 58, alignment: .trailing)
    }
}
