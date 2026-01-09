# Task: Hybrid Post-Processing Punctuation & On-the-Fly Editing

**Task ID:** yap-punct
**Priority:** P1
**Status:** 🔬 Research & Planning
**Created:** 2026-01-09

## Problem Statement

The current Parakeet EOU 120M model **does not output punctuation or capitalization** - this is documented behavior, not a bug ([source](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml)). The transcription is quite accurate for word recognition (~5.73% WER with 320ms chunks), but lacks the polish needed for practical dictation:

- No periods, commas, or other punctuation
- No capitalization
- Raw unpunctuated stream creates poor UX despite accurate word recognition

## Vision: On-the-Fly Editing Architecture

Rather than buffering text in an ephemeral location before outputting, explore **direct text manipulation within the input field** using a hybrid streaming + post-processing approach:

### Core Concept
```
Parakeet Stream → Buffer → Display unpunctuated (fast)
      ↓
   [On EOU]
      ↓
Post-processor Model → Generate punctuated version
      ↓
Cursor/Edit Manager → Select & replace text in-place
```

### Key Insight
Use the existing `InputSimulator.applyTextUpdate()` diff-based correction system to make "ghost edits" that:
- Stream in raw text immediately (maintains real-time feel)
- On utterance completion (EOU), intelligently edit the text in-place
- Could support different styles (formal, casual, etc.)
- Could even support translation in real-time

### Reference Architecture from Apple Intelligence
Apple recently implemented similar translation functionality - this hybrid approach is proven at scale.

## Research Findings

### Model Landscape (January 2026)

#### Current Model: Parakeet EOU 120M
- **Size:** 120M parameters, ~250MB download
- **Accuracy:** ~5.73% WER (320ms chunks), ~8-9% WER (160ms chunks)
- **Latency:** 80-160ms per chunk
- **Capabilities:** Streaming ASR with End-of-Utterance detection
- **Limitations:** English only, **no punctuation**, **no capitalization**
- **Source:** [FluidInference/parakeet-realtime-eou-120m-coreml](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml)

#### Larger Models Available (Not Streaming)

**Parakeet TDT v3 (0.6b):**
- **Size:** 600M parameters
- **Accuracy:** Higher than 120M (specific WER not documented)
- **Performance:** ~110× RTF on M4 Pro (1 min audio ≈ 0.5s)
- **Capabilities:** Multilingual (25 European languages), batch processing
- **Limitations:** **No streaming support yet** - "Coming soon" per FluidAudio docs
- **Source:** [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)

**Parakeet TDT v2 (0.6b):**
- **Size:** 600M parameters
- **Accuracy:** "Highest recall" according to FluidAudio
- **Capabilities:** English-only, batch processing
- **Limitations:** No streaming support
- **Source:** [FluidInference/parakeet-tdt-0.6b-v2-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml)

#### Outside FluidAudio Ecosystem (Requires Custom Integration)

