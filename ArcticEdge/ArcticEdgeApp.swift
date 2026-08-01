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

enum AppModelError: Error, LocalizedError {
    case persistenceServiceNotReady

    var errorDescription: String? {
        switch self {
        case .persistenceServiceNotReady:
            return "Storage is still starting up. Try again in a moment."
        }
    }
}

// MARK: - Background task assertion

// Wraps async work in a UIKit background task assertion so iOS does not suspend
// the process partway through a SwiftData write. Emergency flushes used to run
// in a bare detached Task, so a background transition could cut a save in half
// and lose the tail of a run.
@MainActor
func withBackgroundAssertion(
    name: String,
    _ work: @Sendable @escaping () async -> Void
) async {
    var taskID: UIBackgroundTaskIdentifier = .invalid
    taskID = UIApplication.shared.beginBackgroundTask(withName: name) {
        // Expiration handler: iOS is reclaiming the assertion. Release it so
        // the app is not killed for holding an expired task.
        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
    }
    await work()
    if taskID != .invalid {
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
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
    let locationAuthorization: LocationAuthorization

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

    // Capture health. `captureWarnings` lists everything currently degrading the
    // session (location denied, workout session unavailable, GPS lost) so the UI
    // can be honest instead of silently recording nothing. `lastCaptureError`
    // holds the most recent persistence failure, which used to be swallowed by
    // `try?` at every call site.
    private(set) var captureWarnings: [String] = []
    private(set) var lastCaptureError: String? = nil
    private(set) var gpsHealth: GPSHealth = .idle

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

        // No explicit migration plan: all Phase 3 schema additions are Optional fields,
        // so SwiftData performs lightweight migration automatically. An explicit
        // SchemaMigrationPlan with duplicate-checksum schemas crashes at launch.
        // try! is acceptable: a failed ModelContainer is an unrecoverable programmer error.
        let c = try! ModelContainer(for: schema, configurations: config)
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
        // LocationAuthorization owns a CLLocationManager, which must be created
        // on the main thread. AppModel is @MainActor apart from this init, and
        // the App struct constructs it during main-actor scene setup.
        self.locationAuthorization = MainActor.assumeIsolated { LocationAuthorization() }
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
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await withBackgroundAssertion(name: "ArcticEdge.backgroundFlush") {
                    do { try await service.emergencyFlush(ringBuffer: rb) }
                    catch { await self.recordCaptureError(error, context: "background flush") }
                }
            }
        }

        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await withBackgroundAssertion(name: "ArcticEdge.terminateFlush") {
                    do { try await service.emergencyFlush(ringBuffer: rb) }
                    catch { await self.recordCaptureError(error, context: "shutdown flush") }
                }
            }
        }
    }

    // MARK: - Capture health

    /// Records a persistence failure so it reaches the UI. Save errors used to be
    /// discarded by `try?`, which meant a full disk or a cold-weather shutdown lost
    /// data with no signal to the skier at all.
    func recordCaptureError(_ error: Error, context: String) {
        lastCaptureError = "\(context): \(error.localizedDescription)"
    }

    private func refreshCaptureWarnings() {
        var warnings: [String] = []
        if let reason = locationAuthorization.state.degradedReason, isDayActive || locationAuthorization.state.isBlocked {
            warnings.append(reason)
        }
        if let gpsMessage = gpsHealth.message, gpsHealth != .awaitingFix,
           locationAuthorization.state.degradedReason == nil {
            warnings.append(gpsMessage)
        }
        if isDayActive && !isWorkoutSessionActive {
            warnings.append("Background workout session unavailable: capture may stop when the screen locks.")
        }
        captureWarnings = warnings
    }

    // Tracks whether the HKWorkoutSession actually started. Capture continues
    // without it, but background survival is not guaranteed, so the UI says so.
    private(set) var isWorkoutSessionActive: Bool = false

    // MARK: - Power Saver

    // Enables UIDevice battery monitoring and registers for level-change notifications.
    // Battery level is -1 in simulator — guard on level >= 0 before acting.
    private func setupBatteryMonitoring() {
        // Idempotent: startDay() re-arms after endDay() removed the observer.
        if let existing = batteryObserver {
            NotificationCenter.default.removeObserver(existing)
            batteryObserver = nil
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        if level >= 0 {
            batteryPercent = Int(level * 100)
            // Honor the current level immediately rather than waiting for the
            // first level-change notification, which may be an hour away.
            let pct = Int(level * 100)
            Task { @MainActor [weak self] in
                await self?.updatePowerSaverMode(batteryPercent: pct)
            }
        }
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
        lastCaptureError = nil

        // 0. Location authorization. CLBackgroundActivitySession only grants
        //    background execution once when-in-use authorization is held, so the
        //    prompt has to resolve before GPS starts. A refusal degrades the
        //    session (no speed, distance, or intensity pillar) but never blocks
        //    IMU capture, which is the part that carries the carving score.
        await locationAuthorization.requestIfNeeded()

        // 1. HKWorkoutSession first (SESS-01 ordering constraint).
        //    Denial or unavailability must NOT abort the day: the session buys
        //    background CPU budget, it is not the source of any data. Capture
        //    proceeds degraded and the UI warns that a screen lock may stop it.
        do {
            try await workoutSessionManager.start()
            isWorkoutSessionActive = true
        } catch {
            isWorkoutSessionActive = false
            recordCaptureError(error, context: "workout session")
        }

        // 2. Start GPS and Activity signal sources.
        if !locationAuthorization.state.isBlocked {
            await gpsManager.start()
        }
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

        // 6. Re-arm battery monitoring. endDay() tears it down, and this used to
        //    be a launch-only call, so Power Saver was dead from the second
        //    session of the process onward: exactly when a long day needs it.
        setupBatteryMonitoring()

        // 7. Start HUD polling loop.
        startHUDPolling()
        refreshCaptureWarnings()
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
            let rb = ringBuffer
            await withBackgroundAssertion(name: "ArcticEdge.endDayFlush") {
                do { try await service.emergencyFlush(ringBuffer: rb) }
                catch { await self.recordCaptureError(error, context: "end of day flush") }
            }
        }

        isDayActive = false
        isWorkoutSessionActive = false
        gpsHealth = .idle
        classifierStateLabel = "IDLE"
        lastFinalizedRunID = nil
        previousRunID = nil
        refreshCaptureWarnings()

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
        let gps = gpsManager
        hudPollingTask = Task { @MainActor [weak self] in
            var warningTick = 0
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
                // Bug 1 fix: keep captured frames tagged with the active run so
                // FrameRecord.runID matches RunRecord.runID. On run start, tag with
                // the run's id; on run end, switch to a throwaway id so subsequent
                // lift frames do not pollute the just-ended run's frame set.
                let previous = self?.previousRunID ?? nil
                if currentRunID != previous {
                    if let id = currentRunID {
                        await mm.setActiveRunID(id)
                    } else {
                        await mm.setActiveRunID(UUID())
                    }
                }
                // Detect non-nil -> nil transition: a run just ended.
                if let prev = previous, currentRunID == nil {
                    self?.lastFinalizedRunID = prev
                }
                self?.previousRunID = currentRunID
                // GPS health changes slowly; sample it once a second rather than
                // hitting the actor ten times for a value that rarely moves.
                warningTick += 1
                if warningTick % 10 == 0 {
                    let health = await gps.health
                    self?.gpsHealth = health
                    self?.refreshCaptureWarnings()
                }
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
                    // Errors are reported rather than dropped: a failed save is
                    // permanent data loss and the skier deserves to know.
                    do { try await service.flushWithGPS(frames: frames, gpsSpeed: gpsSpeed) }
                    catch { self.recordCaptureError(error, context: "periodic flush") }
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
