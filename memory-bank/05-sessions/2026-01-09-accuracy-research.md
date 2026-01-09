# Session: Accuracy Improvement Research & Punctuation Strategy

**Date:** 2026-01-09 Evening
**Duration:** ~1 hour
**Status:** ✅ Research Complete - Strategy Defined

## Objective

Investigate options for improving transcription accuracy and explore approaches for adding punctuation support to Yappatron. Current state: Parakeet EOU 120M (320ms chunks) is "quite accurate" but lacks punctuation and capitalization, limiting practical usability.

## Key Findings

### 1. Current Model Limitations (Critical Discovery)

**The Parakeet EOU 120M model does NOT output punctuation or capitalization** - this is documented behavior, not a bug or configuration issue.

**Source:** [FluidInference/parakeet-realtime-eou-120m-coreml](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml)

**Impact:** The lack of punctuation is the primary UX issue, not necessarily word recognition accuracy. User observation: "all of this has been dictated here and i have to say it's looking pretty strong as i'm watching it stream in" - accuracy is good, formatting is poor.

### 2. Larger ASR Models (Limited Options)

#### Within FluidAudio Ecosystem

| Model | Parameters | Type | WER | Availability | Verdict |
|-------|-----------|------|-----|--------------|---------|
| **Parakeet EOU 120M (160ms)** | 120M | Streaming | ~8-9% | ✅ Available | Previous version |
| **Parakeet EOU 120M (320ms)** | 120M | Streaming | ~5.73% | ✅ Current | **In use** |
| **Parakeet TDT v3 (0.6b)** | 600M | Batch only | Better | ⚠️ No streaming | Not viable |
| **Parakeet TDT v2 (0.6b)** | 600M | Batch only | "Highest recall" | ⚠️ No streaming | Not viable |

