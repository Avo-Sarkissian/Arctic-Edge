// RunHistoryView.swift
// ArcticEdge
//
// Run history browser: paginated list of all runs grouped by day.
// Day headers: date + resort name + run count + total vertical.
// Run rows: run number (within day), top speed, vertical, duration.
// Text only — no sparklines, no bars (Arctic Dark high signal-to-noise).
//
// NavigationStack push to PostRunAnalysisView on row tap.

import SwiftUI

struct RunHistoryView: View {
    @Environment(AppModel.self) private var appModel
    @State private var viewModel = HistoryViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                // Arctic Dark background
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.051, green: 0.067, blue: 0.090), location: 0),
                        .init(color: Color(red: 0.024, green: 0.039, blue: 0.059), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                if viewModel.dayGroups.isEmpty && !viewModel.isLoading {
                    emptyState
                } else {
                    List {
                        ForEach(viewModel.dayGroups) { group in
                            Section {
                                ForEach(Array(group.runs.enumerated()), id: \.element.id) { index, run in
                                    NavigationLink(destination:
                                        PostRunAnalysisView(runID: run.runID)
                                            .environment(appModel)
                                    ) {
                                        RunRowView(run: run, runNumber: index + 1)
                                    }
                                    .listRowBackground(Color.white.opacity(0.04))
                                    .listRowSeparatorTint(.white.opacity(0.08))
                                    .onAppear {
                                        // Pagination trigger on last visible row
                                        if run.id == viewModel.dayGroups.last?.runs.last?.id {
                                            Task {
                                                guard let service = appModel.persistenceService else { return }
                                                await viewModel.fetchNextPage(persistenceService: service)
                                            }
                                        }
                                    }
                                }
                            } header: {
                                DayHeaderView(group: group)
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
        VStack(spacing: 12) {
            Text("No runs recorded")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text("Start a day to begin recording runs.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.3))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - DayHeaderView

private struct DayHeaderView: View {
    let group: DayGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text(group.resortName.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .tracking(1.5)
                    .foregroundStyle(Color(red: 0.12, green: 0.56, blue: 1.0).opacity(0.8))
            }
            Spacer()
            Text("\(group.runCount) runs  \(String(format: "%.0f", group.totalVertical))m vert")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.vertical, 4)
    }
}

// MARK: - RunRowView

private struct RunRowView: View {
    let run: RunRow
    let runNumber: Int

    var body: some View {
        HStack(spacing: 0) {
            // Run number
            Text("Run \(runNumber)")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 60, alignment: .leading)

            Spacer()

            // Top speed
            metricColumn(
                value: run.topSpeed.map { String(format: "%.0f", $0 * 3.6) } ?? "--",
                label: "km/h"
            )

            // Vertical
            metricColumn(
                value: run.verticalDrop.map { String(format: "%.0f", $0) } ?? "--",
                label: "m vert"
            )

            // Duration
            metricColumn(
                value: formatDuration(run.duration),
                label: "time"
            )
        }
        .padding(.vertical, 6)
    }

    private func metricColumn(value: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(width: 70, alignment: .trailing)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
