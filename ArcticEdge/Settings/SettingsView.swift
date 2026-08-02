// SettingsView.swift
// ArcticEdge
//
// Units, capture status, and data control.
//
// The data section is the important part: a telemetry app records a lot about
// where its user goes, so exporting and deleting that record has to be one tap
// away and has to be honest about what is kept and for how long.

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppSettings.self) private var settings

    @State private var frameCount: Int?
    @State private var exportResult: ExportResult?
    @State private var isExporting = false
    @State private var showDeleteConfirmation = false
    @State private var shareURLs: [URL] = []
    @State private var isSharing = false

    private enum ExportResult: Equatable {
        case success(Int)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Gradients.slate.ignoresSafeArea()
                Form {
                    unitsSection
                    captureSection
                    dataSection
                    aboutSection
                }
                .scrollContentBackground(.hidden)
                // Attached to the Form, not to the Section that owns the button.
                // A presentation modifier on a Section is not reliably hoisted
                // into the presentation hierarchy, so the dialog could fail to
                // appear: a bad failure mode for the one confirmation standing
                // between a tap and deleting every run the user has recorded.
                .confirmationDialog(
                    "Delete every run and its data?",
                    isPresented: $showDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete everything", role: .destructive) {
                        Task { await deleteAllData() }
                    }
                    .accessibilityIdentifier("settings.confirmDelete")
                    Button("Keep my data", role: .cancel) {}
                        .accessibilityIdentifier("settings.cancelDelete")
                } message: {
                    Text("This removes every recorded run, score, and motion frame. It cannot be undone.")
                }
            }
            .navigationTitle("Settings")
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task { await refreshFrameCount() }
        .sheet(isPresented: $isSharing) {
            ShareLink(items: shareURLs) { Text("Share export") }
        }
    }

    // MARK: - Units

    private var unitsSection: some View {
        Section {
            Picker("Units", selection: Binding(
                get: { settings.unitSystem },
                set: { settings.unitSystem = $0 }
            )) {
                ForEach(UnitSystem.allCases) { system in
                    Text(system.label).tag(system)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("UNITS").arcticLabel()
        }
        .listRowBackground(Theme.Palette.cardFill)
    }

    // MARK: - Capture

    private var captureSection: some View {
        Section {
            statusRow(
                "Location",
                value: locationStatusText,
                isHealthy: appModel.locationAuthorization.state == .authorizedFull
            )
            statusRow(
                "Background capture",
                value: appModel.isWorkoutSessionActive || !appModel.isDayActive ? "Ready" : "Unavailable",
                isHealthy: appModel.isWorkoutSessionActive || !appModel.isDayActive
            )
            statusRow(
                "Barometer",
                value: AltimeterManager.isAvailable ? "Available" : "Not on this device",
                isHealthy: AltimeterManager.isAvailable
            )
            if !AltimeterManager.isAvailable {
                Text("Without a barometer, vertical drop cannot be measured and is shown as a dash.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            if appModel.locationAuthorization.state.isBlocked {
                Link("Open iOS Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.arctic)
            }
        } header: {
            Text("CAPTURE").arcticLabel()
        }
        .listRowBackground(Theme.Palette.cardFill)
    }

    private var locationStatusText: String {
        switch appModel.locationAuthorization.state {
        case .authorizedFull:    return "Precise"
        case .authorizedReduced: return "Approximate"
        case .denied:            return "Denied"
        case .restricted:        return "Restricted"
        case .notDetermined:     return "Not requested"
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
            HStack {
                Text("Raw motion frames")
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text(frameCount.map { formatCount($0) } ?? "…")
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .accessibilityIdentifier("settings.frameCount")

            Button {
                Task { await exportCalibrationData() }
            } label: {
                HStack {
                    Text("Export runs for calibration")
                    Spacer()
                    if isExporting { ProgressView().tint(Theme.Palette.textSecondary) }
                }
            }
            .disabled(isExporting)
            .foregroundStyle(Theme.Palette.arctic)
            .accessibilityIdentifier("settings.exportCalibration")

            if let exportResult {
                switch exportResult {
                case .success(let count):
                    Text("Exported \(count) \(count == 1 ? "run" : "runs").")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.mint)
                case .failure(let message):
                    Text(message)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.alarm)
                }
            }

            Button("Delete all data", role: .destructive) {
                showDeleteConfirmation = true
            }
            .disabled(appModel.isDayActive)
            .accessibilityIdentifier("settings.deleteAll")
        } header: {
            Text("DATA").arcticLabel()
        } footer: {
            Text("Runs and their scores are kept indefinitely. Raw motion frames are removed after \(AppModel.frameRetentionDays) days to keep the app's storage bounded. Nothing leaves your device unless you export it.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .listRowBackground(Theme.Palette.cardFill)
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Carving score model")
                Spacer()
                Text(CarvingScoreModel.v1.version)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .accessibilityIdentifier("settings.modelVersion")
            }
        } header: {
            Text("ABOUT").arcticLabel()
        } footer: {
            Text("The carving score is provisional. Its scale is set from published research rather than from labelled skiing, so use it to compare your own runs rather than as an absolute grade. Exporting runs is what will improve it.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .listRowBackground(Theme.Palette.cardFill)
    }

    // MARK: - Rows

    private func statusRow(_ title: String, value: String, isHealthy: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            Text(value)
                .font(Theme.Typography.caption)
                .foregroundStyle(isHealthy ? Theme.Palette.mint : Theme.Palette.caution)
        }
    }

    // MARK: - Actions

    private func refreshFrameCount() async {
        guard let service = appModel.persistenceService else { return }
        frameCount = try? await service.frameCount()
    }

    private func exportCalibrationData() async {
        guard let service = appModel.persistenceService else { return }
        isExporting = true
        defer { isExporting = false }
        let exporter = CalibrationExporter(persistence: service)
        do {
            let urls = try await exporter.exportAllRuns()
            shareURLs = urls
            exportResult = .success(urls.count)
            isSharing = true
        } catch {
            exportResult = .failure(error.localizedDescription)
        }
    }

    private func deleteAllData() async {
        guard let service = appModel.persistenceService else { return }
        do {
            try await service.deleteAllData()
            await appModel.refreshDaySummary()
            await refreshFrameCount()
        } catch {
            exportResult = .failure("Could not delete data: \(error.localizedDescription)")
        }
    }

    private func formatCount(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName))
    }
}
