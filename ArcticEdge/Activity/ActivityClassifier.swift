// ActivityClassifier.swift
// ArcticEdge
//
// Hysteresis state machine that fuses GPS speed, g-force variance, and CMMotionActivity
// to classify skiing vs. chairlift rides and segment them into RunRecords.
//
// Design notes:
// - Clock injection via `clock: () -> Date` closure makes hysteresis deterministic in tests.
// - All state transitions require sustained signal windows (onset: 3s, end: 2s) to prevent
//   brief GPS noise or terrain features from splitting a single run into multiple records.
// - GPS blackout while in .chairlift state is tolerated: the GPS gate is waived, and
//   the chairlift signal is sustained by IMU variance + motion activity alone.
// - RunRecord is NOT created until the full skiing onset window elapses (no provisional).
// - pendingFrames buffers FilteredFrames during the onset window so the run startTimestamp
//   uses the first frame that triggered onset accumulation, not the confirmation time.

import CoreMotion
import Foundation
import SwiftData

// MARK: - ClassifierState

nonisolated enum ClassifierState: Sendable, Equatable {
    case idle
    case chairlift
    case skiing
}

// MARK: - PersistenceServiceProtocol

/// Minimal persistence contract used by ActivityClassifier.
/// PersistenceService conforms via extension; MockPersistenceService conforms in tests.
protocol PersistenceServiceProtocol: Actor {
    func createRunRecord(runID: UUID, startTimestamp: Date) throws
    // Updated signature: accepts computed stats alongside endTimestamp.
    // Callers that don't have stats available pass nil for all Optional parameters.
    func finalizeRunRecord(runID: UUID, endTimestamp: Date,
                           topSpeed: Double?, avgSpeed: Double?,
                           verticalDrop: Double?, distanceMeters: Double?,
                           resortName: String?) throws
    // Phase 3 fetch methods for ViewModel queries.
    func fetchRunRecords(descriptor: FetchDescriptor<RunRecord>) async throws -> [RunRecord]
    func fetchFrameRecords(descriptor: FetchDescriptor<FrameRecord>) async throws -> [FrameRecord]
    // Phase 3 history pagination and geocode cache write for HistoryViewModel.
    func fetchRunHistory(offset: Int, limit: Int) async throws -> [RunSnapshot]
    func updateResortName(runID: UUID, resortName: String) async throws
    // Re-stamps frames captured during the skiing onset window onto the run they
    // actually belong to. Frames are tagged at capture time, before the classifier
    // has confirmed the run, so the onset window lands on a throwaway id.
    func retagFrames(fromUptime: TimeInterval, toUptime: TimeInterval, runID: UUID) async throws
}

// MARK: - ActivityClassifier

