// ArcticEdgeApp.swift
// ArcticEdge
//
// App entry point. Wires the full Phase 1 pipeline:
//   ModelContainer -> RingBuffer -> MotionManager -> StreamBroadcaster
//   -> PersistenceService + WorkoutSessionManager
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
import UIKit

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

    // PersistenceService is initialized asynchronously via setupPipelineAsync().
    // It is stored as an optional because @ModelActor init is async.
    // After setupPipelineAsync() completes, this is always non-nil.
    private(set) var persistenceService: PersistenceService?

    // Lifecycle observer tokens retained for deregistration.
    private var backgroundObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    // Background flush task handle for cancellation on session end.
    private var periodicFlushTask: Task<Void, Never>?

    nonisolated init() {
        // ModelContainer: FrameRecord and RunRecord schema.
        let schema = Schema([FrameRecord.self, RunRecord.self])
        let config = ModelConfiguration(schema: schema)
        // try! is acceptable here: a failed ModelContainer is an unrecoverable programmer error.
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

    // SESS-01: Start a session. Enforces HKWorkoutSession .running BEFORE starting
    // CMMotionManager. The run ID is shared between WorkoutSessionManager and broadcaster.
    func startSession() async throws {
        // 1. Bring HKWorkoutSession to .running first (SESS-01 ordering constraint).
        try await workoutSessionManager.start()

        let runID = UUID()

        // 2. Create the RunRecord on disk before motion data starts arriving.
        try await persistenceService?.createRunRecord(runID: runID, startTimestamp: Date())

        // 3. Start CMMotionManager. Frames start flowing into RingBuffer now.
        await broadcaster.start(runID: runID)

        // 4. Start periodic flush: drain ring buffer to SwiftData every 2 seconds
        //    when count >= 200 frames (SESS-02 batching policy).
        startPeriodicFlush(runID: runID)
    }

    // Stop the session: end HKWorkoutSession, stop motion, flush remaining frames.
    func endSession(runID: UUID) async throws {
        periodicFlushTask?.cancel()
        periodicFlushTask = nil

        await broadcaster.stop()
        await workoutSessionManager.end()

        // Final flush of any remaining frames in the ring buffer.
        if let service = persistenceService {
            try await service.emergencyFlush(ringBuffer: ringBuffer)
            try await service.finalizeRunRecord(runID: runID, endTimestamp: Date())
        }
    }

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
