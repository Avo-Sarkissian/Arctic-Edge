// ArcticEdgeApp.swift
// ArcticEdge
//
// App entry point. Wires the full pipeline:
//   ModelContainer -> RingBuffer -> MotionManager -> StreamBroadcaster
//   -> PersistenceService + WorkoutSessionManager + GPSManager + ActivityManager
//   -> ActivityClassifier (owns run segmentation boundaries)
//
// PersistenceService (@ModelActor) cannot be created synchronously in App.init()
// because @ModelActor initialization binds to a background serial queue via the
// model container. The chosen pattern: AppModel is an @Observable class that lazily
// initializes PersistenceService inside an async .task block on the WindowGroup.
// This guarantees the ModelContainer exists before PersistenceService is constructed
// and avoids any main-actor-executor binding.

import SwiftUI
import SwiftData
import HealthKit
import CoreMotion
import CoreLocation
import UIKit

// MARK: - PowerSaverMode

nonisolated enum PowerSaverMode: Equatable, Sendable {
    case normal   // 100Hz IMU, continuous GPS
    case saving   // 60Hz IMU, duty-cycled GPS (≤1 update/5s)
}

// MARK: - AppModelError

enum AppModelError: Error {
    case persistenceServiceNotReady
}

// MARK: - AppModel

// @Observable class owns all long-lived pipeline actors.
// Using a class (not struct) so that notification observer closures can capture
// [weak self] and avoid creating retain cycles or referencing a copied struct value.
@Observable
@MainActor
final class AppModel {
    let container: ModelContainer
    let ringBuffer: RingBuffer
    let motionManager: MotionManager
    let broadcaster: StreamBroadcaster
    let workoutSessionManager: WorkoutSessionManager
    let gpsManager: GPSManager
    let activityManager: ActivityManager
    let activityClassifier: ActivityClassifier

    // PersistenceService is initialized asynchronously via setupPipelineAsync().
    // It is stored as an optional because @ModelActor init is async.
    // After setupPipelineAsync() completes, this is always non-nil.
    private(set) var persistenceService: PersistenceService?

    // HUD observable state — updated at 10Hz by hudPollingTask.
    private(set) var classifierStateLabel: String = "IDLE"
    private(set) var lastGPSSpeed: Double = -1
    private(set) var lastGForceVariance: Double = 0
    private(set) var lastActivityLabel: String = "unknown"
    private(set) var hysteresisProgress: Double = 0
    private(set) var isDayActive: Bool = false

    // Set by HUD polling when currentRunID transitions non-nil -> nil (run ended).
    // Observed by TodayTabView to auto-present PostRunAnalysisView.
    private(set) var lastFinalizedRunID: UUID? = nil

    // Tracks the last seen currentRunID in the polling loop for finalization detection.
    private var previousRunID: UUID? = nil

    // Power Saver — battery-level-driven mode switching.
    private(set) var powerSaverMode: PowerSaverMode = .normal
    private(set) var thermalStateLabel: String = "NOMINAL"
    private(set) var batteryPercent: Int = -1            // -1 = unmonitored (simulator)
    private(set) var currentSampleRateHz: Int = 100
    private(set) var gpsHorizontalAccuracyMeters: Double = -1

    // Lifecycle observer tokens retained for deregistration.
    private var backgroundObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private var batteryObserver: NSObjectProtocol?

    // Background flush task handle for cancellation on session end.
    private var periodicFlushTask: Task<Void, Never>?

    // HUD polling task handle.
    private var hudPollingTask: Task<Void, Never>?

    nonisolated init() {
        // ModelContainer: FrameRecord and RunRecord schema.
        let schema = Schema([FrameRecord.self, RunRecord.self])
        let config = ModelConfiguration(schema: schema)
        // try! is acceptable here: a failed ModelContainer is an unrecoverable programmer error.
        let c = try! ModelContainer(
            for: schema,
            migrationPlan: ArcticEdgeMigrationPlan.self,
            configurations: config
        )
        self.container = c

        let rb = RingBuffer()
        self.ringBuffer = rb

        // MotionManager owns a CMMotionManager and the ring buffer.
        let mm = MotionManager(dataSource: CMMotionManager(), ringBuffer: rb)
        self.motionManager = mm

        // StreamBroadcaster owns the MotionManager reference.
        let bc = StreamBroadcaster(motionManager: mm)
        self.broadcaster = bc

        // Wire the optional broadcaster ref back into MotionManager to break circular init.
        // Task bridging is needed because setStreamBroadcaster is actor-isolated.
        Task { await mm.setStreamBroadcaster(bc) }

        self.workoutSessionManager = WorkoutSessionManager()
        self.gpsManager = GPSManager()
        self.activityManager = ActivityManager()
        self.activityClassifier = ActivityClassifier()
    }