actor ActivityClassifier {

    // MARK: - Configuration

    let skiingOnsetSeconds: Double
    let runEndSeconds: Double
    let varianceWindowSize: Int

    private let liftSpeedMin: Double = 0.5      // m/s chairlift lower bound
    private let liftSpeedMax: Double = 7.0      // m/s chairlift upper bound
    private let skiingSpeedMin: Double = 3.0    // m/s skiing lower bound
    private let lowVarianceThreshold: Double = 0.01   // g² — chairlift: variance < this
    private let highVarianceThreshold: Double = 0.005 // g² — skiing:    variance > this

    // MARK: - Injectable clock

    private let clock: @Sendable () -> Date

    // MARK: - Mutable state

    private(set) var state: ClassifierState = .idle
    private var pendingSkiingOnsetAt: Date?
    private var pendingRunEndAt: Date?
    private var pendingFrames: [FilteredFrame] = []
    private(set) var currentRunID: UUID?

    // Uptime span of the skiing onset window for the run in progress. Those
    // frames were captured before the run was confirmed, so they carry the
    // previous throwaway runID and are reclaimed at finalization.
    private var pendingOnsetWindow: (start: TimeInterval, end: TimeInterval)?

    private var varianceWindow: [Double] = []
    private(set) var latestGPS: GPSReading?
    private(set) var latestActivity: ActivitySnapshot?

    // MARK: - HUD helper properties (actor-isolated, read via await from AppModel polling task)

    /// Human-readable string label for the current ClassifierState.
    var classifierStateLabel: String {
        switch state {
        case .skiing:    return "SKIING"
        case .chairlift: return "CHAIRLIFT"
        case .idle:      return "IDLE"
        }
    }

    /// Human-readable activity label derived from the latest ActivitySnapshot.
    var latestActivityLabel: String {
        guard let a = latestActivity else { return "unknown" }
        if a.automotive  { return "automotive" }
        if a.running     { return "running" }
        if a.walking     { return "walking" }
        if a.cycling     { return "cycling" }
        if a.stationary  { return "stationary" }
        return "unknown"
    }

    /// Hysteresis progress toward the skiing onset confirmation window (0.0–1.0).
    /// Returns 0 when not accumulating an onset window.
    var hysteresisProgress: Double {
        guard let onsetStart = pendingSkiingOnsetAt else { return 0.0 }
        let elapsed = clock().timeIntervalSince(onsetStart)
        return min(elapsed / skiingOnsetSeconds, 1.0)
    }

    private var consumptionTasks: [Task<Void, Never>] = []
    private var persistence: (any PersistenceServiceProtocol)?

    // MARK: - Run lifecycle sinks
    //
    // The classifier owns run boundaries, so it is the only place that knows the
    // exact moment a run starts and ends. These closures let it push that fact out
    // immediately instead of having the app discover it by polling at 10 Hz.
    //
    // runIDSink retags live capture. runFinalizedSink triggers the scoring and
    // stats pass. Both are closures rather than protocol members so the classifier
    // stays free of any dependency on MotionManager or the scoring engine.

    private var runIDSink: (@Sendable (UUID) async -> Void)?
    private var runFinalizedSink: (@Sendable (UUID) async -> Void)?

    func setRunIDSink(_ sink: @escaping @Sendable (UUID) async -> Void) { runIDSink = sink }
    func setRunFinalizedSink(_ sink: @escaping @Sendable (UUID) async -> Void) { runFinalizedSink = sink }

    // Serial chain for run lifecycle writes. create, retag, and finalize used to be
    // independent unstructured Tasks, so a short run could finalize before its
    // RunRecord existed and the finalize would silently no-op.
    private var lifecycleChain: Task<Void, Never>?

    private func enqueueLifecycle(_ work: @escaping @Sendable () async -> Void) {
        let previous = lifecycleChain
        lifecycleChain = Task {
            await previous?.value
            await work()
        }
    }

    /// Waits for every queued run lifecycle write to land. Used by endDay and tests.
    func drainLifecycleQueue() async {
        await lifecycleChain?.value
    }

    // MARK: - Init

    init(
        skiingOnsetSeconds: Double = 3.0,
        runEndSeconds: Double = 2.0,
        varianceWindowSize: Int = 50,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.skiingOnsetSeconds = skiingOnsetSeconds
        self.runEndSeconds = runEndSeconds
        self.varianceWindowSize = varianceWindowSize
        self.clock = clock
    }

    // MARK: - Day lifecycle

    /// Arms the classifier and begins consuming all three input streams.
    /// Default safe state on arm is .chairlift (assume we're on a lift until proven otherwise).
    func startDay(
        frameStream: AsyncStream<FilteredFrame>,
        gpsStream: AsyncStream<GPSReading>,
        activityStream: AsyncStream<ActivitySnapshot>,
        persistenceService: PersistenceService
    ) {
        persistence = persistenceService
        state = .chairlift

        let gpsTask = Task { [weak self] in
            for await gps in gpsStream { await self?.setGPS(gps) }
        }
        let activityTask = Task { [weak self] in
            for await activity in activityStream { await self?.setActivity(activity) }
        }
        let frameTask = Task { [weak self] in
            for await frame in frameStream { await self?.processFrame(frame) }
        }
        consumptionTasks = [gpsTask, activityTask, frameTask]
    }

    /// Tears down the classifier and finalizes any open RunRecord.
    func endDay() async {
        consumptionTasks.forEach { $0.cancel() }
        consumptionTasks = []
        if state == .skiing, let runID = currentRunID {
            finalizeRun(runID: runID, endTimestamp: clock())
        }
        // Let every queued create/retag/finalize land before tearing down, so the
        // last run of the day is scored rather than cancelled mid-write.
        await drainLifecycleQueue()
        resetAllState()
    }

    private func resetAllState() {
        state = .idle
        pendingSkiingOnsetAt = nil
        pendingRunEndAt = nil
        pendingFrames = []
        pendingOnsetWindow = nil
        currentRunID = nil
        varianceWindow = []
        latestGPS = nil
        latestActivity = nil
        persistence = nil
        lifecycleChain = nil
        runIDSink = nil
        runFinalizedSink = nil
    }

    // MARK: - Frame processing

    func processFrame(_ frame: FilteredFrame) async {
        // Append g-force magnitude to the rolling variance window.
        let g = hypot(frame.userAccelX, hypot(frame.userAccelY, frame.userAccelZ))
        varianceWindow.append(g)
        if varianceWindow.count > varianceWindowSize {
            varianceWindow.removeFirst()
        }

        let now = clock()
        switch state {
        case .chairlift: evaluateSkiingOnset(frame: frame, now: now)
        case .skiing:    evaluateRunEnd(now: now)
        case .idle:      break
        }
    }

    // MARK: - Skiing onset

    private func evaluateSkiingOnset(frame: FilteredFrame, now: Date) {
        guard skiingSignalActive() else {
            pendingSkiingOnsetAt = nil
            pendingFrames = []
            return
        }
        if pendingSkiingOnsetAt == nil { pendingSkiingOnsetAt = now }
        let elapsed = now.timeIntervalSince(pendingSkiingOnsetAt!)
        if elapsed >= skiingOnsetSeconds {
            confirmSkiingTransition()
        } else {
            pendingFrames.append(frame)
        }
    }

    private func confirmSkiingTransition() {
        let runID = UUID()
        currentRunID = runID

        // The run began when onset accumulation started, not when it was confirmed.
        // pendingSkiingOnsetAt is already wall-clock (it comes from clock()), so it
        // shares a domain with the endTimestamp set on finalization. This used to
        // read Date(timeIntervalSince1970: frame.timestamp), but a FilteredFrame
        // timestamp is CMDeviceMotion uptime, which put every run start in 1970.
        let startTimestamp = pendingSkiingOnsetAt ?? clock()
        // Uptime bound for the same instant, so frames (which carry uptime) can be
        // matched to this run by time range and not only by runID.
        let startUptime = pendingFrames.first?.timestamp

        // Remember the onset window so it can be reclaimed at finalization. The
        // retag cannot happen now: part of that window is still sitting in the
        // ring buffer, unflushed, so a retag here would miss it.
        if let startUptime {
            pendingOnsetWindow = (startUptime, pendingFrames.last?.timestamp ?? startUptime)
        } else {
            pendingOnsetWindow = nil
        }

        let service = persistence
        enqueueLifecycle {
            try? await service?.createRunRecord(runID: runID, startTimestamp: startTimestamp)
        }

        // Tell MotionManager directly rather than waiting for the 10 Hz HUD poll,
        // which left up to 100 ms of further frames on the old id.
        if let sink = runIDSink {
            Task { await sink(runID) }
        }

        state = .skiing
        pendingSkiingOnsetAt = nil
        pendingFrames = []
    }

    // MARK: - Run end

    private func evaluateRunEnd(now: Date) {
        guard chairliftSignalActive() else {
            pendingRunEndAt = nil
            return
        }
        if pendingRunEndAt == nil { pendingRunEndAt = now }
        if now.timeIntervalSince(pendingRunEndAt!) >= runEndSeconds {
            confirmChairliftTransition()
        }
    }

    private func confirmChairliftTransition() {
        if let runID = currentRunID {
            finalizeRun(runID: runID, endTimestamp: clock())
        }
        currentRunID = nil
        state = .chairlift
        pendingRunEndAt = nil
    }

    /// Closes out a run: stamps the end time, then hands the run to the
    /// finalization sink so its stats and carving score are computed and stored.
    ///
    /// Scoring used to happen only if the post-run sheet happened to load, so a
    /// skier who took 20 runs and opened 3 sheets ended the day with 17 unscored
    /// runs. Finalization is the only moment guaranteed to happen for every run.
    private func finalizeRun(runID: UUID, endTimestamp: Date) {
        let service = persistence
        let finalized = runFinalizedSink
        let switchTag = runIDSink
        let onsetWindow = pendingOnsetWindow
        pendingOnsetWindow = nil
        enqueueLifecycle {
            // Reclaim the onset window first, so the stats and score below see the
            // whole run. By now every frame has been flushed, which is why this
            // cannot run at confirmation time: the tail is still in the ring buffer
            // at that point.
            if let onsetWindow {
                try? await service?.retagFrames(
                    fromUptime: onsetWindow.start,
                    toUptime: onsetWindow.end,
                    runID: runID
                )
            }
            // Stats and score are written by the finalization sink, which needs the
            // run's frames. Stamp the end time first so those queries see a closed run.
            try? await service?.finalizeRunRecord(
                runID: runID, endTimestamp: endTimestamp,
                topSpeed: nil, avgSpeed: nil,
                verticalDrop: nil, distanceMeters: nil,
                resortName: nil
            )
            await finalized?(runID)
        }
        // Point live capture at a throwaway id so lift frames do not pollute the
        // run that just closed.
        if let switchTag {
            Task { await switchTag(UUID()) }
        }
    }

    // MARK: - Signal predicates

    /// True when all three chairlift signals are active (or GPS is blacked out in chairlift state).
    func chairliftSignalActive() -> Bool {
        let isAutomotive = (latestActivity?.automotive == true) &&
                           (latestActivity?.confidence != .low)
        let speedInLiftRange: Bool
        if gpsBlackout {
            // Sustain chairlift state through GPS outages (tunnels, tree cover).
            speedInLiftRange = (state == .chairlift)
        } else {
            let speed = latestGPS!.speed
            speedInLiftRange = speed >= liftSpeedMin && speed <= liftSpeedMax
        }
        return isAutomotive && speedInLiftRange && (gForceVariance < lowVarianceThreshold)
    }

    /// True when skiing signals are active: high speed, high variance, not automotive.
    func skiingSignalActive() -> Bool {
        let speedOK = gpsBlackout || latestGPS!.speed >= skiingSpeedMin
        let notAutomotive = !(latestActivity?.automotive ?? false) ||
                             (latestActivity?.confidence == .low)
        return speedOK && (gForceVariance > highVarianceThreshold) && notAutomotive
    }

    // MARK: - Computed signal properties

    /// True when no valid GPS fix is available.
    private var gpsBlackout: Bool {
        latestGPS == nil || (latestGPS?.horizontalAccuracy ?? -1) < 0
    }

    /// Sample variance of the rolling g-force magnitude window. Returns 0 for fewer than 2 samples.
    var gForceVariance: Double {
        guard varianceWindow.count > 1 else { return 0.0 }
        let n = Double(varianceWindow.count)
        let mean = varianceWindow.reduce(0.0, +) / n
        let sumSq = varianceWindow.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        return sumSq / (n - 1)
    }

    // MARK: - Test support helpers
    //
    // Internal (not private) so @testable imports can drive the classifier
    // without requiring a real PersistenceService (@ModelActor needs a ModelContainer).

    func setState(_ newState: ClassifierState) { state = newState }
    func setGPS(_ reading: GPSReading?) { latestGPS = reading }
    func setActivity(_ snapshot: ActivitySnapshot) { latestActivity = snapshot }
    func setPersistence(_ service: any PersistenceServiceProtocol) { persistence = service }
    func setCurrentRunID(_ id: UUID) { currentRunID = id }

    /// endDay variant that injects a mock persistence service — for tests only.
    func endDayWithPersistence(_ service: any PersistenceServiceProtocol) async {
        persistence = service
        consumptionTasks.forEach { $0.cancel() }
        consumptionTasks = []
        if state == .skiing, let runID = currentRunID {
            finalizeRun(runID: runID, endTimestamp: clock())
        }
        await drainLifecycleQueue()
        resetAllState()
    }
}

// MARK: - PersistenceService conformance

// PersistenceService satisfies PersistenceServiceProtocol via this retroactive conformance.
// The @ModelActor throws methods satisfy async throws protocol requirements in Swift.
extension PersistenceService: PersistenceServiceProtocol {}
