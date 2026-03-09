# Deferred Items

## Out-of-scope issues discovered during 01-02 execution

### 1. StreamBroadcasterTests: testConsumerCancellationCleansUp - flaky/failing

**Discovered during:** Task 3 (full test suite run)
**Test file:** ArcticEdgeTests/Motion/StreamBroadcasterTests.swift:92
**Symptom:** `afterTwo == 1` instead of `2` - one continuation is cleaned up immediately

**Root cause:** `_ = await broadcaster2.makeStream()` discards the returned AsyncStream immediately.
The stream is ARC-deallocated, triggering `onTermination` which removes the continuation.
This is a race between ARC and the actor's removeContinuation task.

**Not caused by:** Plan 01-02 changes.
**Plan 01-01 status:** Listed as "fixed with .serialized" but the underlying discarded-stream issue wasn't addressed.

**Fix:** Store the streams in a local variable: `let s1 = await broadcaster2.makeStream()` and
keep `s1` in scope until after the count assertion. Out of scope for 01-02.
