---
phase: 01-motion-engine-and-session-foundation
plan: GAP-01
type: execute
wave: 1
depends_on: []
files_modified:
  - ArcticEdgeTests/Motion/MotionManagerTests.swift
  - ArcticEdgeTests/Motion/StreamBroadcasterTests.swift
autonomous: true
gap_closure: true
requirements:
  - MOTN-01
  - MOTN-04

must_haves:
  truths:
    - "testStartEmitsFrames delivers 3 mock frames through the pipeline and asserts 3 FilteredFrames in the RingBuffer"
    - "testConsumerCancellationCleansUp holds streams in named locals so ARC does not fire onTermination before the afterTwo assertion"
  artifacts:
    - path: "ArcticEdgeTests/Motion/MotionManagerTests.swift"
      provides: "MockMotionDataSource with stored handler and deliverMockMotion(); updated testStartEmitsFrames asserting frame count"
      contains: "nonisolated(unsafe) var handler: CMDeviceMotionHandler?"
    - path: "ArcticEdgeTests/Motion/StreamBroadcasterTests.swift"
      provides: "testConsumerCancellationCleansUp using named stream locals"
      contains: "let s1 = await broadcaster2.makeStream()"
  key_links:
    - from: "MockMotionDataSource.deliverMockMotion()"
      to: "RingBuffer.count"
      via: "stored handler -> MotionManager.receive() -> RingBuffer.append()"
      pattern: "handler\\?\\(CMDeviceMotion\\(\\)"
    - from: "let s1 / let s2"
      to: "broadcaster2.continuationCount"
      via: "named locals prevent ARC-triggered onTermination before assertion"
      pattern: "let s[12] = await broadcaster2\\.makeStream\\(\\)"
---

<objective>
Close two test coverage gaps identified in 01-VERIFICATION.md that prevent MOTN-01 and MOTN-04 from reaching full automated confidence.

Purpose: Both gaps are in test files only. The production pipeline is correct. Fixing them gives the verifier evidence that frames actually flow end-to-end through the CoreMotion bridge and that the continuation count assertion in the cancellation test is reliable.

Output:
- MotionManagerTests.swift: MockMotionDataSource stores the CMDeviceMotionHandler; testStartEmitsFrames delivers 3 mock frames and asserts 3 frames in the RingBuffer.
- StreamBroadcasterTests.swift: testConsumerCancellationCleansUp uses named locals for both streams, preventing immediate ARC deallocation.
</objective>

<execution_context>
@/Users/avosarkissian/.claude/get-shit-done/workflows/execute-plan.md
@/Users/avosarkissian/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/ROADMAP.md
@.planning/STATE.md
@.planning/phases/01-motion-engine-and-session-foundation/01-VERIFICATION.md

<interfaces>
From ArcticEdge/Motion/MotionManager.swift:

```swift
// MotionDataSource protocol
protocol MotionDataSource: AnyObject {
    nonisolated var deviceMotionUpdateInterval: Double { get set }
    nonisolated func startDeviceMotionUpdates(to queue: OperationQueue, withHandler handler: @escaping CMDeviceMotionHandler)
    nonisolated func stopDeviceMotionUpdates()
}

// MotionManager actor - relevant public surface
actor MotionManager {
    init(dataSource: any MotionDataSource, ringBuffer: RingBuffer, broadcaster: StreamBroadcaster? = nil)
    func setStreamBroadcaster(_ broadcaster: StreamBroadcaster)
    func startUpdates(runID: UUID)
    func stopUpdates()
    func adjustSampleRate(for state: ProcessInfo.ThermalState)
}
// receive() is private; tests reach it only via the stored CMDeviceMotionHandler callback.

// RingBuffer actor - public surface used in tests
actor RingBuffer {
    func append(_ frame: FilteredFrame)
    func drain() -> [FilteredFrame]
    var count: Int { get }
}

// StreamBroadcaster actor - public surface
actor StreamBroadcaster {
    init(motionManager: MotionManager)
    func makeStream() -> AsyncStream<FilteredFrame>
    func broadcast(_ frame: FilteredFrame)
    func start(runID: UUID)
    func stop()
    var continuationCount: Int { get }
}
```

CMDeviceMotionHandler type alias (from CoreMotion):
```swift
typealias CMDeviceMotionHandler = (CMDeviceMotion?, Error?) -> Void
```

