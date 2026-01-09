# Session: Accuracy and Stability Fixes

**Date:** 2026-01-09 14:45 UTC
**Duration:** ~1 hour
**Status:** ✅ Complete

## Objective

Fix two critical issues:
1. Improve transcription accuracy (missed words/phrases)
2. Eliminate race condition crashes

## Changes Made

### 1. Accuracy Improvement: 160ms → 320ms Chunk Size

**Problem:**
- Parakeet EOU 120M with 160ms chunks was fast but missed words during dictation
- Users experiencing frustration with inaccurate transcription

**Solution:**
- Switched to 320ms chunk size for more context per inference (same 120M model)
- Changes in `TranscriptionEngine.swift:141,147`
- Changed `Repo.parakeetEou160` → `Repo.parakeetEou320`
- **Critical fix:** Also changed `chunkSize: .ms160` → `chunkSize: .ms320` to match model

**Files Modified:**
- [TranscriptionEngine.swift](../../packages/app/Yappatron/Sources/TranscriptionEngine.swift)
  - Line 138: Model path uses 320M folder
  - Line 157: Model download uses 320M variant
  - Line 147: Updated comment

**Trade-offs:**
- Larger model download on first run
- Potentially higher memory usage
- May have slightly higher latency (to be tested)
- Expected: Much better word recognition

### 2. Stability Fix: Race Condition in Audio Processing

**Problem:**
- Random crashes during use: `StreamingEouAsrManager.process()` → `removeFirst(_:)`
- FluidAudio's internal buffer not thread-safe
- Previous mitigation (serial queue + semaphore) blocked audio thread → audio glitches

**Solution:**
- Implemented actor-based buffer queue pattern
- Created `AudioBufferQueue` actor for thread-safe operations
- Decoupled audio capture from processing:
  - Audio callback enqueues buffers asynchronously (never blocks)
  - Separate Task processes buffers serially
  - Proper buffer copying prevents data races
  - Queue size limit (100) prevents unbounded growth

**Files Modified:**
- [TranscriptionEngine.swift](../../packages/app/Yappatron/Sources/TranscriptionEngine.swift)
  - Lines 17-57: Added `AudioBufferQueue` actor
  - Lines 46-48: Replaced serial queue with buffer queue
  - Lines 280-361: Refactored `processAudioBuffer()` to use queue
  - Lines 363-387: Added `startAudioProcessing()` and `stopAudioProcessing()`
  - Line 169: Start processing task on initialization
  - Line 391: Stop processing task on cleanup

**Architecture:**
```
Audio Input → Convert to 16kHz → Enqueue (async, non-blocking)
                                      ↓
                           AudioBufferQueue (actor)
                                      ↓
                          Processing Task (serial loop)
                                      ↓
                          StreamingEouAsrManager.process()
```

**Benefits:**
- Audio thread never blocks
- Serial processing guaranteed (no race conditions)
- Graceful overflow handling (drops oldest if full)
- Clean separation of concerns

## Build Results

```bash
cd packages/app/Yappatron
swift build
# Build complete! (2.72s)
```

No compilation errors, all warnings are pre-existing resource declarations.

## Testing Results

### Accuracy Testing
- ✅ Compare transcription quality with 160ms vs 320ms - **320ms noticeably better**
- ✅ Test difficult phrases - **Better context-aware decisions (e.g., "to do" vs "todo")**
- ✅ Measure latency impact on ghost text - **Slightly slower but acceptable trade-off**
- ⏳ Monitor Neural Engine utilization - **Not yet measured**

### Stability Testing
- ⏳ Extended runtime test (multiple hours) - **In progress, no crashes yet**
- ✅ High-volume dictation test - **Working well during testing**
- ✅ Monitor for crashes/hangs - **No issues observed**
- ⏳ Check memory usage over time - **Not yet measured**
- ✅ Verify queue doesn't grow unbounded - **Max size of 100 enforced**

### User Verdict
- "Quite accurate now" - passes user's quality bar
- Speed/accuracy balance is good
- System ready for daily use

## Next Steps

1. **Deploy and test** - Run with real workloads
2. **Collect metrics** - Accuracy, latency, memory, stability
3. **User feedback** - Is accuracy noticeably better?
4. **Consider making model configurable** - Let users choose 120M vs 320M based on preference

## Memory Bank Updates

- ✅ Updated [activeWork.md](../02-active/activeWork.md)
- ✅ Updated [blockers.md](../02-active/blockers.md)
- ✅ Updated [yap-320m-accuracy.md](../02-active/yap-320m-accuracy.md)
- ✅ Created this session document

## Technical Notes

### Why Actor Pattern vs. Semaphore?

**Old approach (failed):**
```swift
processingQueue.async {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        await process(buffer)
        semaphore.signal()
    }
    semaphore.wait() // ❌ Blocks audio thread
}
```

**New approach (correct):**
```swift
// Audio thread (never blocks)
Task { await audioBufferQueue.enqueue(buffer) }

// Processing task (runs independently)
Task {
    while true {
        if let buffer = await audioBufferQueue.dequeue() {
            await process(buffer)
        }
    }
}
```

### Buffer Copying is Critical

```swift
// Must copy buffer data - original may be reused by AVFoundation
guard let copy = AVAudioPCMBuffer(...) else { return }
copy.frameLength = buffer.frameLength
memcpy(dstData[channel], srcData[channel], frameLength * MemoryLayout<Float>.size)
```

Without copying, we'd have data races as AVFoundation reuses buffers.

## References

- [FluidAudio Repo enum](https://github.com/FluidGroup/FluidAudio)
- [Swift Actors documentation](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html#ID645)
- [AVAudioEngine buffer management](https://developer.apple.com/documentation/avfaudio/avaudioengine)
