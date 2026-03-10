// MockGPSManager.swift
// ArcticEdgeTests
//
// Test double for GPSManagerProtocol. Allows injecting GPSReading values into
// ActivityClassifier tests without requiring real Core Location hardware.

import Foundation
@testable import ArcticEdge

actor MockGPSManager: GPSManagerProtocol {
    private var continuations: [UUID: AsyncStream<GPSReading>.Continuation] = [:]

    nonisolated func makeStream() -> AsyncStream<GPSReading> {
        // makeStream() must be nonisolated to satisfy GPSManagerProtocol.
        // We hop onto the actor to register the continuation.
        let (stream, continuation) = AsyncStream<GPSReading>.makeStream()
        let id = UUID()
        Task {
            await self.registerContinuation(id: id, continuation: continuation)
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id: id) }
        }
        return stream
    }

    func start() async {
        // No-op: MockGPSManager produces values only via inject().
    }

    func stop() async {
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations = [:]
    }

    /// Push a reading to all active stream consumers.
    func inject(_ reading: GPSReading) async {
        for continuation in continuations.values {
            continuation.yield(reading)
        }
    }

    // MARK: - Private helpers

    private func registerContinuation(
        id: UUID,
        continuation: AsyncStream<GPSReading>.Continuation
    ) {
        continuations[id] = continuation
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
