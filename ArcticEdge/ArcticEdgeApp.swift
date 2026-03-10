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

    // Lifecycle observer tokens retained for deregistration.
    private var backgroundObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

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
    }

    // MARK: - HUD polling

    // Polls ActivityClassifier actor state at 10Hz and bridges it to @Observable
    // main-actor properties for SwiftUI reactivity.
    private func startHUDPolling() {
        let classifier = activityClassifier
        hudPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let stateLabel = await classifier.classifierStateLabel
                let gpsSpeed = await classifier.latestGPS?.speed ?? -1
                let variance = await classifier.gForceVariance
                let actLabel = await classifier.latestActivityLabel
                let progress = await classifier.hysteresisProgress
                self?.classifierStateLabel = stateLabel
                self?.lastGPSSpeed = gpsSpeed
                self?.lastGForceVariance = variance
                self?.lastActivityLabel = actLabel
                self?.hysteresisProgress = progress
                try? await Task.sleep(for: .milliseconds(100))  // 10Hz HUD update
            }
        }
    }

    // MARK: - Periodic flush

    // SESS-02: Periodic background drain. Runs until cancelled.
    private func startPeriodicFlush(runID: UUID) {
        guard let service = persistenceService else { return }
        let rb = ringBuffer
        periodicFlushTask = Task.detached(priority: .background) {
            while !Task.isCancelled {
                if await rb.count >= 200 {
                    let frames = await rb.drain()
                    try? await service.flush(frames: frames)
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

// MARK: - App entry point

@main
struct ArcticEdgeApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(appModel.container)
                .environment(appModel)
                .task {
                    await appModel.setupPipelineAsync()
                }
        }
    }
}
