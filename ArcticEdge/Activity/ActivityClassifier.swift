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
    func finalizeRunRecord(runID: UUID, endTimestamp: Date) throws
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

    private var varianceWindow: [Double] = []
    private(set) var latestGPS: GPSReading?
    private(set) var latestActivity: ActivitySnapshot?

    private var consumptionTasks: [Task<Void, Never>] = []
    private var persistence: (any PersistenceServiceProtocol)?

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
            try? await persistence?.finalizeRunRecord(runID: runID, endTimestamp: clock())
        }
        resetAllState()
    }

    private func resetAllState() {
        state = .idle
        pendingSkiingOnsetAt = nil
        pendingRunEndAt = nil
        pendingFrames = []
        currentRunID = nil
        varianceWindow = []
        latestGPS = nil
        latestActivity = nil
        persistence = nil
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
        let startTimestamp = pendingFrames.first.map { Date(timeIntervalSince1970: $0.timestamp) } ?? clock()
        let service = persistence
        Task { try? await service?.createRunRecord(runID: runID, startTimestamp: startTimestamp) }
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
            let service = persistence
            let endTime = clock()
            Task { try? await service?.finalizeRunRecord(runID: runID, endTimestamp: endTime) }
        }
        currentRunID = nil
        state = .chairlift
        pendingRunEndAt = nil
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
            try? await persistence?.finalizeRunRecord(runID: runID, endTimestamp: clock())
        }
        resetAllState()
    }
}

// MARK: - PersistenceService conformance

extension PersistenceService: PersistenceServiceProtocol {}