CMDeviceMotion() can be instantiated with its default Objective-C init.
All IMU fields on the resulting instance default to 0.0, which is valid for test purposes.
The MotionManager.receive() method accepts 0.0 for all primitive fields and will produce
a FilteredFrame with filteredAccelZ = BiquadHighPassFilter.apply(0.0), which is also 0.0
for a zero-input signal. The frame is still appended to the RingBuffer normally.
</interfaces>
</context>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: Fix MockMotionDataSource to store handler and add deliverMockMotion</name>
  <files>ArcticEdgeTests/Motion/MotionManagerTests.swift</files>
  <behavior>
    - MockMotionDataSource.startDeviceMotionUpdates stores the handler parameter instead of discarding it
    - MockMotionDataSource.deliverMockMotion() invokes the stored handler with CMDeviceMotion() and nil error
    - testStartEmitsFrames calls deliverMockMotion() 3 times after startUpdates, then awaits briefly for the async Task bridge in MotionManager to complete, then asserts ringBuffer.count == 3
    - The existing assertions (startCallCount == 1, interval == 0.01) are preserved alongside the new frame count assertion
  </behavior>
  <action>
Edit MockMotionDataSource in MotionManagerTests.swift:

1. Add a stored handler property:
   ```swift
   nonisolated(unsafe) var handler: CMDeviceMotionHandler?
   ```

2. Update startDeviceMotionUpdates to store the handler:
   ```swift
   nonisolated func startDeviceMotionUpdates(
       to queue: OperationQueue,
       withHandler handler: @escaping CMDeviceMotionHandler
   ) {
       startCallCount += 1
       self.handler = handler
   }
   ```

3. Add deliverMockMotion():
   ```swift
   nonisolated func deliverMockMotion() {
       handler?(CMDeviceMotion(), nil)
   }
   ```

4. Update testStartEmitsFrames to deliver 3 frames and assert on RingBuffer count.
   The MotionManager.receive() method is called via Task { await self.receive(...) } inside the
   CoreMotion callback. After calling deliverMockMotion() 3 times, yield to the cooperative
   scheduler long enough for those Task closures to execute before reading ringBuffer.count.
   A short Task.sleep or a brief loop of Task.yield() calls is sufficient.

   Expose the RingBuffer from makeManager() so the test can read its count, OR restructure
   makeManager() to return a named RingBuffer:

   ```swift
   private func makeManager() -> (MotionManager, MockMotionDataSource, RingBuffer) {
       let mockSource = MockMotionDataSource()
       let ringBuffer = RingBuffer()
       let manager = MotionManager(dataSource: mockSource, ringBuffer: ringBuffer)
       return (manager, mockSource, ringBuffer)
   }
   ```

   Updated testStartEmitsFrames:
   ```swift
   @Test("startUpdates stores handler and emits 3 FilteredFrames into RingBuffer")
   func testStartEmitsFrames() async throws {
       let (manager, mockSource, ringBuffer) = makeManager()
       let runID = UUID()
       await manager.startUpdates(runID: runID)

       #expect(mockSource.startCallCount == 1, "startDeviceMotionUpdates should be called exactly once")
       #expect(mockSource.deviceMotionUpdateInterval == 0.01, "interval should be 0.01 for 100Hz")

       // Deliver 3 mock frames through the stored handler.
       mockSource.deliverMockMotion()
       mockSource.deliverMockMotion()
       mockSource.deliverMockMotion()

       // Yield to the cooperative scheduler so the 3 Task { await self.receive(...) }
       // closures spawned inside the CMDeviceMotionHandler can complete.
       try await Task.sleep(for: .milliseconds(50))

       let count = await ringBuffer.count
       #expect(count == 3, "RingBuffer should contain 3 frames after 3 mock deliveries, got \(count)")
   }
   ```

   Update all other test functions that call makeManager() to handle the now-3-element tuple.
   Those tests do not use the ringBuffer return value, so change:
     `let (manager, mockSource) = makeManager()`
   to:
     `let (manager, mockSource, _) = makeManager()`

   Do not change the logic or assertions in any other test function.

CONSTRAINTS:
- Do not use XCTest. All tests use `import Testing` with `@Test` and `#expect`.
- Do not use `@unchecked Sendable` removal; keep it as-is to satisfy strict concurrency.
- No em-dashes in comments.
- The CMDeviceMotion() default init produces zero-valued IMU fields. That is acceptable for
  this test: the goal is to confirm frames arrive, not to verify specific field values.