**NVIDIA Canary Models:**
- **Canary 1B:** 1 billion parameters, multilingual (English, German, French, Spanish)
- **Canary Qwen 2.5B:** 2.5 billion parameters, tops Open ASR Leaderboard at 5.63% WER
- **Performance:** 418 RTFx (extremely fast)
- **Limitations:** No official CoreML conversions, would require ONNX→CoreML conversion and break "pure Swift" architecture
- **Sources:** [NVIDIA Canary-1b-asr](https://build.nvidia.com/nvidia/canary-1b-asr), [nvidia/canary-qwen-2.5b](https://huggingface.co/nvidia/canary-qwen-2.5b)

**NVIDIA Nemotron Streaming:**
- **nemotron-speech-streaming-en-0.6b:** Newer streaming model
- **Limitations:** Not in FluidAudio library, would need custom integration
- **Source:** [nvidia/nemotron-speech-streaming-en-0.6b](https://huggingface.co/nvidia/nemotron-speech-streaming-en-0.6b)

**Assessment:** Larger models not worth pursuing currently because:
1. TDT models don't support streaming yet
2. Custom integration breaks architecture constraints
3. Current accuracy is "quite accurate" - punctuation is the real problem

### Punctuation Restoration Approaches

#### Approach 1: iOS 16+ Native (Not Compatible)
- **How:** `SFSpeechRecognizer` with `request?.addsPunctuation = true`
- **Pros:** Native, zero latency, maintained by Apple
- **Cons:** Only works with Apple's Speech framework, not FluidAudio
- **Verdict:** ❌ Not compatible with current architecture
- **Source:** [Core ML and NLP Guide](https://moldstud.com/articles/p-enhancing-ios-apps-with-natural-language-processing-and-core-ml-a-comprehensive-guide)

#### Approach 2: On-Device CoreML Punctuation Model (Feasible)
- **Architecture:** GloVe embeddings + Bidirectional LSTM + Attention
- **Training:** TensorFlow/Keras → CoreML conversion
- **Deployment:** Run on Neural Engine alongside ASR
- **Pros:** Fully on-device (privacy maintained), can fine-tune for style
- **Cons:** Need to find/train model, adds latency if not carefully designed, accuracy unknown
- **Verdict:** ✅ Most promising long-term approach
- **Source:** [Netguru - Automatic Sentence Punctuation on iOS](https://www.netguru.com/blog/automatic-sentence-punctuation-on-ios-using-core-ml)

#### Approach 3: Rule-Based Heuristics (Too Brittle)
- **How:** Use EOU signals + pause duration to add basic punctuation
- **Pros:** Zero model overhead, no latency
- **Cons:** Will fail on complex cases, requires constant tuning
- **Verdict:** ⚠️ Doomed for failure per user intuition

#### Approach 4: Hybrid Post-Processing (Recommended)
- **How:** Stream unpunctuated text immediately, post-process on EOU completion
- **Architecture:**
  ```swift
  // Partial text (streaming)
  onPartialTranscription { unpunctuated in
      inputSimulator.applyTextUpdate(from: currentGhostText, to: unpunctuated)
  }

  // Final text (on EOU)
  onTranscription { final in
      let punctuated = await punctuationModel.process(final)
      inputSimulator.applyTextUpdate(from: currentCommittedText, to: punctuated)
  }
  ```
- **Pros:** Doesn't slow streaming feel, can use sophisticated ML, processes complete thoughts
- **Cons:** Text briefly appears unpunctuated then gets replaced (but existing diff system handles this elegantly)
- **Verdict:** ✅✅ Best approach - recommended

## Technical Architecture Proposal

### Component 1: Text Buffer Manager
Track two separate text states:
- **Ghost text:** Current partial transcription (unpunctuated, shown in real-time)
- **Committed text:** Finalized utterances (will receive punctuation)

```swift
class TextBufferManager {
    private var ghostText: String = ""
    private var committedText: String = ""

    func updateGhost(_ newText: String) {
        // Update ghost text (unpunctuated streaming)
    }

    func commitUtterance(_ rawText: String) async {
        // Process through punctuation model
        let punctuated = await punctuationProcessor.process(rawText)
        // Apply edit to replace raw with punctuated
        inputSimulator.applyTextUpdate(from: rawText, to: punctuated)
        committedText += punctuated
    }
}
```

### Component 2: Punctuation Processor
Wrap punctuation model with clean interface:

```swift
actor PunctuationProcessor {
    private var model: MLModel?

    func loadModel() async throws {
        // Load CoreML punctuation restoration model
    }

    func process(_ rawText: String, style: PunctuationStyle = .default) async -> String {
        // Run model inference
        // Return punctuated + capitalized text
    }
}

enum PunctuationStyle {
    case `default`
    case formal
    case casual
    // Future: could support translation here too
}
```

### Component 3: Edit Manager (Enhanced InputSimulator)
Extend existing `InputSimulator` to support more sophisticated edits:

```swift
extension InputSimulator {
    /// Replace a range of text with new text (smart selection + edit)
    func replaceText(from startOffset: Int, length: Int, with newText: String) {
        // 1. Select text range using Cmd+Shift+Arrow or mouse simulation
        // 2. Delete selected text
        // 3. Type new text
    }

    /// Apply "ghost edit" - visually indicate post-processing edit
    func applyPostProcessEdit(from old: String, to new: String) {
        // Could add visual feedback (e.g., brief highlight)
        applyTextUpdate(from: old, to: new)
    }
}
```

### Component 4: Integration with TranscriptionEngine

Modify existing callbacks in [TranscriptionEngine.swift:74-77](../../packages/app/Yappatron/Sources/TranscriptionEngine.swift#L74-L77):

```swift
// Partial callback - stream unpunctuated (current behavior, keep as-is)
onPartialTranscription: ((String) -> Void)?

// Final callback - NEW: post-process before committing
onTranscription: ((String) -> Void)?  // Will now trigger punctuation processing
```

## Implementation Plan

### Phase 1: Research & Model Selection (Current)
- [x] Survey available punctuation restoration models
- [ ] Find pre-trained CoreML punctuation model or identify training approach
- [ ] Benchmark model latency on target hardware (M4 Pro)
- [ ] Validate model can run on Neural Engine alongside ASR

### Phase 2: Proof of Concept (1-2 sessions)
- [ ] Implement `PunctuationProcessor` actor with stub model
- [ ] Create `TextBufferManager` to track ghost vs committed text
- [ ] Modify `TranscriptionEngine` callbacks to route through buffer manager
- [ ] Test basic flow: stream → EOU → post-process → replace

### Phase 3: Model Integration (2-3 sessions)
- [ ] Convert/train punctuation restoration model to CoreML
- [ ] Integrate model into `PunctuationProcessor`
- [ ] Add model download/caching (similar to ASR models)
- [ ] Test accuracy on real dictation samples

### Phase 4: Polish & Style Support (1-2 sessions)
- [ ] Add `PunctuationStyle` variants (formal, casual)
- [ ] Implement visual feedback for post-processing edits
- [ ] Add user settings for punctuation preferences
- [ ] Performance optimization (minimize perceived latency)

### Phase 5: Advanced Features (Future)
- [ ] Real-time translation support (stream → translate → punctuate)
- [ ] Context-aware punctuation (detect code blocks, lists, etc.)
- [ ] Custom vocabulary integration (proper noun capitalization)
- [ ] Multi-language punctuation rules

## Open Questions

1. **Model Selection:** Which punctuation restoration model should we use?
   - Train custom LSTM model (as per Netguru approach)?
   - Find pre-trained BERT/transformer model and convert to CoreML?
   - Use smaller model for speed vs larger for accuracy?

2. **Latency Budget:** How long can post-processing take before UX degrades?
   - Target: <200ms to feel instantaneous
   - Acceptable: <500ms if visually indicated
   - Need to benchmark on target hardware

3. **Visual Feedback:** How to indicate post-processing edits?
   - Brief highlight of edited text?
   - Status indicator in menu bar?
   - Silent (just update text)?

4. **Context Detection:** Should punctuation style adapt to context?
   - Code editor → minimal punctuation?
   - Email client → formal punctuation?
   - Chat app → casual punctuation?

5. **Fallback Strategy:** What if model fails or times out?
   - Commit unpunctuated text (current behavior)?
   - Retry with simpler rule-based approach?
   - Queue for background processing?

## Success Criteria

- [ ] Punctuated text appears within 300ms of EOU detection
- [ ] Punctuation accuracy >95% for common cases (periods, commas, capitalization)
- [ ] No perceptible slowdown in streaming ghost text
- [ ] Memory usage stays under 500MB total (ASR + punctuation models)
- [ ] Works reliably across different text input contexts (editors, browsers, etc.)

## References & Sources

### ASR Models & Ecosystem
- [FluidAudio GitHub Repository](https://github.com/FluidInference/FluidAudio) - Open-source Swift SDK
- [Parakeet EOU 120M CoreML](https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml) - Current model
- [Parakeet TDT 0.6b v3 CoreML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) - Larger batch model
- [NVIDIA Canary 1B](https://build.nvidia.com/nvidia/canary-1b-asr) - Alternative (no CoreML)
- [NVIDIA Canary Qwen 2.5B](https://huggingface.co/nvidia/canary-qwen-2.5b) - State-of-art accuracy

### Punctuation Restoration
- [Netguru - Automatic Sentence Punctuation on iOS Using Core ML](https://www.netguru.com/blog/automatic-sentence-punctuation-on-ios-using-core-ml) - GloVe + LSTM approach
- [Best Open Source STT Models 2026](https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2025-benchmarks) - Benchmark comparison

### General Resources
- [Apple Core ML Documentation](https://developer.apple.com/documentation/coreml)
- [WhisperKit - On-device Speech Recognition](https://github.com/argmaxinc/WhisperKit) - Alternative approach reference

## Next Actions

1. Search for pre-trained punctuation restoration models
2. Benchmark candidate models for latency
3. Create architecture diagram for buffer management
4. Prototype `TextBufferManager` and `PunctuationProcessor` stubs
