// RingBuffer.swift
// ArcticEdge
//
// Actor-based fixed-capacity circular buffer for FilteredFrame.
// Stores the most recent ~10 seconds of sensor data at 100Hz (1000 samples).
// Used by MotionManager to accumulate frames for batched writes to PersistenceService.

actor RingBuffer {
    private var buffer: [FilteredFrame] = []
    private let capacity: Int = 1000   // ~10 seconds at 100Hz

    // Append a frame. If at capacity, the oldest frame is dropped.
    // Dropping oldest is acceptable for live telemetry: recent data is always prioritized.
    func append(_ frame: FilteredFrame) {
        if buffer.count >= capacity {
            buffer.removeFirst()
        }
        buffer.append(frame)
    }

    // Synchronous body prevents actor reentrancy window where new frames could be lost
    // between read and clear. If drain() contained an await, Swift's actor scheduler
    // could interleave a concurrent append between the read and the buffer reset,
    // causing those frames to be silently dropped. The synchronous swap eliminates
    // this window: the entire read-and-clear is atomic within a single turn of the actor.
    func drain() -> [FilteredFrame] {
        let chunk = buffer
        buffer = []
        return chunk
    }

    var count: Int { buffer.count }
}
