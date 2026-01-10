# Session: Text Refinement Experiments

**Date:** 2026-01-09 (evening)
**Status:** Completed - Reverted to streaming-only
**Outcome:** Pure streaming is the winner

## Summary

Explored alternatives to dual-pass audio refinement (which was working but had UX issues). Tried text-based LLM refinement via Ollama as a lighter-weight approach. Integration challenges and unclear benefits led to decision to stick with pure streaming transcription.

## What We Tried

### 1. Ollama LLM Text Refinement
**Goal:** Use local LLM (phi3:mini) to add punctuation/capitalization to streaming text at EOU boundaries instead of re-processing audio.

**Implementation:**
- Installed Ollama with phi3:mini model (3.8B params)
- Created PunctuationModel actor with Ollama API integration
- Built ContinuousRefinementManager to coordinate refinement
- Added completion callbacks to prevent race conditions
- Enhanced rule-based fallback for when Ollama unavailable

**Issues:**
- Refinement didn't trigger reliably
- Integration complexity (async coordination, completion callbacks)
- Unclear if LLM was actually being called
- Logs not showing expected output

**Decision:** Disabled (`isEnabled: false` in RefinementConfig)

### 2. Text-Based Surgical Editing Infrastructure
**Goal:** Build foundation for continuous diff-based editing (future North Star feature).

**Components Built:**
- `TextEditCommand` protocol suite (Navigate, Select, Replace, Insert, Delete)
- `DiffGenerator` actor for computing minimal edit sequences
- `EditApplier` with queuing and version tracking
- `TextStateTracker` for state management
- Extended `InputSimulator` with navigation/selection primitives (Home, End, Shift+Arrow)

**Status:** Complete but unused. Kept in codebase for potential future use.

## Key Learnings

### Dual-Pass Audio (tested earlier today)
**Problems identified:**
1. **UX regression:** Visible backspace/retype animation is distracting (though "kind of cool")
2. **Quality regression:** Batch model sometimes produces worse transcription than streaming
3. **Wasted effort:** Re-processing audio when streaming was already accurate

### Text-Based LLM Refinement
**Problems identified:**
1. Integration complexity outweighs benefits
2. Local LLM adds latency without clear quality improvement
3. Streaming text is already quite usable

### Current Streaming-Only Approach
**Advantages:**
- Fast: Immediate feedback, no post-processing delay
- Simple: Single model, no coordination complexity
- Good quality: ~5.73% WER is acceptable for most use cases
- No regressions: Doesn't make transcription worse

## Technical Details

### Files Modified
- [RefinementConfig.swift](../../packages/app/Yappatron/Sources/Refinement/RefinementConfig.swift) - Disabled refinement (`isEnabled: false`)
- [PunctuationModel.swift](../../packages/app/Yappatron/Sources/Refinement/PunctuationModel.swift) - Ollama integration (disabled)
- [ContinuousRefinementManager.swift](../../packages/app/Yappatron/Sources/Refinement/ContinuousRefinementManager.swift) - EOU refinement coordinator (disabled)
- [YappatronApp.swift](../../packages/app/Yappatron/Sources/YappatronApp.swift) - Completion callback integration

### Files Created (Unused)
- [TextEditCommand.swift](../../packages/app/Yappatron/Sources/TextEditing/TextEditCommand.swift)
- [DiffGenerator.swift](../../packages/app/Yappatron/Sources/TextEditing/DiffGenerator.swift)
- [EditApplier.swift](../../packages/app/Yappatron/Sources/TextEditing/EditApplier.swift)
- [TextStateTracker.swift](../../packages/app/Yappatron/Sources/TextEditing/TextStateTracker.swift)

### Current State
- Pure streaming transcription (Parakeet EOU 120M)
- No post-processing, no refinement
- ~5.73% WER with 320ms chunks
- Clean, simple architecture

## Next Steps

### Immediate (next session)
1. **Cleanup:** Remove or comment out unused code (BatchProcessor, TextRefinementManager, Ollama integration)
2. **Validation:** Use pure streaming in real scenarios to confirm it's good enough
3. **Documentation:** Document the working pattern

### Future Considerations
- **Optional feature:** Dual-pass as user-toggleable option (for those who want it)
- **On-the-fly editing:** Revisit when clearer implementation path emerges
- **Punctuation:** Consider if missing punctuation is actually a problem in practice

## Conclusion

**Winner:** Pure streaming transcription

Simple beats complex. The streaming model is already good enough (~5.73% WER), and attempts to improve it with post-processing introduced more problems than they solved. The right move is to consolidate on what works and ship it.
