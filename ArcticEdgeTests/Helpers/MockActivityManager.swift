// MockActivityManager.swift
// ArcticEdgeTests
//
// Test double for ActivityManagerProtocol. Allows injecting ActivitySnapshot values
// into ActivityClassifier tests without requiring real CMMotionActivityManager hardware.
// Use ActivitySnapshot() default init for "unknown/low-confidence" baseline activity.

import CoreMotion
import Foundation
@testable import ArcticEdge

actor MockActivityManager: ActivityManagerProtocol {
    private var continuations: [UUID: AsyncStream<ActivitySnapshot>.Continuation] = [:]

    func makeStream() -> AsyncStream<ActivitySnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ActivitySnapshot>.makeStream()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id: id) }
        }
        return stream
    }

    func start() async {
        // No-op: MockActivityManager produces values only via inject().
    }

    func stop() async {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations = [:]
    }

    /// Push an ActivitySnapshot to all active stream consumers.
    func inject(_ snapshot: ActivitySnapshot) async {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    // MARK: - Private helpers

    private func registerContinuation(
        id: UUID,
        continuation: AsyncStream<ActivitySnapshot>.Continuation
    ) {
        continuations[id] = continuation
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