**Sources:**
- [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) - Multilingual (25 languages), ~110× RTF on M4 Pro
- [FluidInference/parakeet-tdt-0.6b-v2-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml) - English-only, "highest recall"
- [GitHub - FluidAudio](https://github.com/FluidInference/FluidAudio) - Documentation states batch processing recommended, streaming "coming soon"

**Key Limitation:** FluidAudio's larger TDT models (600M params) do not yet support streaming ASR. Documentation explicitly states:

> "Streaming support: Coming soon — batch processing is recommended for production use"

**Conclusion:** Upgrading to larger models is **not currently viable** because:
1. No streaming support in FluidAudio for TDT models
2. Batch processing incompatible with real-time dictation UX
3. Current 320ms model already "quite accurate" per user testing

#### Outside FluidAudio (Requires Architecture Changes)

**NVIDIA Canary Models:**
- **Canary 1B:** 1 billion parameters, multilingual (English, German, French, Spanish)
- **Canary Qwen 2.5B:** 2.5 billion parameters, **tops Open ASR Leaderboard at 5.63% WER**
- **Performance:** 418 RTFx (extremely fast, processing audio dramatically faster than Whisper)
- **Problem:** No official CoreML conversions available
- **Problem:** Would require ONNX→CoreML conversion and custom integration (breaks "pure Swift, single process" architecture)

**Sources:**
- [NVIDIA Canary-1b-asr](https://build.nvidia.com/nvidia/canary-1b-asr)
- [nvidia/canary-1b-v2](https://huggingface.co/nvidia/canary-1b-v2)
- [nvidia/canary-qwen-2.5b](https://huggingface.co/nvidia/canary-qwen-2.5b)
- [Best Open Source STT Models 2026](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2025-benchmarks)

**NVIDIA Nemotron Streaming:**
- **nemotron-speech-streaming-en-0.6b:** Newer 600M parameter streaming model
- **Problem:** Not in FluidAudio library, would need custom integration
- **Source:** [nvidia/nemotron-speech-streaming-en-0.6b](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b)

**Conclusion:** Custom model integration is **not recommended** because:
1. Violates core constraint: "Pure Swift, no Python in production"
2. Would require significant architecture changes (ONNX runtime, etc.)
3. Maintenance burden for model updates and conversions
4. User is satisfied with current accuracy ("quite accurate now")

### 3. Punctuation Restoration Approaches

#### Approach 1: iOS 16+ Native Punctuation ❌ Not Compatible

**How it works:**
```swift
SFSpeechRecognizer with request?.addsPunctuation = true
```

**Pros:**
- Native Apple framework
- Zero latency, zero model overhead
- Maintained by Apple

**Cons:**
- Only works with `SFSpeechRecognizer` (Yappatron uses FluidAudio)
- Cannot be applied to existing streaming pipeline
- Incompatible with current architecture

**Verdict:** Not viable - requires complete rewrite to use Apple's Speech framework

**Source:** [iOS Core ML and NLP Guide](https://moldstud.com/articles/p-enhancing-ios-apps-with-natural-language-processing-and-core-ml-a-comprehensive-guide)

#### Approach 2: On-Device CoreML Punctuation Model ✅ Feasible

**Architecture (from Netguru research):**
1. **Word Embeddings:** GloVe (Global Vectors for Word Representation)
2. **Bidirectional LSTM:** Processes sequences forward and backward
3. **Attention Mechanism:** Identifies important words influencing punctuation
4. **Training:** TensorFlow/Keras → CoreML conversion
5. **Deployment:** Runs on Neural Engine alongside ASR

**Integration Pattern:**
```
Raw ASR text → Buffer words → Punctuation model → Capitalized + punctuated text
```

**Pros:**
- Fully on-device (maintains privacy constraint)
- Can run on Neural Engine (efficient)
- Can be fine-tuned for different styles (formal, casual, etc.)
- Supports future extensions (translation, style transfer)

**Cons:**
- Adds latency (need to buffer text before processing)
- Need to train or find pre-trained model
- Accuracy unknown without testing/benchmarking
- Additional model to maintain and update

**Source:** [Netguru - Automatic Sentence Punctuation on iOS Using Core ML](https://www.netguru.com/blog/automatic-sentence-punctuation-on-ios-using-core-ml)

**Note:** Article is proof-of-concept (Feb 2025), provides no accuracy metrics or latency benchmarks. Further research needed to find production-ready models.

#### Approach 3: Rule-Based Heuristics ⚠️ Likely to Fail

**Concept:**
```swift
func addPunctuation(text: String, isEOU: Bool, pauseDuration: TimeInterval) -> String {
    if isEOU && pauseDuration > 1.5 { return text + "." }
    if seemsLikeQuestion(text) { return text + "?" }
    return text + ","
}
```

**Pros:**
- Zero model overhead
- No latency
- Easy to implement

**Cons:**
- Brittle - fails on edge cases
- Requires constant tuning
- Cannot handle complex punctuation (semicolons, quotes, etc.)
- No learning or adaptation

**User verdict:** "Using a rule based heuristic is probably doomed for failure"

**Conclusion:** Not recommended as primary approach, but could serve as fallback if ML model fails.

#### Approach 4: Hybrid Post-Processing ✅✅ Recommended

**User insight:** "Post processing completed utterances is going to be probably the best"

**Architecture:**
```
1. Stream unpunctuated text immediately (maintain real-time feel)
   ↓
2. On EOU (End of Utterance), send to punctuation model
   ↓
3. Use InputSimulator.applyTextUpdate() to replace in-place
```

**Key Innovation: Direct Text Editing in Input Field**

User vision: "Can we edit it directly inside of the input rather than having a buffer that waits in some weird ephemeral location"

**Flow:**
```swift
// Partial (streaming) - unpunctuated
onPartialTranscription { unpunctuated in
    inputSimulator.applyTextUpdate(from: currentGhostText, to: unpunctuated)
}

// Final (on EOU) - punctuated
onTranscription { rawFinal in
    let punctuated = await punctuationModel.process(rawFinal)
    inputSimulator.applyTextUpdate(from: rawFinal, to: punctuated)
    // Text gets "ghost edited" in place
}
```

**Pros:**
- Doesn't slow streaming feel (partials remain fast)
- Can use sophisticated ML model for accuracy
- Processes complete thoughts (better context for punctuation)
- Leverages existing diff-based correction system ([InputSimulator.swift:82-99](../../packages/app/Yappatron/Sources/InputSimulator.swift#L82-L99))
- User sees text immediately, then sees intelligent refinement

**Cons:**
- Text briefly appears unpunctuated, then gets replaced
- Requires careful UX design to avoid jarring replacements

**User acceptance:** "Text briefly appears unpunctuated then gets replaced (but existing diff system handles this elegantly)"

**Conclusion:** This is the recommended approach - combines speed of streaming with accuracy of ML post-processing.

## User Clarification: Accuracy Assessment

> "The accuracy really is quite good but still not exactly perfect in where we need it to be"

**Status:** Accuracy is acceptable but has room for improvement. Not a blocker, but worth exploring better models when streaming options become available.

**Key insight:** Post-processing could serve dual purposes:
1. **Punctuation restoration** (primary need)
2. **Accuracy improvement** (secondary benefit)

## Alternative Approach: Batch Re-processing Audio

User suggestion: "You could do other approaches to like keeping the audio chunk and then processing that even with the model that might do punctuation"

### Concept: Dual-Pass Processing
```
First pass (streaming, real-time):
  Parakeet EOU 120M → Stream unpunctuated text (fast, ~5.73% WER)

Second pass (batch, on EOU):
  Saved audio chunk → Parakeet TDT 0.6b (batch) → Higher accuracy + punctuation model
```

### How It Would Work
1. **Save audio chunks** during streaming
2. **On EOU detection**, trigger batch re-processing:
   - Run larger Parakeet TDT model on saved audio (better accuracy)
   - Apply punctuation restoration model
   - Replace streamed text with refined version
3. **User sees:** Initial fast transcription, then refined version appears

### Trade-offs

**Pros:**
- Can use larger, more accurate batch models (TDT 0.6b)
- Two-model approach: accuracy from TDT + punctuation from separate model
- Maintains real-time streaming feel (first pass)
- Improves both accuracy AND formatting (two birds, one stone)

**Cons:**
- Requires audio buffering (memory overhead)
- More complex architecture (two ASR pipelines)
- Higher latency for final text (batch processing is slower)
- More computation (running ASR twice)
- Larger models → more power consumption

### Reference: Previous Whisper Approach

User note: "Like how we previously were just using whisper which collects the whole audio chunk"

This suggests the Python prototype used Whisper in batch mode. Could adapt similar approach with Parakeet TDT instead.

**Key difference:** Yappatron now has streaming first-pass, so user sees text immediately, then refinement. Previous Whisper was batch-only (wait for full utterance before any text).

### Verdict: Worth Prototyping

This dual-pass approach has merit:
1. Leverages FluidAudio's existing batch TDT models
2. Improves accuracy beyond streaming model
3. Could potentially eliminate need for separate punctuation model if TDT outputs punctuation (needs verification)
4. Flexible: could make second pass optional (user setting: "fast" vs "accurate")

**Next step:** ~~Check if Parakeet TDT batch models output punctuation.~~ ✅ **CONFIRMED - TDT outputs punctuation natively!**

**Update (2026-01-09 Evening):** Dual-pass approach fully implemented. See [2026-01-09-dual-pass-implementation.md](./2026-01-09-dual-pass-implementation.md) for details.

## Strategic Direction: On-the-Fly Editing Architecture

### User Vision

> "There could be like a cursor or editing manager that could like select the text and do these like really cool kind of looking ghost edits as you're talking and have some kind of like i don't even know it might have to be like some kind of daemon or socket or something like a listener like an on the fly editor that's taking the raw stream from parakeet and then making it pretty correct in its punctuality and how it's like on the page"

### Components to Build

#### 1. Text Buffer Manager
Track two text states:
- **Ghost text:** Current partial (unpunctuated, fast streaming)
- **Committed text:** Finalized utterances (punctuated)

#### 2. Punctuation Processor (Actor)
Wraps CoreML model with clean async interface:
```swift
actor PunctuationProcessor {
    func process(_ rawText: String, style: PunctuationStyle) async -> String
}
```

#### 3. Edit Manager
Extends existing `InputSimulator` to support visual "ghost edits":
- Select text range
- Replace with punctuated version
- Optional: Visual feedback (highlight, animation)

#### 4. Style System (Future)
Support different punctuation styles:
- **Default:** Standard punctuation
- **Formal:** Professional writing (full stops, formal grammar)
- **Casual:** Conversational (contractions, informal)
- **Translation:** Real-time language translation with punctuation

### Reference: Apple Intelligence Translation

User observation: "This was basically reimplementing what apple just did because apple just implemented the translation functionality"

Apple's recent translation feature validates this hybrid approach:
- Real-time streaming display (fast)
- Post-processing for quality (accurate)
- In-place editing without jarring UX

**Takeaway:** This architecture is proven at scale by Apple.

## Implementation Architecture

### Current Flow (No Punctuation)
```
Microphone → AVAudioEngine → 16kHz conversion
    ↓
AudioBufferQueue (actor, thread-safe)
    ↓
StreamingEouAsrManager.process()
    ↓
onPartialTranscription → InputSimulator.applyTextUpdate()
    ↓
onTranscription (EOU) → Add space, reset
```

### Proposed Flow (With Punctuation)
```
Microphone → AVAudioEngine → 16kHz conversion
    ↓
AudioBufferQueue (actor, thread-safe)
    ↓
StreamingEouAsrManager.process()
    ↓
onPartialTranscription → TextBufferManager.updateGhost()
    ↓                        ↓
    ↓              InputSimulator.applyTextUpdate() [unpunctuated]
    ↓
onTranscription (EOU) → PunctuationProcessor.process()
    ↓
TextBufferManager.commitUtterance() → InputSimulator.applyTextUpdate() [punctuated]
```

### Key Files to Modify

1. **[YappatronApp.swift:86-176](../../packages/app/Yappatron/Sources/YappatronApp.swift#L86-L176)**
   - `handlePartialTranscription()`: Route through TextBufferManager
   - `handleFinalTranscription()`: Add punctuation processing step

2. **[InputSimulator.swift:78-99](../../packages/app/Yappatron/Sources/InputSimulator.swift#L78-L99)**
   - Existing `applyTextUpdate()` already perfect for ghost edits
   - Consider adding visual feedback for post-processing edits

3. **New: TextBufferManager.swift**
   - Track ghost vs committed text state
   - Coordinate between ASR and punctuation processing

4. **New: PunctuationProcessor.swift**
   - Actor for thread-safe model inference
   - Load/cache CoreML punctuation model
   - Support multiple styles (default, formal, casual)

## Open Research Questions

### 0. Does Parakeet TDT Output Punctuation?
**Question:** Do the larger batch models (TDT 0.6b v2/v3) output punctuation and capitalization?

**Importance:** If TDT models output punctuation, dual-pass approach solves both problems (accuracy + formatting) without separate punctuation model.

**Next steps:**
- [ ] Review Parakeet TDT model documentation on Hugging Face
- [ ] Test batch inference with sample audio
- [ ] Check model output format (tokens, capitalization, punctuation)

**If YES:** Consider dual-pass approach as primary strategy
**If NO:** Proceed with separate punctuation restoration model

### 1. Model Selection
**Question:** Which punctuation restoration model should we use?

**Options:**
- Train custom LSTM (GloVe + BiLSTM + Attention) following Netguru approach
- Find pre-trained BERT/transformer model and convert to CoreML
- Use lightweight model (fast but less accurate) vs larger (slow but accurate)
- **Alternative:** Skip separate punctuation model if using dual-pass with TDT

**Next steps:**
- [ ] Check if Parakeet TDT outputs punctuation (Question 0)
- [ ] Search Hugging Face for pre-trained punctuation restoration models
- [ ] Check if models are available in CoreML format
- [ ] Benchmark candidate models for latency on M4 Pro hardware

### 2. Latency Budget
**Question:** How long can post-processing take before UX degrades?

**Targets:**
- Ideal: <200ms (feels instantaneous)
- Acceptable: <500ms (if visually indicated with animation)
- Unacceptable: >500ms (breaks flow)

**Next steps:**
- [ ] Benchmark punctuation model inference times
- [ ] Test with real dictation samples
- [ ] Gather user feedback on perceived latency

### 3. Visual Feedback
**Question:** How to indicate post-processing edits without jarring the user?

**Options:**
- Silent replacement (leverage existing diff system)
- Brief highlight of edited text
- Status indicator in menu bar
- Subtle animation (fade, pulse)

**Next steps:**
- [ ] Prototype different visual approaches
- [ ] User testing for preference

### 4. Style Adaptation
**Question:** Should punctuation style adapt to context automatically?

**Scenarios:**
- Code editor (Xcode, VS Code) → Minimal punctuation, preserve code flow
- Email client (Mail, Gmail) → Formal punctuation, full sentences
- Chat app (Messages, Slack) → Casual punctuation, fragments OK
- Document editor (Pages, Word) → Standard punctuation

**Next steps:**
- [ ] Research macOS accessibility APIs for detecting app context
- [ ] Define punctuation rules for each context
- [ ] Prototype context detection

### 5. Fallback Strategy
**Question:** What if punctuation model fails or times out?

**Options:**
- Commit unpunctuated text (current behavior - safe)
- Retry with simpler rule-based approach
- Queue for background processing (risky - could accumulate)

**Next steps:**
- [ ] Define timeout thresholds
- [ ] Implement graceful degradation

## Success Criteria

**Must have:**
- [ ] Punctuated text appears within 300ms of EOU detection
- [ ] Punctuation accuracy >95% for common cases (periods, commas, capitalization)
- [ ] No perceptible slowdown in streaming ghost text
- [ ] Memory usage stays under 500MB total (ASR + punctuation models)

**Nice to have:**
- [ ] Support for multiple punctuation styles (formal, casual)
- [ ] Context-aware punctuation (email vs chat vs code)
- [ ] Visual feedback for post-processing edits
- [ ] <200ms latency for "instantaneous" feel

## Next Actions

1. **Research Phase (Next Session):**
   - [ ] Search Hugging Face for pre-trained punctuation restoration models
   - [ ] Check CoreML Model Zoo for available models
   - [ ] Investigate converting BERT-based models to CoreML

2. **Architecture Phase:**
   - [ ] Design TextBufferManager interface
   - [ ] Design PunctuationProcessor actor
   - [ ] Create architecture diagram for buffer management
   - [ ] Define interfaces between components

3. **Prototyping Phase:**
   - [ ] Implement stub TextBufferManager
   - [ ] Implement stub PunctuationProcessor (with hardcoded punctuation for testing)
   - [ ] Modify YappatronApp callbacks to route through new components
   - [ ] Test basic flow: stream → EOU → post-process → replace

4. **Integration Phase:**
   - [ ] Integrate real punctuation model
   - [ ] Benchmark latency on M4 Pro
   - [ ] Test accuracy on real dictation samples
   - [ ] Add model download/caching (similar to ASR models)

## References & Sources

### ASR Models & Ecosystem
- [GitHub - FluidAudio](https://github.com/FluidInference/FluidAudio) - "Frontier CoreML audio models in your apps"
- [FluidAudio Releases](https://github.com/FluidInference/FluidAudio/releases) - Update history
- [Parakeet EOU 120M CoreML](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml) - Current streaming model
- [Parakeet TDT 0.6b v3 CoreML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) - Larger batch model (multilingual)
- [Parakeet TDT 0.6b v2 CoreML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml) - Larger batch model (English)

### Alternative Models (Outside FluidAudio)
- [NVIDIA Canary 1B](https://build.nvidia.com/nvidia/canary-1b-asr) - 1B params, multilingual
- [NVIDIA Canary 1B v2](https://huggingface.co/nvidia/canary-1b-v2) - Updated version
- [NVIDIA Canary Qwen 2.5B](https://huggingface.co/nvidia/canary-qwen-2.5b) - State-of-art (5.63% WER)
- [NVIDIA Nemotron Streaming 0.6b](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b) - Streaming variant
- [Best Open Source STT Models 2026](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2025-benchmarks) - Comprehensive benchmarks

### Punctuation Restoration
- [Netguru - Automatic Sentence Punctuation on iOS Using Core ML](https://www.netguru.com/blog/automatic-sentence-punctuation-on-ios-using-core-ml) - GloVe + BiLSTM + Attention approach
- [Apple Core ML Documentation](https://developer.apple.com/documentation/coreml) - Official framework docs
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) - On-device speech recognition (reference architecture)

### General Resources
- [Awesome CoreML Models](https://github.com/likedan/Awesome-CoreML-Models) - Community model collection
- [Core ML Model Format Reference](https://apple.github.io/coremltools/mlmodel/Format/Model.html) - Technical specs

## Technical Notes

### Why Parakeet EOU 120M Doesn't Have Punctuation

ASR models are typically trained on raw transcripts without punctuation to:
1. Simplify training data collection (speech → text mapping)
2. Reduce model complexity (fewer output tokens)
3. Improve speed (fewer decision points)
4. Allow downstream customization (punctuation style varies by use case)

Punctuation is traditionally a **separate NLP task** (sequence labeling), which is why hybrid approaches make sense.

### Existing Infrastructure Advantages

Yappatron's architecture is well-suited for hybrid post-processing:

1. **Diff-based text correction already works** ([InputSimulator.swift:82-99](../../packages/app/Yappatron/Sources/InputSimulator.swift#L82-L99))
   - Finds common prefix
   - Backspaces divergent suffix
   - Types new suffix
   - Can handle punctuation insertion seamlessly

2. **EOU detection is reliable**
   - Model emits `<EOU>` token at utterance boundaries
   - 800ms debounce ensures completeness
   - Natural trigger point for post-processing

3. **Actor-based concurrency prevents race conditions**
   - Recent fix for audio buffer queue
   - Can extend pattern to punctuation processing
   - Thread-safe by design

4. **Neural Engine already in use**
   - ASR runs on ANE
   - Punctuation model can share ANE
   - Minimal additional power consumption

## Memory Bank Updates

- [x] Created [punctuation-post-processing.md](../02-active/punctuation-post-processing.md) with detailed task breakdown
- [x] Created this session document (2026-01-09-accuracy-research.md)
- [ ] Update [nextUp.md](../02-active/nextUp.md) to reflect new priority
- [ ] Update [activeWork.md](../02-active/activeWork.md) when implementation begins

## Session Summary

**Duration:** ~1 hour of research and strategic planning

**Key Decisions:**
1. ✅ Do not pursue larger ASR models (no streaming support yet in FluidAudio)
2. ✅ Focus on punctuation restoration as primary UX improvement
3. ✅ Use hybrid post-processing approach (stream unpunctuated, post-process on EOU)
4. ✅ Build on-the-fly editing architecture leveraging existing diff system

**Next Phase:** Model research and prototype implementation

**User Feedback:** "This is a lot of really excellent research by the way" - direction validated