- Task.sleep(for: .milliseconds(50)) is sufficient; do not use arbitrary large sleeps.
  If the CI environment is slow, prefer .milliseconds(100) as a safe upper bound.
  </action>
  <verify>
    <automated>xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:'ArcticEdgeTests/MotionManagerTests' 2>&1 | grep -E "(PASSED|FAILED|error:|warning: )" | head -30</automated>
  </verify>
  <done>All 4 MotionManagerTests pass: testStartEmitsFrames asserts startCallCount == 1, interval == 0.01, and ringBuffer.count == 3. The 3 thermal interval tests are unaffected.</done>
</task>

<task type="auto">
  <name>Task 2: Fix ARC race in testConsumerCancellationCleansUp</name>
  <files>ArcticEdgeTests/Motion/StreamBroadcasterTests.swift</files>
  <action>
Edit testConsumerCancellationCleansUp in StreamBroadcasterTests.swift.

Change lines 89-90 from:
```swift
_ = await broadcaster2.makeStream()
_ = await broadcaster2.makeStream()
```

To:
```swift
let s1 = await broadcaster2.makeStream()
let s2 = await broadcaster2.makeStream()
```

Then add a `withExtendedLifetime` guard or simply reference the streams after the assertion
to ensure the compiler does not optimize them away. The simplest approach is to add a
`_ = (s1, s2)` line after the afterStop assertion so both are kept in scope through the
end of the test function body.

Full corrected test:
```swift
@Test("Cancelling one consumer stream does not affect the other")
func testConsumerCancellationCleansUp() async {
    let mockSource2 = MockMotionDataSource()
    let manager2 = MotionManager(dataSource: mockSource2, ringBuffer: RingBuffer())
    let broadcaster2 = StreamBroadcaster(motionManager: manager2)
    await manager2.setStreamBroadcaster(broadcaster2)

    // Assign streams to named locals so ARC does not fire onTermination immediately.
    let s1 = await broadcaster2.makeStream()
    let s2 = await broadcaster2.makeStream()
    let afterTwo = await broadcaster2.continuationCount
    #expect(afterTwo == 2, "Should have 2 active continuations after makeStream x2, got \(afterTwo)")

    await broadcaster2.stop()
    let afterStop = await broadcaster2.continuationCount
    #expect(afterStop == 0, "All continuations should be removed after stop(), got \(afterStop)")

    // Keep s1 and s2 in scope until after all assertions complete.
    _ = (s1, s2)
}
```

Do not change any other test in this file.

CONSTRAINTS:
- Do not use XCTest. Keep `import Testing`.
- No em-dashes in comments.
- The test name string ("Cancelling one consumer stream does not affect the other") must remain unchanged to preserve documentation continuity with the VERIFICATION.md reference.
  </action>
  <verify>
    <automated>xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:'ArcticEdgeTests/StreamBroadcasterTests' 2>&1 | grep -E "(PASSED|FAILED|error:|warning: )" | head -30</automated>
  </verify>
  <done>All 3 StreamBroadcasterTests pass: testConsumerCancellationCleansUp now observes afterTwo == 2 (not 1), and afterStop == 0. testTwoConsumersReceiveSameFrames and testSingleMotionManagerStart are unaffected.</done>
</task>

</tasks>

<verification>
Run the full Motion test suite after both tasks complete to confirm no regressions:

```
xcodebuild test -scheme ArcticEdge -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:'ArcticEdgeTests/MotionManagerTests' -only-testing:'ArcticEdgeTests/StreamBroadcasterTests' 2>&1 | tail -20
```

Expected: 7 tests total, all PASSED.
- MotionManagerTests (4): testStartEmitsFrames, testThermalNominalIs100Hz, testThermalSeriousIs50Hz, testThermalCriticalIs25Hz
- StreamBroadcasterTests (3): testTwoConsumersReceiveSameFrames, testSingleMotionManagerStart, testConsumerCancellationCleansUp

Build must compile with zero errors and zero warnings under SWIFT_STRICT_CONCURRENCY = complete.
</verification>

<success_criteria>
- MOTN-01 status upgrades from PARTIAL to SATISFIED: testStartEmitsFrames asserts 3 FilteredFrames in RingBuffer after 3 mock deliveries
- MOTN-04 status upgrades from PARTIAL to SATISFIED: testConsumerCancellationCleansUp reliably observes afterTwo == 2
- All 7 Motion tests pass in the iOS Simulator
- Zero new compiler warnings introduced
- No changes to any production source file (ArcticEdge/ not ArcticEdgeTests/)
</success_criteria>

<output>
After completion, create `.planning/phases/01-motion-engine-and-session-foundation/01-GAP-01-SUMMARY.md`
</output>
