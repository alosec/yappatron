# Dual-Pass ASR Processing

**Created:** 2026-01-09
**Updated:** 2026-01-09
**Status:** ✅ IMPLEMENTED - Optional Toggle (Disabled by Default)

## Concept

Run ASR twice on the same audio for both speed and accuracy:

1. **First Pass (Real-time Streaming):** Parakeet EOU 120M
   - Fast, low-latency streaming (~80-160ms chunks)
   - Shows unpunctuated text immediately
   - Maintains real-time "ghost text" feel
   - ~5.73% WER (good but not perfect)

2. **Second Pass (Batch Re-processing):** Parakeet TDT 0.6b
   - Triggered on EOU detection
   - Processes saved audio chunk with larger, more accurate model
   - 600M parameters vs 120M (5x larger)
   - Potentially better accuracy
   - **Unknown:** Does it output punctuation?

## Architecture

```
Audio Input → Buffer + Stream
                 ↓              ↓
            Save chunks    First Pass (Streaming)
                 ↓         Parakeet EOU 120M
                 ↓              ↓
                 ↓         Display unpunctuated
                 ↓         (fast, ~5.73% WER)
                 ↓              ↓
            [EOU Detected] ←────┘
                 ↓
          Second Pass (Batch)
          Parakeet TDT 0.6b
          Process saved audio
                 ↓
          Better accuracy
          + Punctuation (?)
                 ↓
          Replace text in-place
          (InputSimulator.applyTextUpdate)
```

## Comparison to Single-Pass Punctuation

### Single-Pass Approach (Punctuation Model Only)
```
Stream EOU 120M → Unpunctuated text
                      ↓
                  [On EOU]
                      ↓
              Punctuation model
              (text → text)
                      ↓
              Add punctuation
              Same accuracy
```

### Dual-Pass Approach (Batch Re-processing)
```
Stream EOU 120M → Unpunctuated text (~5.73% WER)
                      ↓
                  [On EOU]
                      ↓
              TDT 0.6b (batch)
              (audio → text)
                      ↓
              Better accuracy + punctuation (?)
```

## Trade-offs

| Aspect | Single-Pass (Punctuation) | Dual-Pass (Batch ASR) |
|--------|---------------------------|----------------------|
| **Accuracy improvement** | ❌ No (same ASR) | ✅ Yes (larger model) |
| **Punctuation** | ✅ Yes (dedicated model) | ❓ Unknown (TDT might not output) |
| **Latency** | ⚡ Fast (~50-200ms) | 🐢 Slower (batch processing) |
| **Memory** | 💚 Lower (one ASR model) | 🟡 Higher (audio buffering) |
| **Complexity** | 💚 Simpler (one ASR) | 🟡 More complex (two ASR) |
| **Power usage** | 💚 Lower (ASR once) | 🟡 Higher (ASR twice) |
| **Flexibility** | ✅ Style variants (formal/casual) | ❌ Fixed output from model |

## ✅ VERIFIED: TDT Outputs Punctuation!

**Finding:** Parakeet TDT 0.6b v3 **DOES output punctuation and capitalization**.

**Source:** [NVIDIA Parakeet TDT 0.6b v3 Model Card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)

### Key Details from Documentation:

**Stated Features:**
> "Automatic **punctuation** and **capitalization**"

**Output Format:**
> **Output Type(s):** Text
> **Output Format:** String
> **Output Parameters:** 1D (text)
> **Other Properties Related to Output:** **Punctuations and Capitalizations included.**

**Training Data:**
> "All transcriptions preserve punctuation and capitalization."

**WER Calculation Note:**
> WERs are calculated after **removing Punctuation and Capitalization from reference and predicted text**.

### Implications:

✅ **Dual-pass solves BOTH problems:**
- Improved accuracy (600M params vs 120M params)
- Punctuation and capitalization (native from model)

✅ **No separate punctuation model needed**
- Simpler architecture
- Single post-processing step
- Lower latency (one model, not two)

✅ **Implementation decision: CONFIRMED**
- Dual-pass is the clear winner
- One solution for both accuracy and formatting
- Worth the added complexity

## User Context: Previous Whisper Approach

> "Like how we previously were just using whisper which collects the whole audio chunk"

The Python prototype used Whisper in batch mode. Key differences:

**Previous (Whisper batch):**
- Wait for complete utterance
- Process entire audio chunk
- Display text once (with punctuation)
- No streaming, higher perceived latency

**Proposed (Dual-pass):**
- Stream first (fast, unpunctuated)
- Re-process on EOU (accurate, punctuated)
- User sees text immediately, then refinement
- Best of both worlds: speed + accuracy