    // Called once from the WindowGroup .task modifier.
    // Initializes PersistenceService on a background queue via Task.detached,
    // then registers lifecycle observers.
    func setupPipelineAsync() async {
        // PersistenceService must be created on a non-MainActor executor.
        // Task.detached detaches from the current (MainActor) executor, ensuring the
        // @ModelActor init runs on the model actor's background serial queue.
        let capturedContainer = container
        let service = await Task.detached {
            PersistenceService(modelContainer: capturedContainer)
        }.value
        persistenceService = service

        // Check for orphaned session from previous unclean exit (SESS-05).
        let sentinel = UserDefaults.standard.bool(forKey: kSessionSentinelKey)
        if sentinel {
            await workoutSessionManager.recoverOrphanedSession()
        }

        setupLifecycleObservers()
        setupBatteryMonitoring()
    }

    // SESS-04: Register for app lifecycle notifications so the ring buffer is flushed
    // before the process suspends or terminates.
    private func setupLifecycleObservers() {
        guard let service = persistenceService else { return }
        let rb = ringBuffer

        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Detach to avoid blocking the notification callback thread.
            Task.detached {
                try? await service.emergencyFlush(ringBuffer: rb)
            }
        }

        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task.detached {
                try? await service.emergencyFlush(ringBuffer: rb)
            }
        }
    }

    // MARK: - Power Saver

    // Enables UIDevice battery monitoring and registers for level-change notifications.
    // Battery level is -1 in simulator — guard on level >= 0 before acting.
    private func setupBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        if level >= 0 { batteryPercent = Int(level * 100) }
        batteryObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let level = UIDevice.current.batteryLevel
                guard level >= 0 else { return }
                let pct = Int(level * 100)
                self.batteryPercent = pct
                await self.updatePowerSaverMode(batteryPercent: pct)
            }
        }
    }

    @MainActor
    func updatePowerSaverMode(batteryPercent: Int) async {
        let newMode = AppModel.nextPowerSaverMode(current: powerSaverMode, batteryPercent: batteryPercent)
        guard newMode != powerSaverMode else { return }
        powerSaverMode = newMode
        let saving = (newMode == .saving)
        await motionManager.setPowerSaverMode(saving)
        await gpsManager.setPowerSaverMode(saving)
    }

    /// Pure threshold logic — extracted for testability.
    /// Activates at ≤30%, deactivates at ≥35% (5% hysteresis prevents flapping).
    nonisolated static func nextPowerSaverMode(
        current: PowerSaverMode, batteryPercent: Int
    ) -> PowerSaverMode {
        switch current {
        case .normal: return batteryPercent <= 30 ? .saving : .normal
        case .saving: return batteryPercent >= 35 ? .normal : .saving
        }
    }

    // MARK: - Day lifecycle

    // Start Day: arms GPS, ActivityManager, ActivityClassifier, IMU pipeline.
    // SESS-01: HKWorkoutSession must reach .running before CMMotionManager starts.
    func startDay() async throws {
        // 1. HKWorkoutSession first (SESS-01 ordering constraint).
        try await workoutSessionManager.start()

        // 2. Start GPS and Activity signal sources.
        await gpsManager.start()
        await activityManager.start()

        // 3. Get streams for classifier.
        let frameStream = await broadcaster.makeStream()
        let gpsStream = await gpsManager.makeStream()
        let activityStream = await activityManager.makeStream()

        guard let service = persistenceService else {
            throw AppModelError.persistenceServiceNotReady
        }

        // 4. Arm ActivityClassifier — it owns all run boundaries from here.
        await activityClassifier.startDay(
            frameStream: frameStream,
            gpsStream: gpsStream,
            activityStream: activityStream,
            persistenceService: service
        )

        // 5. Start IMU pipeline (day-level runID; per-run IDs owned by classifier).
        let dayRunID = UUID()
        await broadcaster.start(runID: dayRunID)
        startPeriodicFlush(runID: dayRunID)
        isDayActive = true

        // 6. Start HUD polling loop.
        startHUDPolling()
    }

    // End Day: finalizes any open RunRecord, stops all capture.
    func endDay() async throws {
        periodicFlushTask?.cancel()
        periodicFlushTask = nil
        hudPollingTask?.cancel()
        hudPollingTask = nil

        // Classifier finalizes any open RunRecord before stopping.
        await activityClassifier.endDay()
        await broadcaster.stop()
        await gpsManager.stop()
        await activityManager.stop()
        await workoutSessionManager.end()

        if let service = persistenceService {
            try await service.emergencyFlush(ringBuffer: ringBuffer)
        }

        isDayActive = false
        classifierStateLabel = "IDLE"
        lastFinalizedRunID = nil
        previousRunID = nil

        // Tear down battery monitoring for this session.
        if let obs = batteryObserver {
            NotificationCenter.default.removeObserver(obs)
            batteryObserver = nil
        }
        UIDevice.current.isBatteryMonitoringEnabled = false
        batteryPercent = -1
        powerSaverMode = .normal
    }

    // MARK: - HUD polling

    // Polls ActivityClassifier actor state at 10Hz and bridges it to @Observable
    // main-actor properties for SwiftUI reactivity.
    // Also detects non-nil -> nil transitions on currentRunID to capture lastFinalizedRunID.
    private func startHUDPolling() {
        let classifier = activityClassifier
        let mm = motionManager
        hudPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let stateLabel = await classifier.classifierStateLabel
                let gpsSpeed = await classifier.latestGPS?.speed ?? -1
                let gpsAccuracy = await classifier.latestGPS?.horizontalAccuracy ?? -1
                let variance = await classifier.gForceVariance
                let actLabel = await classifier.latestActivityLabel
                let progress = await classifier.hysteresisProgress
                let currentRunID = await classifier.currentRunID
                let sampleRateHz = await mm.currentSampleRateHz
                let thermal = ProcessInfo.processInfo.thermalState
                self?.classifierStateLabel = stateLabel
                self?.lastGPSSpeed = gpsSpeed
                self?.gpsHorizontalAccuracyMeters = gpsAccuracy
                self?.lastGForceVariance = variance
                self?.lastActivityLabel = actLabel
                self?.hysteresisProgress = progress
                self?.currentSampleRateHz = sampleRateHz
                self?.thermalStateLabel = thermal.debugLabel
                // Detect non-nil -> nil transition: a run just ended.
                if let prev = self?.previousRunID, currentRunID == nil {
                    self?.lastFinalizedRunID = prev
                }
                self?.previousRunID = currentRunID
                try? await Task.sleep(for: .milliseconds(100))  // 10Hz HUD update
            }
        }
    }

    // MARK: - Periodic flush

    // SESS-02: Periodic background drain. Runs until cancelled.
    // GPS speed is captured on @MainActor each iteration, then passed to the
    // @ModelActor service via a detached task. lastGPSSpeed is < 0 when unavailable.
    private func startPeriodicFlush(runID: UUID) {
        guard let service = persistenceService else { return }
        let rb = ringBuffer
        periodicFlushTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await rb.count >= 200 {
                    let frames = await rb.drain()
                    let gpsSpeed = self.lastGPSSpeed >= 0 ? self.lastGPSSpeed : nil
                    Task.detached {
                        try? await service.flushWithGPS(frames: frames, gpsSpeed: gpsSpeed)
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - ProcessInfo.ThermalState display

private extension ProcessInfo.ThermalState {
    var debugLabel: String {
        switch self {
        case .nominal:   return "NOMINAL"
        case .fair:      return "FAIR"
        case .serious:   return "SERIOUS"
        case .critical:  return "CRITICAL"
        @unknown default: return "UNKNOWN"
        }
    }
}

// MARK: - App entry point

@main
struct ArcticEdgeApp: App {
    @State private var appModel = AppModel()
    // MetricKit subscriber retained for the process lifetime. Registers with
    // MXMetricManager.shared in its init; receives daily payloads on-device.
    private let metricKitSubscriber = MetricKitSubscriber()

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Today", systemImage: "mountain.2.fill") {
                    TodayTabView()
                }
                Tab("History", systemImage: "clock.fill") {
                    RunHistoryView()
                }
            }
            .tint(Color(red: 0.12, green: 0.56, blue: 1.0))
            .modelContainer(appModel.container)
            .environment(appModel)
            .task {
                await appModel.setupPipelineAsync()
            }
        }
    }
}
