// StreamBroadcaster.swift
// ArcticEdge
//
// Actor that fans out FilteredFrame to multiple independent AsyncStream consumers.
// Owns a single MotionManager reference; starts it once regardless of consumer count.

import Foundation

actor StreamBroadcaster {
    private var continuations: [UUID: AsyncStream<FilteredFrame>.Continuation] = [:]
    private let motionManager: MotionManager
    private var isStarted = false

    init(motionManager: MotionManager) {
        self.motionManager = motionManager
    }

    // Returns a new independent AsyncStream for one consumer.
    // Multiple calls to makeStream() do not trigger additional MotionManager starts.
    func makeStream() -> AsyncStream<FilteredFrame> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<FilteredFrame>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self, id] _ in
            Task { await self?.removeContinuation(id: id) }
        }
        return stream
    }

    // Start the MotionManager with the given runID. Idempotent: calling start() again
    // while already running does not create a second CMMotionManager update handler.
    func start(runID: UUID) async {
        guard !isStarted else { return }
        isStarted = true
        await motionManager.startUpdates(runID: runID)
    }

    // Stop the MotionManager and finish all active consumer continuations.
    func stop() async {
        isStarted = false
        await motionManager.stopUpdates()
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations = [:]
    }

    // Called by MotionManager on each new frame. Delivers the frame to all consumers.
    func broadcast(_ frame: FilteredFrame) {
        for continuation in continuations.values {
            continuation.yield(frame)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    // Number of currently active consumer continuations. Exposed for testing.
    var continuationCount: Int { continuations.count }
}