## Implementation Considerations

### Audio Buffering
Need to save audio chunks during streaming:

```swift
class AudioChunkBuffer {
    private var currentUtteranceAudio: [AVAudioPCMBuffer] = []

    func append(_ buffer: AVAudioPCMBuffer) {
        // Save buffer for potential re-processing
        currentUtteranceAudio.append(copyBuffer(buffer))
    }

    func getCompleteUtterance() -> AVAudioPCMBuffer? {
        // Concatenate all buffers into single chunk
        return concatenate(currentUtteranceAudio)
    }

    func clear() {
        currentUtteranceAudio.removeAll()
    }
}
```

### Memory Management
- **Per utterance:** ~5-10 seconds of audio at 16kHz mono Float32
- **Memory usage:** ~5s × 16000 samples × 4 bytes = ~320KB per utterance
- **Acceptable:** Not significant overhead
- **Cleanup:** Clear buffer after processing to prevent accumulation

### Batch Processing Integration
FluidAudio supports batch processing with TDT models:

```swift
// Load batch TDT model (separate from streaming)
let batchManager = try await BatchAsrManager.load(.parakeetTdt0_6bV3)

// On EOU, re-process saved audio
let audioChunk = audioBuffer.getCompleteUtterance()
let refinedText = try await batchManager.transcribe(audioChunk)

// Replace streamed text with refined version
inputSimulator.applyTextUpdate(from: streamedText, to: refinedText)
audioBuffer.clear()
```

### Performance Concerns

**Latency:**
- TDT 0.6b: ~110× RTF on M4 Pro (1 min audio ≈ 0.5s)
- 5-10s utterance: ~50-100ms batch processing time
- **Acceptable:** Within <200ms target if optimized

**Neural Engine Contention:**
- Streaming ASR already uses ANE
- Batch processing would compete for ANE resources
- **Mitigation:** Run batch on CPU if ANE busy, or queue sequentially

### Optional Setting
Make dual-pass optional:

```swift
enum TranscriptionMode {
    case fastOnly        // Streaming only (current behavior)
    case accurateRefine  // Streaming + batch refinement
}

// User preference
var transcriptionMode: TranscriptionMode = .fastOnly
```

**Use cases:**
- **Fast only:** Low-power mode, battery sensitive, casual use
- **Accurate refine:** Dictating important documents, formal writing

## Implementation Status

### ✅ Phase 1: Research & Verification (COMPLETE)

1. **✅ Verified TDT punctuation output** (critical!)
   - ✅ Confirmed via NVIDIA model card documentation
   - ✅ Model outputs punctuation and capitalization natively
   - ✅ Decision: Dual-pass approach is optimal

### ✅ Phase 2: Core Implementation (COMPLETE)

