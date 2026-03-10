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

    /// Chairlift GPS speed range (m/s)
    private let liftSpeedMin: Double = 0.5
    private let liftSpeedMax: Double = 7.0

    /// Skiing minimum GPS speed (m/s)
    private let skiingSpeedMin: Double = 3.0

    /// G-force variance thresholds (g²)
    private let lowVarianceThreshold: Double = 0.01     // chairlift: variance < this
    private let highVarianceThreshold: Double = 0.005   // skiing:    variance > this

    // MARK: - Injectable clock

    private let clock: @Sendable () -> Date

    // MARK: - Mutable state

    private(set) var state: ClassifierState = .idle
    private var pendingSkiingOnsetAt: Date? = nil
    private var pendingRunEndAt: Date? = nil
    private var pendingFrames: [FilteredFrame] = []
    private(set) var currentRunID: UUID? = nil

    private var varianceWindow: [Double] = []
    private(set) var latestGPS: GPSReading? = nil
    private(set) var latestActivity: ActivitySnapshot? = nil

    private var consumptionTasks: [Task<Void, Never>] = []

    /// Boxed persistence service — holds any PersistenceServiceProtocol-conforming actor.
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
        self.persistence = persistenceService
        state = .chairlift
        launchConsumptionTasks(frameStream: frameStream, gpsStream: gpsStream, activityStream: activityStream)
    }

    private func launchConsumptionTasks(
        frameStream: AsyncStream<FilteredFrame>,
        gpsStream: AsyncStream<GPSReading>,
        activityStream: AsyncStream<ActivitySnapshot>
    ) {
        let gpsTask = Task { [weak self] in
            for await gps in gpsStream {
                await self?.updateGPS(gps)
            }
        }
        let activityTask = Task { [weak self] in
            for await activity in activityStream {
                await self?.updateActivity(activity)
            }
        }
        let frameTask = Task { [weak self] in
            for await frame in frameStream {
                await self?.processFrame(frame)
            }
        }
        consumptionTasks = [gpsTask, activityTask, frameTask]
    }

    /// Tears down the classifier and finalizes any open RunRecord.
    func endDay() async {
        for task in consumptionTasks {
            task.cancel()
        }
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

    // MARK: - Stream update helpers

    private func updateGPS(_ gps: GPSReading) {
        latestGPS = gps
    }

    private func updateActivity(_ activity: ActivitySnapshot) {
        latestActivity = activity
    }

    // MARK: - Frame processing

    func processFrame(_ frame: FilteredFrame) async {
        // Update g-force variance window with the magnitude of user acceleration.
        let g = (frame.userAccelX * frame.userAccelX +
                 frame.userAccelY * frame.userAccelY +
                 frame.userAccelZ * frame.userAccelZ).squareRoot()
        varianceWindow.append(g)
        if varianceWindow.count > varianceWindowSize {
            varianceWindow.removeFirst()
        }

        let now = clock()

        switch state {
        case .chairlift:
            evaluateSkiingOnset(frame: frame, now: now)
        case .skiing:
            evaluateRunEnd(now: now)
        case .idle:
            break
        }
    }

    // MARK: - Skiing onset

    private func evaluateSkiingOnset(frame: FilteredFrame, now: Date) {
        if skiingSignalActive() {
            if pendingSkiingOnsetAt == nil {
                pendingSkiingOnsetAt = now
            }
            let elapsed = now.timeIntervalSince(pendingSkiingOnsetAt!)
            if elapsed >= skiingOnsetSeconds {
                confirmSkiingTransition()
            } else {
                pendingFrames.append(frame)
            }
        } else {
            pendingSkiingOnsetAt = nil
            pendingFrames = []
        }
    }

    private func confirmSkiingTransition() {
        let runID = UUID()
        currentRunID = runID

        let startTimestamp: Date
        if let firstFrame = pendingFrames.first {
            startTimestamp = Date(timeIntervalSince1970: firstFrame.timestamp)
        } else {
            startTimestamp = clock()
        }

        let service = persistence
        Task {
            try? await service?.createRunRecord(runID: runID, startTimestamp: startTimestamp)
        }

        state = .skiing
        pendingSkiingOnsetAt = nil
        pendingFrames = []
    }

    // MARK: - Run end

    private func evaluateRunEnd(now: Date) {
        if chairliftSignalActive(at: now) {
            if pendingRunEndAt == nil {
                pendingRunEndAt = now
            }
            if now.timeIntervalSince(pendingRunEndAt!) >= runEndSeconds {
                confirmChairliftTransition()
            }
        } else {
            pendingRunEndAt = nil
        }
    }

    private func confirmChairliftTransition() {
        if let runID = currentRunID {
            let service = persistence
            let endTime = clock()
            Task {
                try? await service?.finalizeRunRecord(runID: runID, endTimestamp: endTime)
            }
        }
        currentRunID = nil
        state = .chairlift
        pendingRunEndAt = nil
    }

    // MARK: - Signal predicates

    /// True when all three chairlift signals are active (or GPS is blacked out in chairlift state).
    func chairliftSignalActive(at now: Date) -> Bool {
        // Signal 1: automotive motion activity with medium or high confidence.
        let isAutomotive = (latestActivity?.automotive == true) &&
                           (latestActivity?.confidence != .low)

        // Signal 2: GPS speed in lift range, with blackout tolerance in chairlift state.
        let speedInLiftRange: Bool
        let gpsBlackout = latestGPS == nil || (latestGPS?.horizontalAccuracy ?? -1) < 0
        if gpsBlackout {
            // Waive the GPS gate while in chairlift state (tunnel / tree cover tolerance).
            speedInLiftRange = (state == .chairlift)
        } else {
            let speed = latestGPS!.speed
            speedInLiftRange = speed >= liftSpeedMin && speed <= liftSpeedMax
        }

        // Signal 3: Low g-force variance (smooth chairlift ride).
        let isLowVariance = gForceVariance < lowVarianceThreshold

        return isAutomotive && speedInLiftRange && isLowVariance
    }

    /// True when skiing signals are active: high speed, high variance, not automotive.
    func skiingSignalActive() -> Bool {
        // Signal 1: GPS speed at or above skiing threshold, or GPS unavailable.
        let speedOK: Bool
        let gpsBlackout = latestGPS == nil || (latestGPS?.horizontalAccuracy ?? -1) < 0
        if gpsBlackout {
            speedOK = true
        } else {
            speedOK = latestGPS!.speed >= skiingSpeedMin
        }

        // Signal 2: High g-force variance (dynamic carving motion).
        let isHighVariance = gForceVariance > highVarianceThreshold

        // Signal 3: Not automotive (or low-confidence automotive classification).
        let notAutomotive = !(latestActivity?.automotive ?? false) ||
                            (latestActivity?.confidence == .low)

        return speedOK && isHighVariance && notAutomotive
    }

    // MARK: - G-force variance

    /// Sample variance of the g-force magnitude window. Returns 0 when fewer than 2 samples.
    var gForceVariance: Double {
        guard varianceWindow.count > 1 else { return 0.0 }
        let count = Double(varianceWindow.count)
        let mean = varianceWindow.reduce(0.0, +) / count
        let sumSq = varianceWindow.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
        return sumSq / (count - 1)
    }

    // MARK: - Test support helpers
    //
    // These methods are internal (not private) so @testable imports can drive the classifier
    // without requiring a real PersistenceService (@ModelActor needs a ModelContainer).

    /// Directly override classifier state — for test setup only.
    func setState(_ newState: ClassifierState) {
        state = newState
    }

    /// Directly set the latest GPS reading — for test setup only.
    func setGPS(_ reading: GPSReading?) {
        latestGPS = reading
    }

    /// Directly set the latest activity snapshot — for test setup only.
    func setActivity(_ snapshot: ActivitySnapshot) {
        latestActivity = snapshot
    }

    /// Directly set a mock persistence service — for test setup only.
    func setPersistence(_ service: any PersistenceServiceProtocol) {
        persistence = service
    }

    /// Directly set the current run ID — for test setup only.
    func setCurrentRunID(_ id: UUID) {
        currentRunID = id
    }

    /// endDay variant that accepts a mock persistence service directly — for test setup only.
    func endDayWithPersistence(_ service: any PersistenceServiceProtocol) async {
        persistence = service
        for task in consumptionTasks {
            task.cancel()
        }
        consumptionTasks = []

        if state == .skiing, let runID = currentRunID {
            try? await persistence?.finalizeRunRecord(runID: runID, endTimestamp: clock())
        }

        resetAllState()
    }
}

// MARK: - PersistenceService conformance

extension PersistenceService: PersistenceServiceProtocol {}