All core components implemented and building successfully:

   - ✅ Created `AudioChunkBuffer` actor in [TranscriptionEngine.swift:58-102](../../packages/app/Yappatron/Sources/TranscriptionEngine.swift#L58-L102)
   - ✅ Integrated with audio capture pipeline (saves buffers during streaming)
   - ✅ Provides `getAsSamples()` to concatenate buffers into Float array

3. **✅ Created batch processor**
   - ✅ Implemented `BatchProcessor` actor in [BatchProcessor.swift](../../packages/app/Yappatron/Sources/BatchProcessor.swift)
   - ✅ Loads Parakeet TDT 0.6b v3 models using FluidAudio's `AsrModels.downloadAndLoad(version: .v3)`
   - ✅ Provides async `transcribe(_ samples: [Float])` method
   - ✅ Logs latency and RTF for monitoring

4. **✅ Created refinement coordinator**
   - ✅ Implemented `TextRefinementManager` in [TextRefinementManager.swift](../../packages/app/Yappatron/Sources/TextRefinementManager.swift)
   - ✅ Coordinates streaming → batch workflow
   - ✅ Uses existing `InputSimulator.applyTextUpdate()` for text replacement
   - ✅ Detects whether changes are accuracy improvements or just formatting

5. **✅ Integrated with app**
   - ✅ Modified [YappatronApp.swift](../../packages/app/Yappatron/Sources/YappatronApp.swift) to initialize components
   - ✅ Wired up `engine.onUtteranceComplete` callback to trigger refinement
   - ✅ Added `handleRefinementComplete()` to finalize utterance after batch processing
   - ✅ Batch processor initialization runs in parallel with streaming models

6. **✅ Build successful**
   - ✅ All compilation errors resolved
   - ✅ Project builds cleanly with dual-pass system integrated

### ✅ Phase 3: Testing & Validation (COMPLETE)

**Status:** Successfully tested with real-world dictation (2026-01-09 evening)

1. **✅ Real usage testing**
   - ✅ Both models load successfully (streaming + batch)
   - ✅ Text replacement works smoothly
   - ✅ No runtime errors encountered
   - ✅ System handles natural speech patterns with pauses

2. **✅ Quality evaluation**
   - ✅ Punctuation quality: Excellent (periods, commas, capitalization)
   - ✅ Accuracy: Improved from streaming model
   - ✅ Multi-sentence utterances: Handled correctly
   - ✅ EOU detection: 800ms debounce working well (doesn't cut off mid-thought)

3. **✅ UX evaluation**
   - ✅ Text replacement is NOT jarring - described as "really cool effect"
   - ✅ Delete/retype animation works well
   - ✅ Delays acceptable - EOU debounce takes "a little bit while" but necessary for natural pauses
   - ✅ Overall UX: "Really close to exactly what we were hoping to enable"
   - ✅ User verdict: "Really quite impressive"

### Key Observations from Testing

**What Works Well:**
- Immediate streaming text maintains real-time feel
- Smooth refinement with delete/retype effect
- Punctuation and capitalization are accurate
- Multiple sentences in single utterance handled correctly
- Natural pauses don't trigger premature EOU

**EOU Detection Tradeoff:**
- Current: 800ms silence debounce (reduced from 1280ms)
- User feedback: Slight perceptible delay but necessary and acceptable
- Handles natural "um", "uh" pauses without cutting off
- Keeps complete thoughts together as single utterances

**Potential Future Improvements:**
- Could make EOU debounce configurable (user preference)
- Consider full context refinement (currently only refines last utterance)
- Visual feedback for when refinement is processing

### ⚠️ Phase 4: Optional Toggle Implementation (2026-01-09) - ACCURACY REGRESSION FOUND

**Status:** Implemented but currently experiencing accuracy degradation issues.

**Implementation:**
1. **✅ Menu bar toggle:** "Dual-Pass Refinement (Punctuation)"
   - Located in menu bar right-click menu
   - Defaults to OFF (fast streaming-only mode)
   - Shows checkmark when enabled
   - Requires app restart to take effect (user is informed via alert)

2. **✅ UserDefaults persistence:**
   - Setting stored in `enableDualPassRefinement` key
   - Persists across app restarts
   - Default value: `false` (disabled)

3. **✅ Conditional initialization:**
   - Batch processor only initialized when toggle is ON
   - Refinement manager only created when toggle is ON
   - No performance/memory overhead when disabled
   - Graceful fallback if batch processor fails to initialize

4. **✅ Dual behavior in handleFinalTranscription:**
   - **When disabled:** Immediate spacing/enter after EOU (current fast behavior)
   - **When enabled:** Wait for refinement, then add spacing/enter
   - Smooth transition between modes

**Commit:** 16ab51c - Reintroduce dual-pass refinement as optional menu toggle

### ✅ Phase 5: Root Cause Analysis & Fixes (2026-01-10)

**Status:** Root cause identified and fixes implemented, pending testing.

**Root Cause Identified:**

The toggle version had a critical timing bug not present in commit 161624b:

**The Bug (Line 451-453 in TranscriptionEngine.swift):**
```swift
if self.isSpeaking {
    await self.audioChunkBuffer?.append(buffer)  // Only saves AFTER speaking detected!
}
```

**The Problem:**
- Audio buffering only started AFTER `isSpeaking` flag was set
- `isSpeaking` is set in `handlePartialTranscription()` when first partial arrives
- By that time, ~100-300ms of initial audio has already been processed and lost
- Batch model receives incomplete audio → worse accuracy, cut-off beginnings, message loss

**Why Previous Always-On Version Worked:**
- Commit 161624b saved audio unconditionally from the start
- No dependency on `isSpeaking` flag timing
- Captured complete utterances

**Secondary Issues:**
1. Buffer clearing timing: Cleared at utterance START (async Task) instead of after refinement completes
2. Missing diagnostic logging: Hard to debug timing issues without state transition logs

**Fixes Implemented (2026-01-10):**

1. **✅ Fix 1: Unconditional Audio Buffering**
   - Changed Line 461 to always save audio chunks (no `if self.isSpeaking` condition)
   - Now captures complete utterances from the very beginning
   - Matches behavior of working commit 161624b
   - File: [TranscriptionEngine.swift:458-461](../../packages/app/Yappatron/Sources/TranscriptionEngine.swift#L458-L461)

2. **✅ Fix 2: Buffer Clearing Timing**
   - Moved buffer clear from `handlePartialTranscription()` to `handleFinalTranscription()`
   - Now clears AFTER refinement callback completes (Line 330)
   - Ensures callback has access to complete audio
   - Eliminates async timing race condition
   - File: [TranscriptionEngine.swift:328-331](../../packages/app/Yappatron/Sources/TranscriptionEngine.swift#L328-L331)

3. **✅ Fix 3: Diagnostic Logging**
   - Added logging for `isSpeaking` state transitions (Lines 276, 323)
   - Added warning when no audio samples captured (Line 308)
   - Added logging when refinement callback is skipped (Line 319)
   - Added logging when buffer is cleared (Line 331)
   - File: [TranscriptionEngine.swift](../../packages/app/Yappatron/Sources/TranscriptionEngine.swift)

**Expected Outcomes:**
- ✅ No more cut-off word beginnings (captures complete audio)
- ✅ Better accuracy (batch model has complete context)
- ✅ No message loss (complete utterances preserved)
- ✅ More reliable (no timing-dependent buffer clearing)
- ✅ Better debuggability (state transition logging)

### ✅ Phase 6: Testing & Validation (2026-01-10)

**Status:** Fixes tested and verified working!

**Test Results (2026-01-10):**

1. **✅ Complete Word Beginnings**
   - No more cut-off beginnings
   - Batch model receives complete utterances from start
   - First 100-300ms now captured correctly

2. **✅ Improved Accuracy**
   - User feedback: "looks like it's improved"
   - Better transcription quality than broken version
   - Batch model (600M params) performing as expected with complete audio

3. **✅ No Message Loss**
   - All utterances preserved correctly
   - No missing or corrupted transcriptions during testing

4. **✅ Punctuation & Capitalization**
   - Working correctly from batch model
   - Natural sentence formatting

5. **✅ System Stability**
   - No crashes or errors during testing
   - Diagnostic logging confirmed proper buffer behavior
   - Buffer clearing happens at correct time (after refinement)

**User Verdict:**
- "This is really great"
- Dual-pass now functioning as originally intended
- Optional toggle working correctly

**Conclusion:**
The audio buffer timing fix completely resolved all reported issues. Dual-pass refinement is now working as well as the original always-on implementation (commit 161624b), but with the added benefit of being an optional toggle.

### Remaining Tasks (Optional Enhancements)

1. **Performance benchmarking** (nice-to-have metrics)
   - [ ] Measure exact batch processing latency
   - [ ] Test with various utterance lengths (2s, 5s, 10s+)
   - [ ] Monitor memory usage over extended sessions
   - [ ] Profile Neural Engine utilization

2. **Future enhancements** (not critical)
   - [ ] Make EOU debounce configurable
   - [ ] Add visual feedback for refinement state
   - [ ] Consider full-context refinement (beyond single utterance)
   - [x] ~~Implement optional fast-only mode (toggle dual-pass)~~ ✅ DONE

## Decision Criteria

**Choose Dual-Pass if:**
- ✅ TDT outputs punctuation (solves both problems)
- ✅ Latency is acceptable (<200ms perceived)
- ✅ Accuracy improvement is significant (>2% WER reduction)
- ✅ Memory overhead is manageable

**Stick with Single-Pass if:**
- ❌ TDT does NOT output punctuation (need separate model anyway)
- ❌ Latency is too high (>500ms)
- ❌ Accuracy improvement is marginal (<1% WER reduction)
- ❌ Complexity not justified by benefits

## Next Actions

**Immediate (before further architecture work):**
1. [ ] Research Parakeet TDT punctuation capabilities
2. [ ] Test batch TDT inference with sample audio
3. [ ] Document exact output format (capitalization, punctuation, etc.)

**If TDT outputs punctuation:**
1. [ ] Prototype dual-pass architecture
2. [ ] Benchmark latency and accuracy
3. [ ] Compare with single-pass punctuation approach
4. [ ] User testing for perceived quality

**If TDT does NOT output punctuation:**
1. [ ] Proceed with single-pass + separate punctuation model
2. [ ] Consider dual-pass only if accuracy improvement alone justifies complexity
3. [ ] Re-evaluate when FluidAudio adds streaming TDT support

## References

- [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) - Batch model (multilingual)
- [FluidInference/parakeet-tdt-0.6b-v2-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml) - Batch model (English)
- [NVIDIA Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) - Original model documentation
- [FluidAudio GitHub](https://github.com/FluidInference/FluidAudio) - API documentation for batch processing
